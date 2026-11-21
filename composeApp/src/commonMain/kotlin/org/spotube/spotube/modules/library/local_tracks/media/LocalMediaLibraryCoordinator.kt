/*
 * Copyright (C) 2026 Kingkor Roy Tirtho and Spotube Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

package org.spotube.spotube.modules.library.local_tracks.media

import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import okio.FileSystem
import okio.Path.Companion.toPath
import okio.SYSTEM
import org.spotube.spotube.core.db.Database
import org.spotube.spotube.core.di.injectLogger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.time.Clock
import org.koin.core.component.KoinComponent

class LocalMediaLibraryCoordinator(
    private val discoveryService: LocalMediaDiscoveryService,
    private val cacheRepository: LocalMediaCacheRepository,
    private val foldersConfig: LocalMediaFoldersConfig,
    private val database: Database) : KoinComponent {
    private val logger by injectLogger<LocalMediaLibraryCoordinator>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val _cacheState = MutableStateFlow(LocalMediaCache())
    private val downloadKeyPrefix = "download-path:"
    val cacheState: StateFlow<LocalMediaCache> = combine(
        _cacheState, database.offlineLibraryDataStore.data
    ) { cache, preferences ->
        val downloadPaths = preferences.asMap().mapNotNull { (key, value) ->
            if (key.name.startsWith(downloadKeyPrefix) && value is String) {
                key.name.removePrefix(downloadKeyPrefix) to value
            } else null
        }.toMap()
        cache.copy(downloadPaths = downloadPaths)
    }.stateIn(scope, SharingStarted.Eagerly, LocalMediaCache())

    suspend fun registerDownloadedTrack(trackId: String, path: String) {
        if (trackId.isNotBlank()) {
            database.offlineLibraryDataStore.edit {
                it[stringPreferencesKey(downloadKeyPrefix + trackId)] = path
            }
        }
    }

    private var observation: LocalMediaObservation? = null
    private var periodicJob: Job? = null
    private var configuredRoots: List<String> = emptyList()
    private val refreshMutex = Mutex()

    init {
        scope.launch {
            cacheRepository.cacheFlow.collect { cache ->
                _cacheState.value = cache
            }
        }

        scope.launch {
            discoveryService.ensureInitialized()
            foldersConfig.configuredRootsFlow.collect { roots ->
                configuredRoots = roots
                observation?.stop()
                observation = discoveryService.observeChanges(roots) {
                    scheduleRefresh(reason = "filesystem_change")
                }
                scheduleRefresh(reason = "roots_changed")
            }
        }

        periodicJob = scope.launch {
            while (true) {
                delay(PERIODIC_REFRESH_MS)
                refreshIfStale()
            }
        }
    }

    fun findMatchingTrack(
        track: org.spotube.plugin_interfaces.plugin_apis.metadata.track.MetadataTrack,
        cache: LocalMediaCache = cacheState.value
    ): LocalMediaTrack? {
        cache.downloadPaths[track.id]?.let { path ->
            val metadata = runCatching { FileSystem.SYSTEM.metadataOrNull(path.toPath()) }.getOrNull()
            if (metadata?.isRegularFile == true && (metadata.size ?: 0) > 0) {
                return LocalMediaTrack(
                    path = path,
                    name = track.title,
                    artists = track.artists.map { it.name },
                    durationMs = track.durationMs,
                    album = track.album?.title)
            }
        }
        val album = track.album?.title ?: return null
        val artists = track.artists.joinToString(", ") { it.name }
        if (artists.isBlank() || track.durationMs <= 0) return null
        return cache.folders.asSequence().flatMap { it.tracks.asSequence() }
            .filter { local ->
                local.name.equals(track.title, ignoreCase = true) &&
                    local.album.equals(album, ignoreCase = true) &&
                    local.artists.joinToString(", ").equals(artists, ignoreCase = true) &&
                    local.durationMs > 0 &&
                    kotlin.math.abs(local.durationMs - track.durationMs) <= 2000
            }
            .distinctBy { it.path }
            .take(2).toList().singleOrNull()
    }

    fun scheduleRefresh(reason: String) {
        scope.launch {
            runCatching { refreshNow(reason) }
                .onFailure { throwable ->
                    logger.w(throwable) { "Local media refresh failed. reason=$reason" }
                }
        }
    }

    suspend fun refreshIfStale() {
        val lastIndexedAt = _cacheState.value.indexedAtEpochMs
        val now = Clock.System.now().toEpochMilliseconds()
        if (now - lastIndexedAt >= STALE_AFTER_MS) {
            refreshNow("stale")
        }
    }

    suspend fun refreshNow(reason: String) {
        refreshMutex.withLock {
            logger.i { "Refreshing local media cache. reason=$reason" }
            runCatching {
                discoveryService.discoverFolders(configuredRoots)
            }.onSuccess { folders ->
                val cache = LocalMediaCache(
                    folders = folders,
                    indexedAtEpochMs = Clock.System.now().toEpochMilliseconds())
                cacheRepository.save(cache)
                _cacheState.value = cache
            }.onFailure { throwable ->
                logger.w(throwable) { "Failed to discover local media. reason=$reason" }
            }
        }
    }

    companion object {
        private const val PERIODIC_REFRESH_MS = 15 * 60 * 1000L
        private const val STALE_AFTER_MS = 30 * 60 * 1000L
    }
}

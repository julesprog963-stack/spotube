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

package org.spotube.spotube.modules.playlist

import org.spotube.plugin_interfaces.plugin_apis.metadata.common.PaginationResult
import org.spotube.plugin_interfaces.plugin_apis.metadata.common.PaginationStrategy
import org.spotube.plugin_interfaces.plugin_apis.metadata.playlist.MetadataPlaylist
import org.spotube.plugin_interfaces.plugin_apis.metadata.track.MetadataTrack
import org.spotube.spotube.modules.library.LibraryRepository
import org.spotube.spotube.modules.plugin.PluginManager
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.Json
import org.spotube.spotube.core.db.Database
import io.github.reactivecircus.cache4k.Cache
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

@OptIn(ExperimentalCoroutinesApi::class)
class PlaylistRepository(
    val pluginManager: PluginManager,
    private val libraryRepository: LibraryRepository,
    private val database: Database) {
    val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())

    val plugin
        get() = pluginManager.selectedMetadataPlugin.value

    private val playlistInfoCache = Cache.Builder<String, Pair<MetadataPlaylist, Boolean>>().build()
    private val playlistTracksCache = Cache.Builder<Pair<String, PaginationStrategy>, PaginationResult<MetadataTrack>>().build()

    init {
        scope.launch {
            pluginManager.selectedMetadataPlugin
                .filterNotNull()
                .flatMapLatest { it.loggedInFlow }
                .distinctUntilChanged()
                .collect { loggedIn ->
                    isLoggedIn = loggedIn
                    invalidateCaches()
                }
        }
    }

    private var isLoggedIn: Boolean = false

    fun invalidateCaches() {
        playlistInfoCache.invalidateAll()
        playlistTracksCache.invalidateAll()
    }

    suspend fun getPlaylistInfo(playlistId: String) = plugin?.let { plugin ->
        playlistInfoCache.get(playlistId) {
            mirrored("playlist:${plugin.pluginId}:$playlistId:info") {
                pluginManager.withScope {
                    plugin.use {
                        val playlist = metadataPlaylistAPI.getPlaylist(playlistId)
                        val isSaved = libraryRepository.isSavedPlaylists(listOf(playlistId)).firstOrNull() ?: false
                        playlist to isSaved
                    }
                }
            }
        }
    }

    suspend fun getPlaylistTracks(
        playlistId: String,
        paginationStrategy: PaginationStrategy? = null,
        refresh: Boolean = false
    ): PaginationResult<MetadataTrack>? = plugin?.let { active ->
        val key = playlistId to (paginationStrategy ?: PaginationStrategy.Offset(0, 20))
        if (refresh) playlistTracksCache.invalidate(key)
        playlistTracksCache.get(key) {
            mirrored("playlist:${active.pluginId}:$playlistId:${Json.encodeToString(paginationStrategy)}") {
                pluginManager.withScope {
                    active.use {
                        metadataPlaylistAPI.getPlaylistTracks(id = playlistId, pagination = paginationStrategy)
                    }
                }
            }
        }
    }

    private suspend inline fun <reified T> mirrored(keyName: String, fetch: () -> T): T {
        val key = stringPreferencesKey(keyName)
        val store = database.offlineLibraryDataStore
        return try {
            val result = fetch()
            store.edit { it[key] = Json.encodeToString(result) }
            result
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            val cached = store.data.first()[key] ?: throw e
            Json.decodeFromString<T>(cached)
        }
    }

    suspend fun toggleSavedPlaylist(playlistId: String, currentIsSaved: Boolean) = plugin?.let { plugin ->
        if (currentIsSaved) {
            libraryRepository.removeSavedPlaylists(listOf(playlistId))
        } else {
            libraryRepository.savePlaylists(listOf(playlistId))
        }
        !currentIsSaved
    }
}

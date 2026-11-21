package org.spotube.spotube.modules.playlist

import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import co.touchlab.kermit.Logger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.spotube.plugin_interfaces.plugin_apis.metadata.common.PaginationStrategy
import org.spotube.spotube.core.audioplayer.PlaybackConnectivity
import org.spotube.spotube.core.db.Database
import org.spotube.spotube.modules.downloads.DownloadManager
import org.spotube.spotube.modules.library.LibraryRepository

enum class PlaylistDownloadMode { Wifi, AnyConnection }

class PlaylistDownloads(
    database: Database,
    private val library: LibraryRepository,
    private val playlists: PlaylistRepository,
    private val downloads: DownloadManager,
    private val connectivity: PlaybackConnectivity?
) {
    private val store = database.offlineLibraryDataStore
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val syncMutex = Mutex()
    private val logger = Logger.withTag("PlaylistDownloads")
    private val lastSync = mutableMapOf<String, Long>()
    val supportsWifiOnly = connectivity != null

    init {
        scope.launch {
            while (true) {
                downloads.resumePlaylistDownloads()
                syncDuePlaylists()
                delay(10_000)
            }
        }
    }

    private fun prefix(pluginId: String) = "playlist-download:$pluginId:"
    private fun key(playlistId: String) =
        library.configuredMetadataPluginId?.let { stringPreferencesKey(prefix(it) + playlistId) }

    fun mode(playlistId: String) = combine(store.data, library.pluginManager.state) { prefs, _ ->
        key(playlistId)?.let { prefs[it] }?.let(PlaylistDownloadMode::valueOf)
    }

    fun setMode(playlistId: String, mode: PlaylistDownloadMode?) {
        val key = key(playlistId) ?: return
        scope.launch {
            store.edit { if (mode == null) it.remove(key) else it[key] = mode.name }
            downloads.cancelPlaylistDownloads(key.name)
            syncMutex.withLock { lastSync.remove(key.name) }
            syncDuePlaylists()
        }
    }

    private suspend fun syncDuePlaylists() = syncMutex.withLock {
        val active = playlists.plugin ?: return@withLock
        if (connectivity?.hasInternet() == false) return@withLock
        val prefix = prefix(active.pluginId)
        val now = kotlin.time.Clock.System.now().toEpochMilliseconds()
        for ((key, value) in store.data.first().asMap()) {
            if (!key.name.startsWith(prefix) || value !is String) continue
            val mode = PlaylistDownloadMode.valueOf(value)
            if (mode == PlaylistDownloadMode.Wifi && connectivity?.hasWifi() != true) continue
            if (now - (lastSync[key.name] ?: 0) < 120_000) continue
            lastSync[key.name] = now
            try {
                syncPlaylist(key.name.removePrefix(prefix), key.name, mode)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                logger.w(e) { "Could not synchronize playlist ${key.name}" }
            }
        }
    }

    private suspend fun syncPlaylist(playlistId: String, keyName: String, mode: PlaylistDownloadMode) {
        val wifiOnly = mode == PlaylistDownloadMode.Wifi
        val key = stringPreferencesKey(keyName)
        val visited = mutableSetOf<PaginationStrategy?>()
        var next: PaginationStrategy? = null
        do {
            if (wifiOnly && connectivity?.hasWifi() != true) return
            if (store.data.first()[key] != mode.name) return
            val page = playlists.getPlaylistTracks(playlistId, next, refresh = true) ?: return
            if (store.data.first()[key] != mode.name) return
            page.items.forEach { downloads.enqueue(it, playlistKey = keyName, wifiOnly = wifiOnly) }
            next = page.nextPagination
        } while (next != null && visited.add(next))
    }
}

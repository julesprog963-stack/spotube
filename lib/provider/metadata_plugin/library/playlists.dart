import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/core/auth.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';
import 'package:spotube/provider/metadata_plugin/tracks/playlist.dart';
import 'package:spotube/provider/metadata_plugin/utils/paginated.dart';
import 'package:spotube/services/metadata/errors/exceptions.dart';

const _kOfflineSavedPlaylistsCacheKey = 'spotube_offline_saved_playlists_v1';

class MetadataPluginSavedPlaylistsNotifier
    extends PaginatedAsyncNotifier<SpotubeSimplePlaylistObject> {
  MetadataPluginSavedPlaylistsNotifier() : super();

  Future<void> _saveOfflineCache(
    SpotubePaginationResponseObject<SpotubeSimplePlaylistObject> data,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonMap = {
        'limit': data.limit,
        'nextOffset': null,
        'total': data.items.length,
        'hasMore': false,
        'items': data.items.map((e) => e.toJson()).toList(),
      };
      await prefs.setString(
        _kOfflineSavedPlaylistsCacheKey,
        jsonEncode(jsonMap),
      );
    } catch (_) {}
  }

  Future<SpotubePaginationResponseObject<SpotubeSimplePlaylistObject>>
      _loadOfflineCache(int limit) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kOfflineSavedPlaylistsCacheKey);
      if (raw != null && raw.isNotEmpty) {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        final cached =
            SpotubePaginationResponseObject<SpotubeSimplePlaylistObject>.fromJson(
          map,
          SpotubeSimplePlaylistObject.fromJson,
        );
        return SpotubePaginationResponseObject<SpotubeSimplePlaylistObject>(
          limit: cached.items.length,
          nextOffset: null,
          total: cached.items.length,
          hasMore: false,
          items: cached.items,
        );
      }
    } catch (_) {}
    return SpotubePaginationResponseObject<SpotubeSimplePlaylistObject>(
      limit: limit,
      nextOffset: null,
      total: 0,
      hasMore: false,
      items: [],
    );
  }

  @override
  fetch(int offset, int limit) async {
    try {
      final playlists = await (await metadataPlugin)
          .user
          .savedPlaylists(limit: limit, offset: offset);
      if (offset == 0 && playlists.items.isNotEmpty) {
        await _saveOfflineCache(playlists);
      }
      return playlists;
    } catch (_) {
      if (offset == 0) {
        return await _loadOfflineCache(limit);
      }
      return SpotubePaginationResponseObject<SpotubeSimplePlaylistObject>(
        limit: limit,
        nextOffset: null,
        total: state.value?.items.length ?? 0,
        hasMore: false,
        items: [],
      );
    }
  }

  @override
  build() async {
    await ref.watch(metadataPluginAuthenticatedProvider.future);

    try {
      final playlists = await fetch(0, 20);
      return playlists;
    } catch (_) {
      return await _loadOfflineCache(20);
    }
  }

  void updatePlaylist(SpotubeSimplePlaylistObject playlist) {
    if (state.value == null) return;

    if (state.value!.items.none((e) => e.id == playlist.id)) return;

    state = AsyncData(
      state.value!.copyWith(
        items: state.value!.items
            .map((element) => element.id == playlist.id ? playlist : element)
            .toList(),
      ),
    );
  }

  Future<void> addFavorite(SpotubeSimplePlaylistObject playlist) async {
    if (state.value == null) return;

    final oldState = state.value;

    state = AsyncData(
      state.value!.copyWith(
        items: [
          playlist,
          ...state.value!.items,
        ],
      ),
    );

    try {
      await (await metadataPlugin).playlist.save(playlist.id);
    } catch (e) {
      state = AsyncData(oldState!);
      rethrow;
    }
  }

  Future<void> removeFavorite(SpotubeSimplePlaylistObject playlist) async {
    if (state.value == null) return;

    final oldState = state.value;
    state = AsyncData(
      state.value!.copyWith(
        items: state.value!.items.where((e) => (e).id != playlist.id).toList(),
      ),
    );

    try {
      await (await metadataPlugin).playlist.unsave(playlist.id);
    } catch (e) {
      state = AsyncData(oldState!);
      rethrow;
    }
  }

  Future<void> delete(String playlistId) async {
    if (state.value == null) return;
    final oldState = state;
    try {
      state = const AsyncLoading();
      await (await metadataPlugin).playlist.deletePlaylist(playlistId);
      ref.invalidateSelf();
      ref.invalidate(metadataPluginIsSavedPlaylistProvider(playlistId));
      ref.invalidate(metadataPluginPlaylistTracksProvider(playlistId));
    } catch (e) {
      state = oldState;
      rethrow;
    }
  }

  Future<void> addTracks(String playlistId, List<String> trackIds) async {
    if (state.value == null) return;

    await (await metadataPlugin)
        .playlist
        .addTracks(playlistId, trackIds: trackIds);

    ref.invalidate(metadataPluginPlaylistTracksProvider(playlistId));
  }

  Future<void> removeTracks(String playlistId, List<String> trackIds) async {
    if (state.value == null) return;

    await (await metadataPlugin)
        .playlist
        .removeTracks(playlistId, trackIds: trackIds);

    ref.invalidate(metadataPluginPlaylistTracksProvider(playlistId));
  }
}

final metadataPluginSavedPlaylistsProvider = AsyncNotifierProvider<
    MetadataPluginSavedPlaylistsNotifier,
    SpotubePaginationResponseObject<SpotubeSimplePlaylistObject>>(
  () => MetadataPluginSavedPlaylistsNotifier(),
);

final metadataPluginIsSavedPlaylistProvider =
    FutureProvider.family<bool, String>(
  (ref, id) async {
    final plugin = await ref.watch(metadataPluginProvider.future);

    if (plugin == null) {
      throw MetadataPluginException.noDefaultMetadataPlugin();
    }

    final savedPlaylists =
        await ref.watch(metadataPluginSavedPlaylistsProvider.future);

    final savedPlaylistsNotifier =
        ref.read(metadataPluginSavedPlaylistsProvider.notifier);

    final allSavedPlaylists = savedPlaylists.hasMore
        ? await savedPlaylistsNotifier.fetchAll()
        : savedPlaylists.items;

    return allSavedPlaylists.any((element) => element.id == id);
  },
);

import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/download_manager_provider.dart';
import 'package:spotube/provider/metadata_plugin/core/auth.dart';
import 'package:spotube/provider/metadata_plugin/utils/common.dart';
import 'package:spotube/provider/metadata_plugin/utils/paginated.dart';

const _kOfflineSavedTracksCacheKey = 'spotube_offline_saved_tracks_v1';

class MetadataPluginSavedTracksNotifier
    extends AutoDisposePaginatedAsyncNotifier<SpotubeFullTrackObject> {
  MetadataPluginSavedTracksNotifier() : super();

  Future<void> _saveOfflineCache(
    SpotubePaginationResponseObject<SpotubeFullTrackObject> data,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonMap = {
        'limit': data.limit,
        'nextOffset': data.nextOffset,
        'total': data.total,
        'hasMore': data.hasMore,
        'items': data.items.map((e) => e.toJson()).toList(),
      };
      await prefs.setString(_kOfflineSavedTracksCacheKey, jsonEncode(jsonMap));
    } catch (_) {}
  }

  Future<SpotubePaginationResponseObject<SpotubeFullTrackObject>?>
      _loadOfflineCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kOfflineSavedTracksCacheKey);
      if (raw == null || raw.isEmpty) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return SpotubePaginationResponseObject<SpotubeFullTrackObject>.fromJson(
        map,
        SpotubeFullTrackObject.fromJson,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  fetch(offset, limit) async {
    try {
      final tracks = await (await metadataPlugin).user.savedTracks(
            offset: offset,
            limit: limit,
          );
      if (offset == 0 && tracks.items.isNotEmpty) {
        await _saveOfflineCache(tracks);
      }
      return tracks;
    } catch (e) {
      if (offset == 0) {
        final cached = await _loadOfflineCache();
        if (cached != null) return cached;
      }
      rethrow;
    }
  }

  @override
  build() async {
    ref.cacheFor();

    try {
      await ref.watch(metadataPluginAuthenticatedProvider.future);
      return await fetch(0, 20);
    } catch (e) {
      final cached = await _loadOfflineCache();
      if (cached != null) return cached;
      rethrow;
    }
  }

  Future<void> addFavorite(List<SpotubeTrackObject> tracks) async {
    if (state.value == null) {
      return;
    }

    final fullTracks = tracks.whereType<SpotubeFullTrackObject>().toList();
    final oldState = state.value;
    final updatedState = state.value!.copyWith(
      items: [
        ...fullTracks,
        ...state.value!.items,
      ],
    );
    state = AsyncData(updatedState);
    await _saveOfflineCache(updatedState);

    if (fullTracks.isNotEmpty) {
      Future.microtask(() {
        ref.read(downloadManagerProvider.notifier).addAllToQueue(fullTracks);
      });
    }

    try {
      await (await metadataPlugin).track.save(tracks.map((e) => e.id).toList());
    } catch (e) {
      state = AsyncData(oldState!);
      rethrow;
    }
  }

  Future<void> removeFavorite(List<SpotubeTrackObject> tracks) async {
    if (state.value == null) {
      return;
    }

    final oldState = state.value;
    final updatedState = state.value!.copyWith(
      items: state.value!.items
          .where(
            (savedTrack) => !tracks.any((track) => track.id == savedTrack.id),
          )
          .toList(),
    );
    state = AsyncData(updatedState);
    await _saveOfflineCache(updatedState);

    try {
      await (await metadataPlugin)
          .track
          .unsave(tracks.map((e) => e.id).toList());
    } catch (e) {
      state = AsyncData(oldState!);
      rethrow;
    }
  }
}

final metadataPluginSavedTracksProvider = AutoDisposeAsyncNotifierProvider<
    MetadataPluginSavedTracksNotifier,
    SpotubePaginationResponseObject<SpotubeFullTrackObject>>(
  () => MetadataPluginSavedTracksNotifier(),
);

final metadataPluginIsSavedTrackProvider =
    FutureProvider.autoDispose.family<bool, String>(
  (ref, trackId) async {
    final savedTracks =
        await ref.watch(metadataPluginSavedTracksProvider.future);
    final allSavedTracks = savedTracks.hasMore
        ? await ref.read(metadataPluginSavedTracksProvider.notifier).fetchAll()
        : savedTracks.items;

    return allSavedTracks.any((track) => track.id == trackId);
  },
);

import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/download_manager_provider.dart';
import 'package:spotube/provider/metadata_plugin/core/auth.dart';
import 'package:spotube/provider/metadata_plugin/utils/common.dart';
import 'package:spotube/provider/metadata_plugin/utils/paginated.dart';

const _kOfflineSavedTracksCacheKey = 'spotube_offline_saved_tracks_v1';
const _kLocalAddedFavoritesKey = 'spotube_local_added_favorites_v1';
const _kLocalRemovedFavoritesKey = 'spotube_local_removed_favorites_v1';

class MetadataPluginSavedTracksNotifier
    extends AutoDisposePaginatedAsyncNotifier<SpotubeFullTrackObject> {
  MetadataPluginSavedTracksNotifier() : super();

  Future<List<SpotubeFullTrackObject>> _loadLocalAddedFavorites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kLocalAddedFavoritesKey);
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw) as List;
      return list
          .map((e) =>
              SpotubeFullTrackObject.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<Set<String>> _loadLocalRemovedFavorites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_kLocalRemovedFavoritesKey);
      return list?.toSet() ?? <String>{};
    } catch (_) {
      return <String>{};
    }
  }

  Future<void> _recordLocalFavoriteAdd(
    List<SpotubeFullTrackObject> addedTracks,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existingAdded = await _loadLocalAddedFavorites();
      final removedIds = await _loadLocalRemovedFavorites();
      for (final t in addedTracks) {
        removedIds.remove(t.id);
      }
      final seen = <String>{};
      final merged = <SpotubeFullTrackObject>[];
      for (final t in [...addedTracks, ...existingAdded]) {
        if (seen.add(t.id)) {
          merged.add(t);
        }
      }
      await prefs.setString(
        _kLocalAddedFavoritesKey,
        jsonEncode(merged.map((e) => e.toJson()).toList()),
      );
      await prefs.setStringList(
        _kLocalRemovedFavoritesKey,
        removedIds.toList(),
      );
    } catch (_) {}
  }

  Future<void> _recordLocalFavoriteRemove(List<String> removedTrackIds) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final removeSet = removedTrackIds.toSet();
      final existingAdded = await _loadLocalAddedFavorites();
      final updatedAdded =
          existingAdded.where((t) => !removeSet.contains(t.id)).toList();
      final removedIds = await _loadLocalRemovedFavorites();
      removedIds.addAll(removeSet);
      await prefs.setString(
        _kLocalAddedFavoritesKey,
        jsonEncode(updatedAdded.map((e) => e.toJson()).toList()),
      );
      await prefs.setStringList(
        _kLocalRemovedFavoritesKey,
        removedIds.toList(),
      );
    } catch (_) {}
  }

  Future<void> _saveExactOfflineCache(
    SpotubePaginationResponseObject<SpotubeFullTrackObject> data,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonMap = {
        'limit': data.items.length,
        'nextOffset': null,
        'total': data.items.length,
        'hasMore': false,
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
      final parsed =
          SpotubePaginationResponseObject<SpotubeFullTrackObject>.fromJson(
        map,
        SpotubeFullTrackObject.fromJson,
      );
      return SpotubePaginationResponseObject<SpotubeFullTrackObject>(
        limit: parsed.items.length,
        nextOffset: null,
        total: parsed.items.length,
        hasMore: false,
        items: parsed.items,
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
      if (offset == 0) {
        final localAdded = await _loadLocalAddedFavorites();
        final localRemoved = await _loadLocalRemovedFavorites();
        final cached = await _loadOfflineCache();
        final remoteIds = tracks.items.map((e) => e.id).toSet();
        final cachedOnly = (cached?.items ?? <SpotubeFullTrackObject>[])
            .where((t) => !remoteIds.contains(t.id))
            .toList();
        final currentItems = state.value?.items ?? <SpotubeFullTrackObject>[];

        final seen = <String>{};
        final combined = <SpotubeFullTrackObject>[];
        for (final t in [
          ...localAdded,
          ...cachedOnly,
          ...currentItems,
          ...tracks.items,
        ]) {
          if (!localRemoved.contains(t.id) && seen.add(t.id)) {
            combined.add(t);
          }
        }
        final mergedResponse = SpotubePaginationResponseObject<SpotubeFullTrackObject>(
          limit: combined.length,
          nextOffset: tracks.nextOffset,
          total: combined.length > tracks.total ? combined.length : tracks.total,
          hasMore: tracks.hasMore,
          items: combined,
        );
        if (combined.isNotEmpty) {
          await _saveExactOfflineCache(mergedResponse);
        }
        return mergedResponse;
      }
      return tracks;
    } catch (e) {
      final cached = await _loadOfflineCache();
      if (cached != null) {
        if (offset == 0) {
          return cached;
        }
        final existingIds =
            (state.value?.items ?? []).map((e) => e.id).toSet();
        final remaining = cached.items
            .where((t) => !existingIds.contains(t.id))
            .toList();
        return SpotubePaginationResponseObject<SpotubeFullTrackObject>(
          limit: remaining.length,
          nextOffset: null,
          total: cached.items.length,
          hasMore: false,
          items: remaining,
        );
      }
      rethrow;
    }
  }

  @override
  build() async {
    ref.cacheFor();

    try {
      await ref.watch(metadataPluginAuthenticatedProvider.future);
      final firstPage = await fetch(0, 20);
      if (firstPage.hasMore) {
        Future.microtask(() async {
          try {
            final cached = await _loadOfflineCache();
            if (cached == null || cached.items.length < firstPage.total) {
              await fetchAll();
            }
          } catch (_) {}
        });
      }
      return firstPage;
    } catch (e) {
      final cached = await _loadOfflineCache();
      if (cached != null) return cached;
      rethrow;
    }
  }

  Future<void> addFavorite(List<SpotubeTrackObject> tracks) async {
    var currentState = state.value;
    if (currentState == null) {
      try {
        currentState = await future;
      } catch (_) {
        currentState = await _loadOfflineCache();
      }
    }
    if (currentState == null) {
      return;
    }

    final fullTracks = tracks.whereType<SpotubeFullTrackObject>().toList();
    final seen = <String>{};
    final mergedItems = <SpotubeFullTrackObject>[];
    for (final t in [...fullTracks, ...currentState.items]) {
      if (seen.add(t.id)) {
        mergedItems.add(t);
      }
    }

    final updatedState = currentState.copyWith(
      items: mergedItems,
      total: mergedItems.length,
      limit: mergedItems.length,
    );
    state = AsyncData(updatedState);
    await _recordLocalFavoriteAdd(fullTracks);
    await _saveExactOfflineCache(updatedState);

    if (fullTracks.isNotEmpty) {
      Future.microtask(() {
        ref.read(downloadManagerProvider.notifier).addAllToQueue(fullTracks);
      });
    }

    try {
      await (await metadataPlugin).track.save(tracks.map((e) => e.id).toList());
    } catch (_) {
      // Keep local favorite state and offline cache even if remote save fails
    }
  }

  Future<void> removeFavorite(List<SpotubeTrackObject> tracks) async {
    var currentState = state.value;
    if (currentState == null) {
      try {
        currentState = await future;
      } catch (_) {
        currentState = await _loadOfflineCache();
      }
    }
    if (currentState == null) {
      return;
    }

    final removeIds = tracks.map((e) => e.id).toList();
    final filteredItems = currentState.items
        .where(
          (savedTrack) => !tracks.any((track) => track.id == savedTrack.id),
        )
        .toList();
    final updatedState = currentState.copyWith(
      items: filteredItems,
      total: filteredItems.length,
      limit: filteredItems.length,
    );
    state = AsyncData(updatedState);
    await _recordLocalFavoriteRemove(removeIds);
    await _saveExactOfflineCache(updatedState);

    try {
      await (await metadataPlugin).track.unsave(removeIds);
    } catch (_) {
      // Keep local removal state and offline cache even if remote unsave fails
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
    final savedTracksState = ref.watch(metadataPluginSavedTracksProvider);
    final SpotubePaginationResponseObject<SpotubeFullTrackObject> savedTracks =
        savedTracksState.valueOrNull ??
            await ref.watch(metadataPluginSavedTracksProvider.future);
    final allSavedTracks = savedTracks.hasMore
        ? await ref.read(metadataPluginSavedTracksProvider.notifier).fetchAll()
        : savedTracks.items;

    return allSavedTracks.any((track) => track.id == trackId);
  },
);

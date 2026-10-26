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
      List<SpotubeFullTrackObject> mergedItems = [...data.items];
      final existingRaw = prefs.getString(_kOfflineSavedTracksCacheKey);
      if (existingRaw != null && existingRaw.isNotEmpty) {
        try {
          final existingMap = jsonDecode(existingRaw) as Map<String, dynamic>;
          final existing =
              SpotubePaginationResponseObject<SpotubeFullTrackObject>.fromJson(
            existingMap,
            SpotubeFullTrackObject.fromJson,
          );
          final seenIds = mergedItems.map((e) => e.id).toSet();
          for (final item in existing.items) {
            if (seenIds.add(item.id)) {
              mergedItems.add(item);
            }
          }
        } catch (_) {}
      }
      final jsonMap = {
        'limit': mergedItems.length,
        'nextOffset': null,
        'total': data.total > mergedItems.length ? data.total : mergedItems.length,
        'hasMore': false,
        'items': mergedItems.map((e) => e.toJson()).toList(),
      };
      await prefs.setString(_kOfflineSavedTracksCacheKey, jsonEncode(jsonMap));
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
      if (tracks.items.isNotEmpty) {
        final currentItems = state.value?.items ?? <SpotubeFullTrackObject>[];
        final seen = <String>{};
        final combined = <SpotubeFullTrackObject>[];
        for (final t in [...currentItems, ...tracks.items]) {
          if (seen.add(t.id)) {
            combined.add(t);
          }
        }
        await _saveOfflineCache(
          tracks.copyWith(items: combined),
        );
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
    await _saveExactOfflineCache(updatedState);

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

import 'dart:async';
import 'dart:math';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
// ignore: implementation_imports
import 'package:riverpod/src/async_notifier.dart';
import 'package:spotube/provider/metadata_plugin/utils/common.dart';
import 'package:spotube/services/logger/logger.dart';

mixin PaginatedAsyncNotifierMixin<K>
    // ignore: invalid_use_of_internal_member
    on AsyncNotifierBase<SpotubePaginationResponseObject<K>> {
  Future<SpotubePaginationResponseObject<K>> fetch(int offset, int limit);

  Future<void> fetchMore() async {
    if (state.value == null || !state.value!.hasMore) return;

    final oldState = state.value;
    try {
      state = AsyncLoadingNext(state.asData!.value);

      final newState = await fetch(
        state.value!.nextOffset!,
        state.value!.limit,
      );

      final oldItems =
          state.value!.items.isEmpty ? <K>[] : state.value!.items.cast<K>();
      final items = newState.items.isEmpty ? <K>[] : newState.items.cast<K>();

      state = AsyncData(newState.copyWith(items: <K>[...oldItems, ...items]));
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
      state = AsyncData(oldState!);
    }
  }

  Completer<List<K>>? _fetchAllCompleter;

  Future<List<K>> fetchAll() async {
    if (state.value == null) return [];
    if (!state.value!.hasMore) return state.value!.items.cast<K>();
    if (_fetchAllCompleter != null) return _fetchAllCompleter!.future;

    _fetchAllCompleter = Completer<List<K>>();
    try {
      var currentState = state.value!;
      final accumulated = <K>[
        ...(currentState.items.isEmpty ? <K>[] : currentState.items.cast<K>())
      ];

      bool hasMore = currentState.hasMore;
      int? nextOffset = currentState.nextOffset;

      while (hasMore && nextOffset != null) {
        final offsetToFetch = nextOffset;
        final newState = await fetch(
          offsetToFetch,
          max(currentState.limit, 100),
        )
            .catchError(
              (e) => fetch(offsetToFetch, max(currentState.limit, 50)),
            )
            .catchError(
              (e) => fetch(offsetToFetch, currentState.limit),
            )
            .catchError(
          (e) async {
            await Future.delayed(const Duration(milliseconds: 500));
            return fetch(offsetToFetch, currentState.limit);
          },
        );

        final items =
            newState.items.isEmpty ? <K>[] : newState.items.cast<K>();
        accumulated.addAll(items);

        hasMore = newState.hasMore && newState.nextOffset != offsetToFetch;
        nextOffset = newState.nextOffset;
        currentState = newState.copyWith(
          hasMore: hasMore,
          nextOffset: nextOffset,
          items: accumulated,
        );
      }

      state = AsyncData(currentState.copyWith(hasMore: false, nextOffset: null));
      final result = state.value!.items.cast<K>();
      _fetchAllCompleter!.complete(result);
      return result;
    } catch (e, stack) {
      _fetchAllCompleter!.completeError(e, stack);
      rethrow;
    } finally {
      _fetchAllCompleter = null;
    }
  }
}

abstract class PaginatedAsyncNotifier<K>
    extends AsyncNotifier<SpotubePaginationResponseObject<K>>
    with PaginatedAsyncNotifierMixin<K>, MetadataPluginMixin<K> {}

abstract class AutoDisposePaginatedAsyncNotifier<K>
    extends AutoDisposeAsyncNotifier<SpotubePaginationResponseObject<K>>
    with PaginatedAsyncNotifierMixin<K>, MetadataPluginMixin<K> {}

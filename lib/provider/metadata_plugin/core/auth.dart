import 'dart:async';

import 'package:riverpod/riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';

const _kOfflineAuthenticatedKey = 'spotube_offline_authenticated_v1';
const _kOfflineSavedTracksKey = 'spotube_offline_saved_tracks_v1';

class MetadataPluginAuthenticatedNotifier extends AsyncNotifier<bool> {
  Future<bool> _getOfflineAuthFallback() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedAuth = prefs.getBool(_kOfflineAuthenticatedKey) ?? false;
      final hasCachedTracks =
          (prefs.getString(_kOfflineSavedTracksKey)?.isNotEmpty) ?? false;
      return cachedAuth || hasCachedTracks;
    } catch (_) {
      return false;
    }
  }

  Future<void> _setOfflineAuth(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kOfflineAuthenticatedKey, value);
    } catch (_) {}
  }

  @override
  FutureOr<bool> build() async {
    final defaultPluginConfig = ref.watch(metadataPluginsProvider);
    if (defaultPluginConfig.asData?.value.defaultMetadataPluginConfig?.abilities
            .contains(PluginAbilities.authentication) !=
        true) {
      return await _getOfflineAuthFallback();
    }

    final defaultPlugin = await ref.watch(metadataPluginProvider.future);
    if (defaultPlugin == null) {
      return await _getOfflineAuthFallback();
    }

    final sub = defaultPlugin.auth.authStateStream.listen((event) async {
      final isAuth = defaultPlugin.auth.isAuthenticated();
      if (isAuth) {
        await _setOfflineAuth(true);
        state = const AsyncData(true);
      } else {
        final fallback = await _getOfflineAuthFallback();
        state = AsyncData(fallback);
      }
    });

    ref.onDispose(() {
      sub.cancel();
    });

    final isAuth = defaultPlugin.auth.isAuthenticated();
    if (isAuth) {
      await _setOfflineAuth(true);
      return true;
    }
    return await _getOfflineAuthFallback();
  }
}

final metadataPluginAuthenticatedProvider =
    AsyncNotifierProvider<MetadataPluginAuthenticatedNotifier, bool>(
  MetadataPluginAuthenticatedNotifier.new,
);

class AudioSourcePluginAuthenticatedNotifier extends AsyncNotifier<bool> {
  @override
  FutureOr<bool> build() async {
    final defaultPluginConfig = ref.watch(metadataPluginsProvider);
    if (defaultPluginConfig
            .asData?.value.defaultAudioSourcePluginConfig?.abilities
            .contains(PluginAbilities.authentication) !=
        true) {
      return false;
    }

    final defaultPlugin = await ref.watch(audioSourcePluginProvider.future);
    if (defaultPlugin == null) {
      return false;
    }

    final sub = defaultPlugin.auth.authStateStream.listen((event) {
      state = AsyncData(defaultPlugin.auth.isAuthenticated());
    });

    ref.onDispose(() {
      sub.cancel();
    });

    return defaultPlugin.auth.isAuthenticated();
  }
}

final audioSourcePluginAuthenticatedProvider =
    AsyncNotifierProvider<AudioSourcePluginAuthenticatedNotifier, bool>(
  AudioSourcePluginAuthenticatedNotifier.new,
);

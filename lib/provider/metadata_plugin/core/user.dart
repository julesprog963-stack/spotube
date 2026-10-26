import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/core/auth.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';

const _kOfflineUserCacheKey = 'spotube_offline_user_v1';

Future<SpotubeUserObject> _loadOfflineUserFallback() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kOfflineUserCacheKey);
    if (raw != null && raw.isNotEmpty) {
      return SpotubeUserObject.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    }
  } catch (_) {}
  return SpotubeUserObject(
    id: 'offline-user',
    name: 'Offline',
    images: [],
    externalUri: '',
  );
}

final metadataPluginUserProvider = FutureProvider<SpotubeUserObject?>(
  (ref) async {
    final metadataPlugin = await ref.watch(metadataPluginProvider.future);
    final authenticated =
        await ref.watch(metadataPluginAuthenticatedProvider.future);

    if (!authenticated) {
      return null;
    }
    if (metadataPlugin == null) {
      return await _loadOfflineUserFallback();
    }
    try {
      final user = await metadataPlugin.user.me();
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          _kOfflineUserCacheKey,
          jsonEncode(user.toJson()),
        );
      } catch (_) {}
      return user;
    } catch (_) {
      return await _loadOfflineUserFallback();
    }
  },
);

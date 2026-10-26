import 'package:spotube/utils/platform.dart';

enum ReleaseChannel {
  nightly,
  stable,
}

class _Env {
  static const String lastFmApiKey = '00000000000000000000000000000000';
  static const String lastFmApiSecret = '00000000000000000000000000000000';
  static const int _hideDonations = 0;
  static const String _enableUpdateChecker = '0';
  static const String _releaseChannel = 'stable';
}

abstract class Env {
  static final String lastFmApiKey = _Env.lastFmApiKey;

  static final String lastFmApiSecret = _Env.lastFmApiSecret;

  static final int _hideDonations = _Env._hideDonations;

  static bool get hideDonations => _hideDonations == 1;

  static final String _enableUpdateChecker = _Env._enableUpdateChecker;

  static final String _releaseChannel = _Env._releaseChannel;

  static ReleaseChannel get releaseChannel => _releaseChannel == "stable"
      ? ReleaseChannel.stable
      : ReleaseChannel.nightly;

  static bool get enableUpdateChecker =>
      kIsFlatpak || _enableUpdateChecker == "1";

  static String discordAppId = "1176718791388975124";
}

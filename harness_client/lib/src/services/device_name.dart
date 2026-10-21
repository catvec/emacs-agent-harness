import 'package:flutter/foundation.dart';

/// A short name for this device: what the harness shows the person who is
/// asked to approve it, and in its list of devices.
String deviceName() {
  if (kIsWeb) return 'Harness on the web';
  final platform = switch (defaultTargetPlatform) {
    TargetPlatform.android => 'Android',
    TargetPlatform.iOS => 'iOS',
    TargetPlatform.macOS => 'macOS',
    TargetPlatform.linux => 'Linux',
    TargetPlatform.windows => 'Windows',
    TargetPlatform.fuchsia => 'Fuchsia',
  };
  return 'Harness on $platform';
}

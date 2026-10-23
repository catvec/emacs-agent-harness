import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// What the Android build needs from `android/gradle.properties` so that the
/// build the phone installer runs (`tool/qr_install.sh`, over the `build/` its
/// last run left) does not fall over on a dependency upgrade.
///
/// Kotlin's incremental compiler keeps its state in `build/`, keyed by the
/// paths of the sources.  A plugin's sources sit in the pub cache under a
/// directory named after its version, so raising the version moves them, and
/// the compiler then carries the old path's classes over to the new one
/// wrongly.  `shared_preferences_android` 2.5.0 -> 2.5.2 over the `build/` of
/// 2.5.0 lost `SharedPreferencesPlugin`, and
///
///     GeneratedPluginRegistrant.java:34: error: cannot find symbol
///       symbol:   class SharedPreferencesPlugin
///
/// stopped the build.  A build from an empty `build/` is fine, so a task that
/// builds the app once, in a clean checkout, cannot see it, and nothing else
/// the app's tests run can: they do not compile Kotlin.  Compiling from
/// scratch every time is what keeps the build from depending on what was
/// built before.
void main() {
  /// The `key=value` lines of `android/gradle.properties` that are in force:
  /// not comments, not blank.
  Map<String, String> properties() {
    final result = <String, String>{};
    for (final raw in File('android/gradle.properties').readAsLinesSync()) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('!')) {
        continue;
      }
      final at = line.indexOf('=');
      if (at < 0) continue;
      result[line.substring(0, at).trim()] = line.substring(at + 1).trim();
    }
    return result;
  }

  test('Kotlin is compiled from scratch, not on top of an older build', () {
    expect(
      properties()['kotlin.incremental'],
      'false',
      reason:
          'android/gradle.properties must say kotlin.incremental=false: with '
          "Kotlin's incremental compiler on, a plugin upgrade built over an "
          'existing build/ can lose the plugin\'s classes (cannot find symbol '
          'in GeneratedPluginRegistrant.java), and only a build over an older '
          'one shows it',
    );
  });

  test('the SDK components the build is pinned to are all named', () {
    // tool/client_toolchain.sh installs exactly these when the machine has no
    // Android SDK of its own, and the build reads them in android/build.gradle.
    final pinned = properties();
    for (final key in const [
      'harness.compileSdk',
      'harness.buildToolsVersion',
      'harness.ndkVersion',
      'harness.cmakeVersion',
    ]) {
      expect(pinned[key], isNotNull, reason: '$key is not set');
      expect(pinned[key], isNotEmpty, reason: '$key is empty');
    }
  });
}

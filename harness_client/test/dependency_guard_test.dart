import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `shared_preferences_android` 2.5.0 and 2.5.1 do not work in an Android
/// release build.  They look Kotlin classes up by name through JNI, and ship
/// no R8 keep rules; Flutter runs R8 on every release build, which renames
/// those classes, and the plugin dies at startup with a `NoSuchMethodError`.
/// The app can then neither read nor write its preferences, so it forgets the
/// address of its harness and its session secret each time it closes, whatever
/// "Remember" says.  That is what `tool/qr_install.sh` (a release build)
/// put on a phone, for days; no test of the app on the desktop or in a browser
/// can see it, because neither runs R8.  2.5.2 adds the rules.
///
/// So the lock file may not go below that.  (A rebuilt lock file, or a pub
/// that is asked for the newest versions that fit and is handed an old one by
/// a stale cache, is how it would.)
const _minimum = (2, 5, 2);

(int, int, int)? _parse(String version) {
  final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(version);
  if (match == null) return null;
  return (
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  );
}

bool _atLeast((int, int, int) version, (int, int, int) floor) {
  if (version.$1 != floor.$1) return version.$1 > floor.$1;
  if (version.$2 != floor.$2) return version.$2 > floor.$2;
  return version.$3 >= floor.$3;
}

/// The lines of the entry for [package] in `pubspec.lock`.
List<String> _lockEntry(String package) {
  final lines = File('pubspec.lock').readAsLinesSync();
  final start = lines.indexOf('  $package:');
  if (start < 0) return const [];
  final entry = <String>[];
  for (var i = start + 1; i < lines.length; i++) {
    if (!lines[i].startsWith('    ')) break;
    entry.add(lines[i]);
  }
  return entry;
}

void main() {
  test('the locked Android preference plugin is one that survives R8', () {
    final entry = _lockEntry('shared_preferences_android');
    expect(entry, isNotEmpty, reason: 'pubspec.lock names no such package');
    final version = entry
        .map((line) => RegExp(r'^    version: "([^"]+)"').firstMatch(line))
        .whereType<RegExpMatch>()
        .map((match) => match.group(1)!)
        .firstOrNull;
    expect(version, isNotNull, reason: 'no version in its lock entry');
    final parsed = _parse(version!);
    expect(parsed, isNotNull, reason: '"$version" is not a version');
    expect(
      _atLeast(parsed!, _minimum),
      isTrue,
      reason:
          'shared_preferences_android $version is locked: below 2.5.2 the '
          'Android release build cannot read or write its preferences (R8 '
          'strips what the plugin finds through JNI), so the app forgets its '
          'harness each time it closes.',
    );
  });

  test('pubspec.yaml does not let the plugin fall below it either', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^  shared_preferences_android: *\^?(\d+\.\d+\.\d+)',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(
      match,
      isNotNull,
      reason:
          'shared_preferences_android must be a direct dependency, to hold '
          'its minimum version: it is only a transitive one otherwise, and a '
          'new lock file may pick any version shared_preferences allows',
    );
    expect(_atLeast(_parse(match!.group(1)!)!, _minimum), isTrue);
  });
}

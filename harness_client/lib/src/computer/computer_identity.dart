import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/device_name.dart';

/// Who this client is when it registers itself as a computer.
///
/// The id is stable for the installation (`cmp-<os>-<random>`), and the
/// secret is what proves that a reconnect speaks for the same registration.
/// Both live in the app's private preferences: the mobile equivalent of a
/// file only this app can read.  They are not hardware-backed; a platform
/// keystore can replace [ComputerSecretStore] without touching the endpoint.
class ComputerIdentity {
  const ComputerIdentity({
    required this.id,
    required this.name,
    required this.os,
    required this.arch,
    required this.secret,
  });

  final String id;
  final String name;
  final String os;
  final String arch;
  final String secret;

  static const _idKey = 'harness.computer.id';
  static const _secretKey = 'harness.computer.secret';
  static const _nameKey = 'harness.computer.name';

  /// Read this installation's identity, making an id and a secret the first
  /// time.  The secret is 256 random bits, base64url without padding.
  ///
  /// With [preferences] it is kept there (a widget test's mock store).  In
  /// the app it is a JSON file in the app's private directory, read and
  /// written synchronously so the first `initialize` can carry the real id
  /// without waiting on a platform channel.  The file is inside the app
  /// sandbox; it is not hardware-backed, and [ComputerSecretStore] is the
  /// seam a platform keystore would replace.
  static Future<ComputerIdentity> load({SharedPreferences? preferences}) async {
    if (preferences != null) {
      var id = preferences.getString(_idKey);
      if (id == null || id.isEmpty) {
        id = _newId();
        await preferences.setString(_idKey, id);
      } else if (id != id.toLowerCase()) {
        id = id.toLowerCase();
        await preferences.setString(_idKey, id);
      }
      var secret = preferences.getString(_secretKey);
      if (secret == null || secret.length < 32) {
        secret = _randomToken(32);
        await preferences.setString(_secretKey, secret);
      }
      final name = preferences.getString(_nameKey);
      return ComputerIdentity(
        id: id,
        name: (name == null || name.isEmpty) ? deviceName() : name,
        os: computerOs(),
        arch: computerArch(),
        secret: secret,
      );
    }
    final file = _file();
    if (file.existsSync()) {
      try {
        final wire =
            jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
        final id = (wire[_idKey] as String?)?.toLowerCase();
        final secret = wire[_secretKey] as String?;
        if (id != null &&
            id.isNotEmpty &&
            secret != null &&
            secret.length >= 32) {
          final name = wire[_nameKey] as String?;
          return ComputerIdentity(
            id: id,
            name: (name == null || name.isEmpty) ? deviceName() : name,
            os: computerOs(),
            arch: computerArch(),
            secret: secret,
          );
        }
      } catch (_) {
        // A damaged file is replaced by a fresh identity.
      }
    }
    final identity = ComputerIdentity(
      id: _newId(),
      name: deviceName(),
      os: computerOs(),
      arch: computerArch(),
      secret: _randomToken(32),
    );
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode(<String, Object?>{
          _idKey: identity.id,
          _secretKey: identity.secret,
          _nameKey: identity.name,
        }),
      );
    } catch (_) {
      // No writable sandbox: keep the identity for this run.
    }
    return identity;
  }

  static File _file() =>
      File('${Directory.systemTemp.path}/harness-computer/identity.json');

  /// An identity for this run only, when preferences are not answering.
  factory ComputerIdentity.ephemeral() => ComputerIdentity(
    id: _newId(),
    name: deviceName(),
    os: computerOs(),
    arch: computerArch(),
    secret: _randomToken(32),
  );

  /// The computer description sent in `initialize` and at registration.
  Map<String, Object?> toWire() => <String, Object?>{
    'id': id,
    'name': name,
    'host': name,
    'os': os,
    'arch': arch,
    'display': null,
    'vnc': null,
    'vncSocket': null,
    'windowScoped': false,
    'capabilities': const <String>[],
    'servers': const <Object?>[],
  };
}

/// The operating system name the harness stores, in its lower-case vocabulary.
String computerOs() {
  if (kIsWeb) return 'web';
  return defaultTargetPlatform.name;
}

/// The architecture, where the platform exposes one, else its OS name.
///
/// Flutter has no portable architecture query; a build may pass
/// `--dart-define=HARNESS_ARCH=arm64`, and otherwise this says `unknown`
/// rather than guessing.
String computerArch() {
  const fromBuild = String.fromEnvironment('HARNESS_ARCH');
  if (fromBuild.isNotEmpty) return fromBuild;
  return 'unknown';
}

/// A fresh computer id.  Lowercase, because the harness keeps computer ids
/// lowercase and a client that used another case would not find its own.
String _newId() => 'cmp-${computerOs()}-${_randomToken(9).toLowerCase()}';

String _randomToken(int bytes) {
  final random = Random.secure();
  final values = List<int>.generate(bytes, (_) => random.nextInt(256));
  return base64UrlEncode(values).replaceAll('=', '');
}

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/device_name.dart';
import 'computer_platform.dart';

/// Who this client is when it registers itself as a computer.
///
/// The id is stable for the installation (`cmp-<os>-<random>`), and the
/// secret is what proves that a reconnect speaks for the same registration.
/// The id and the name are in a file in the app's durable private directory;
/// the secret is sealed by the platform (Android Keystore, iOS Keychain) when
/// it has one, and otherwise sits in that same private file.  The wire format
/// does not depend on which.
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

  /// Where the secret is kept when the platform has a keystore or a keychain.
  /// The id and the name are not secret, so they stay in the identity file.
  static const secretKey = 'identity.secret';

  /// Read this installation's identity, making an id and a secret the first
  /// time.  The secret is 256 random bits, base64url without padding.
  ///
  /// With [preferences] it is kept there (a widget test's mock store).  In
  /// the app it is a JSON file under [directoryPath], the platform's durable
  /// private directory, read and written synchronously so the first
  /// `initialize` can carry the real id without waiting on a channel.  The
  /// secret is sealed through [platform] and kept out of that file when the
  /// platform has a keystore or a keychain.
  static Future<ComputerIdentity> load({
    SharedPreferences? preferences,
    ComputerPlatform? platform,
    String? directoryPath,
  }) async {
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
    final file = _file(directoryPath);
    final sealed = await _sealedSecret(platform);
    if (file.existsSync()) {
      try {
        final wire =
            jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
        final id = (wire[_idKey] as String?)?.toLowerCase();
        // The secret comes from the keystore when one answered, else from the
        // file itself (a platform with no keystore, or a file written before
        // the secret moved there).
        final secret = sealed ?? wire[_secretKey] as String?;
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
      secret: sealed != null && sealed.length >= 32 ? sealed : _randomToken(32),
    );
    // The secret is sealed by the platform when it has a keystore or a
    // keychain; the identity file then holds no secret at all.  Without one
    // the file is the app sandbox, which is what it was before.
    final sealedNow = await _sealSecret(platform, identity.secret);
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode(<String, Object?>{
          _idKey: identity.id,
          if (!sealedNow) _secretKey: identity.secret,
          _nameKey: identity.name,
        }),
      );
    } catch (_) {
      // No writable sandbox: keep the identity for this run.
    }
    return identity;
  }

  /// The secret the platform's keystore holds, or null when it has none.
  static Future<String?> _sealedSecret(ComputerPlatform? platform) async {
    if (platform == null) return null;
    try {
      final value = await platform.unseal(secretKey);
      return value != null && value.length >= 32 ? value : null;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _sealSecret(
    ComputerPlatform? platform,
    String secret,
  ) async {
    if (platform == null) return false;
    try {
      return await platform.seal(secretKey, secret);
    } catch (_) {
      return false;
    }
  }

  /// The identity file: the platform's durable app directory when it gave
  /// one, else the process's temporary directory (a widget test, a desktop
  /// build that was handed none).
  static File _file(String? directoryPath) => File(
    '${directoryPath ?? Directory.systemTemp.path}/harness-computer/identity.json',
  );

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

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'computer_capabilities.dart';
import 'computer_capture_port.dart';

/// What the phone's own OS says about one permission, before anything is
/// asked for.  It is data, not interface copy; the page maps it to a noun.
enum PlatformPermission {
  /// The OS holds it now.
  granted,

  /// The OS does not hold it and the person has to answer a prompt.
  promptable,

  /// The person (or a device policy) refused it.
  denied,

  /// This build or this OS has no such thing.
  unavailable,
}

/// One OS permission's state, with the platform's own reason when it is not
/// [PlatformPermission.granted].
@immutable
class PermissionState {
  const PermissionState(this.permission, {this.detail});

  final PlatformPermission permission;
  final String? detail;

  bool get granted => permission == PlatformPermission.granted;

  static const unknown = PermissionState(PlatformPermission.unavailable);
  static const held = PermissionState(PlatformPermission.granted);

  @override
  String toString() => 'PermissionState(${permission.name}, $detail)';
}

/// What the phone's OS said, read once and then held as a value.
///
/// Nothing on the connection path waits for a platform channel: a channel is
/// answered by the platform, and a test, a desktop build or a web build never
/// answers one at all.  The app reads [ComputerPlatform.facts] once at start
/// (with a short bound), hands the value to the controller, and asks again
/// only when the person asks or the app comes back to the foreground.
@immutable
class PlatformFacts {
  const PlatformFacts({
    this.permissions = const <String, PermissionState>{},
    this.storageRoot,
    this.control = SystemControlState.unsupported,
    this.secure = false,
    this.read = false,
  });

  /// The OS's answer for `camera`, `microphone`, `screen` and `control`.
  final Map<String, PermissionState> permissions;

  /// The app's durable private directory, or null when it gave none.
  final String? storageRoot;

  /// What the OS says of the person's system control.
  final SystemControlState control;

  /// Whether the platform has a keystore or a keychain to seal the secret in.
  final bool secure;

  /// Whether the OS was asked at all.  False for a test, the web and a desktop
  /// build, whose honest answer is that nothing is known yet.
  final bool read;

  PlatformFacts copyWith({
    Map<String, PermissionState>? permissions,
    String? storageRoot,
    SystemControlState? control,
    bool? secure,
    bool? read,
  }) => PlatformFacts(
    permissions: permissions ?? this.permissions,
    storageRoot: storageRoot ?? this.storageRoot,
    control: control ?? this.control,
    secure: secure ?? this.secure,
    read: read ?? this.read,
  );

  @override
  String toString() =>
      'PlatformFacts(read: $read, root: $storageRoot, control: ${control.name}, '
      'secure: $secure, permissions: ${permissions.length})';
}

/// Where the app's own durable files live, and how a secret is sealed.
///
/// The defaults are honest for a build with no platform channel: no durable
/// directory beyond the process's temporary one, and a secret that is only as
/// safe as the app sandbox the caller already has.  A phone replaces both.
abstract class ComputerPlatform {
  /// The OS's state for each of `camera`, `microphone`, `screen` and
  /// `control`.  It never prompts.
  Future<Map<String, PermissionState>> permissions();

  /// Ask the OS for `camera` or `microphone`; resolves to its state after the
  /// person answers.  A prompt is made only from a person's own switch.
  Future<PermissionState> requestPermission(String name);

  /// The path of the app's durable private directory, or null when this
  /// platform has none.  It is inside the app sandbox, and the person's own
  /// files are only ever copies there.
  Future<String?> storageRoot();

  /// Keep [value] under [key] with the platform's own protection (Android
  /// Keystore, iOS Keychain).  False when this platform has none.
  Future<bool> seal(String key, String value);

  /// The value kept under [key], or null when there is none or it cannot be
  /// unsealed.
  Future<String?> unseal(String key);

  Future<void> forget(String key);

  /// Open the OS's own settings page where a person enables system control.
  /// False when the platform has no such page or no such control.
  Future<bool> openControlSettings();

  /// Whether this platform can seal a secret in its own keystore or keychain.
  bool get secure;

  /// Everything the OS can say, in one value: one round trip, and a result the
  /// controller holds instead of waiting on a channel again.
  Future<PlatformFacts> facts();
}

/// The channel to the Android host and the iOS runner.
class MethodChannelComputerPlatform implements ComputerPlatform {
  const MethodChannelComputerPlatform({this.channel = _defaultChannel});

  static const _defaultChannel = MethodChannel('app.harness/computer_platform');
  final MethodChannel channel;

  @override
  bool get secure => true;

  /// The OS's answer, read once.  Each ask is bounded by the caller, and a
  /// channel that does not answer throws, which the caller treats as nothing
  /// said: no state is invented from silence.
  @override
  Future<PlatformFacts> facts() async {
    final permissions = await this.permissions();
    return PlatformFacts(
      permissions: permissions,
      storageRoot: await storageRoot(),
      secure: secure,
      control: controlStateFrom(permissions['control']),
      read: true,
    );
  }

  @override
  Future<Map<String, PermissionState>> permissions() async {
    try {
      final answer = await channel.invokeMapMethod<String, Object?>(
        'permissions',
      );
      if (answer == null) return _unknown();
      return <String, PermissionState>{
        for (final name in const ['camera', 'microphone', 'screen', 'control'])
          name: _state(answer[name], answer['${name}Reason']),
      };
    } on MissingPluginException {
      return _unknown();
    } on PlatformException {
      return _unknown();
    }
  }

  @override
  Future<PermissionState> requestPermission(String name) async {
    try {
      final answer = await channel.invokeMethod<String>(
        'requestPermission',
        <String, Object?>{'name': name},
      );
      return _state(answer, null);
    } on MissingPluginException {
      return PermissionState.unknown;
    } on PlatformException catch (failure) {
      return PermissionState(
        PlatformPermission.denied,
        detail: failure.message,
      );
    }
  }

  @override
  Future<String?> storageRoot() async {
    try {
      final path = await channel.invokeMethod<String>('storageRoot');
      return path == null || path.isEmpty ? null : path;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<bool> seal(String key, String value) async {
    try {
      return await channel.invokeMethod<bool>(
            'secureWrite',
            <String, Object?>{'key': key, 'value': value},
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<String?> unseal(String key) async {
    try {
      return await channel.invokeMethod<String>(
        'secureRead',
        <String, Object?>{'key': key},
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> forget(String key) async {
    try {
      await channel.invokeMethod<void>(
        'secureDelete',
        <String, Object?>{'key': key},
      );
    } on MissingPluginException {
      // Nothing was ever sealed here.
    } on PlatformException {
      // Best effort: a failed delete leaves a secret the next write replaces.
    }
  }

  @override
  Future<bool> openControlSettings() async {
    try {
      await channel.invokeMethod<void>('controlSettings');
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static PermissionState _state(Object? value, Object? detail) {
    final text = '$value';
    return switch (text) {
      'available' => PermissionState(PlatformPermission.granted),
      'granted' => PermissionState(PlatformPermission.granted),
      'promptable' => PermissionState(PlatformPermission.promptable),
      'denied' => PermissionState(PlatformPermission.denied, detail: '$detail'),
      'disabled' => PermissionState(PlatformPermission.denied),
      'restricted' => PermissionState(PlatformPermission.unavailable),
      _ => PermissionState(
        PlatformPermission.unavailable,
        detail: detail == null ? null : '$detail',
      ),
    };
  }

  static Map<String, PermissionState> _unknown() => <String, PermissionState>{
    for (final name in const ['camera', 'microphone', 'screen', 'control'])
      name: PermissionState.unknown,
  };
}

/// The state of the phone's system control (its opt-in accessibility
/// service), as the OS reports it.
enum SystemControlState {
  /// The person enabled it; the pointer and keyboard can be offered.
  enabled,

  /// The service is declared but the person has not enabled it in the OS.
  disabled,

  /// This platform has no public way to inject input into other apps.
  unsupported,
}

/// The remote interaction a phone offers an agent.
///
/// Screen viewing is not control: this is the separate, powerful grant a
/// person makes, and it stays a person's until they withdraw it in the OS.
/// The vocabulary is the harness's `computer_pointer` and `computer_keyboard`
/// actions, so the endpoint maps one to the other without inventing a
/// dialect.  Nothing here can be granted by the app itself.
abstract class SystemControlPort {
  /// Whether this platform has any system control to offer at all.  It is
  /// known without asking the OS, so a page can say `System control off`
  /// rather than `No system control` while the OS's answer is on its way.
  bool get supported;

  Future<SystemControlState> state();

  /// Perform one pointer action.  Returns a machine reason: `ok`,
  /// `service-off`, `no-focus`, `unsupported`, `unavailable` or a platform
  /// message.
  Future<String> pointer({
    required String action,
    required double x,
    required double y,
    double? toX,
    double? toY,
    String? direction,
    int amount = 1,
  });

  /// Type text, or press one key (`delete`, `enter`), into the focused field.
  Future<String> keyboard({String? text, String? key});

  /// The OS's own settings page where the person enables or withdraws it.
  Future<bool> openSettings();
}

/// The control an Android build with the accessibility service offers.
class PlatformSystemControl implements SystemControlPort {
  const PlatformSystemControl({
    this.platform = const MethodChannelComputerPlatform(),
    this.channel = const MethodChannel('app.harness/computer_control'),
  });

  final ComputerPlatform platform;
  final MethodChannel channel;

  @override
  bool get supported => true;

  @override
  Future<SystemControlState> state() async =>
      controlStateFrom((await platform.permissions())['control']);

  @override
  Future<String> pointer({
    required String action,
    required double x,
    required double y,
    double? toX,
    double? toY,
    String? direction,
    int amount = 1,
  }) async {
    final verb = switch (action) {
      'click' => 'tap',
      'move' => 'tap',
      'scroll' => 'scroll',
      'drag' => 'drag',
      _ => null,
    };
    if (verb == null) return 'unsupported';
    if (verb == 'tap' && action == 'move') return 'unsupported';
    return _call(<String, Object?>{
      'action': verb,
      'x': x,
      'y': y,
      if (toX != null) 'toX': toX,
      if (toY != null) 'toY': toY,
      if (direction != null) 'direction': direction,
      'amount': amount,
    });
  }

  @override
  Future<String> keyboard({String? text, String? key}) async {
    if (text != null && text.isNotEmpty) {
      return _call(<String, Object?>{'action': 'type', 'text': text});
    }
    if (key != null && key.isNotEmpty) {
      return _call(<String, Object?>{'action': 'key', 'key': key});
    }
    return 'unsupported';
  }

  @override
  Future<bool> openSettings() => platform.openControlSettings();

  Future<String> _call(Map<String, Object?> arguments) async {
    try {
      return await channel.invokeMethod<String>('perform', arguments) ?? 'unavailable';
    } on MissingPluginException {
      return 'unsupported';
    } on PlatformException catch (failure) {
      return failure.message ?? 'unavailable';
    }
  }
}

/// What one permission answer means for the person's system control.  It is
/// the one mapping, so the endpoint, the page and the platform port cannot
/// disagree about whether the OS has the control on.
SystemControlState controlStateFrom(PermissionState? permission) =>
    switch (permission?.permission) {
      PlatformPermission.granted => SystemControlState.enabled,
      PlatformPermission.denied => SystemControlState.disabled,
      _ => SystemControlState.unsupported,
    };

/// The control of a platform with no public input injection: it offers
/// nothing and says why.  iOS is this case, deliberately.
class UnsupportedSystemControl implements SystemControlPort {
  const UnsupportedSystemControl([this.reason = 'unsupported']);

  final String reason;

  @override
  bool get supported => false;

  @override
  Future<SystemControlState> state() async => SystemControlState.unsupported;

  @override
  Future<String> pointer({
    required String action,
    required double x,
    required double y,
    double? toX,
    double? toY,
    String? direction,
    int amount = 1,
  }) async => reason;

  @override
  Future<String> keyboard({String? text, String? key}) async => reason;

  @override
  Future<bool> openSettings() async => false;
}

/// The platform this build runs on: a channel on Android and iOS, and none
/// elsewhere.
ComputerPlatform computerPlatformFor() {
  if (kIsWeb) return const _NoComputerPlatform();
  return switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS =>
      const MethodChannelComputerPlatform(),
    _ => const _NoComputerPlatform(),
  };
}

/// The system control this build has: Android's opt-in accessibility
/// service, nothing on iOS, and nothing on a desktop build (its own pointer is
/// not this phone's).
SystemControlPort systemControlFor() {
  if (kIsWeb) return const UnsupportedSystemControl('web-no-system-control');
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => const PlatformSystemControl(),
    TargetPlatform.iOS => const UnsupportedSystemControl('ios-no-system-injection'),
    _ => const UnsupportedSystemControl('desktop-uses-its-own-computer'),
  };
}

/// A build with no platform channel: no permission answers, the process's
/// temporary directory, no keystore and no control.
class _NoComputerPlatform implements ComputerPlatform {
  const _NoComputerPlatform();

  @override
  bool get secure => false;

  /// Nothing was asked, so nothing is claimed: the caller sees `Not checked`
  /// rather than a permission state this build cannot know.
  @override
  Future<PlatformFacts> facts() async => const PlatformFacts();

  @override
  Future<Map<String, PermissionState>> permissions() async =>
      MethodChannelComputerPlatform._unknown();

  @override
  Future<PermissionState> requestPermission(String name) async =>
      PermissionState.unknown;

  @override
  Future<String?> storageRoot() async => null;

  @override
  Future<bool> seal(String key, String value) async => false;

  @override
  Future<String?> unseal(String key) async => null;

  @override
  Future<void> forget(String key) async {}

  @override
  Future<bool> openControlSettings() async => false;
}

/// Which capability each platform permission belongs to, so the endpoint and
/// the page agree.
const Map<String, String> platformPermissionCapability = <String, String>{
  'camera': 'camera',
  'microphone': 'audio',
  'screen': 'view',
};

/// The capability state one platform permission means.
ComputerCapabilityStatus capabilityFromPermission(
  PermissionState? permission, {
  bool foregroundOnly = false,
  String? missing,
}) {
  if (permission == null) {
    return ComputerCapabilityStatus(
      state: ComputerCapabilityState.unavailable,
      detail: missing,
    );
  }
  return switch (permission.permission) {
    PlatformPermission.granted => ComputerCapabilityStatus(
      state: foregroundOnly
          ? ComputerCapabilityState.foregroundOnly
          : ComputerCapabilityState.available,
      detail: permission.detail,
    ),
    PlatformPermission.promptable => ComputerCapabilityStatus(
      state: ComputerCapabilityState.unavailable,
      detail: 'Permission prompt',
    ),
    PlatformPermission.denied => ComputerCapabilityStatus(
      state: ComputerCapabilityState.denied,
      detail: permission.detail,
    ),
    PlatformPermission.unavailable => ComputerCapabilityStatus(
      state: ComputerCapabilityState.unavailable,
      detail: permission.detail ?? missing,
    ),
  };
}

/// The sources a port may capture, keyed by the platform permission that
/// gates them.
const Map<ComputerCaptureSource, String> captureSourcePermission =
    <ComputerCaptureSource, String>{
      ComputerCaptureSource.screen: 'screen',
      ComputerCaptureSource.camera: 'camera',
      ComputerCaptureSource.microphone: 'microphone',
    };

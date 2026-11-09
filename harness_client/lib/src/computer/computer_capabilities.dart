/// The states a mobile computer's capabilities can be in.
///
/// A capability is offered to the harness only while it is [available] or
/// [foregroundOnly]; every other state is a reason it is not in the
/// registration's capability list, and a fact the user sees.  The names are
/// the wire vocabulary sent in `computer/update` under `capabilityStates`.
enum ComputerCapabilityState {
  available('available'),
  denied('denied'),
  revoked('revoked'),
  unavailable('unavailable'),
  foregroundOnly('foreground-only'),
  suspended('suspended'),
  error('error');

  const ComputerCapabilityState(this.wire);
  final String wire;

  /// Whether a capability in this state may be advertised as offered.
  bool get offered =>
      this == ComputerCapabilityState.available ||
      this == ComputerCapabilityState.foregroundOnly;

  static ComputerCapabilityState fromWire(Object? value) {
    final text = '$value';
    for (final state in values) {
      if (state.wire == text) return state;
    }
    return ComputerCapabilityState.unavailable;
  }
}

/// The labels people read for the capabilities a mobile computer offers.
const Map<String, String> computerCapabilityLabels = {
  'view': 'Screen',
  'camera': 'Camera',
  'audio': 'Microphone',
  'files': 'Files',
  'clipboard': 'Clipboard',
};

/// The states a mobile computer offers, by capability name, with a detail
/// for people (an OS prompt, a missing platform feature, a capture running).
class ComputerCapabilityStatus {
  const ComputerCapabilityStatus({required this.state, this.detail});

  final ComputerCapabilityState state;
  final String? detail;

  bool get offered => state.offered;

  String get label => switch (state) {
    ComputerCapabilityState.available => 'Available',
    ComputerCapabilityState.denied => 'Denied',
    ComputerCapabilityState.revoked => 'Revoked',
    ComputerCapabilityState.unavailable => 'Unavailable',
    ComputerCapabilityState.foregroundOnly => 'Foreground only',
    ComputerCapabilityState.suspended => 'Suspended',
    ComputerCapabilityState.error => 'Error',
  };

  Map<String, Object?> toWire() => <String, Object?>{
    'state': state.wire,
    if (detail != null && detail!.isNotEmpty) 'detail': detail,
  };
}

/// The capability set a phone advertises: only what the user enabled and the
/// platform can do, with the state of everything else kept visible.
class ComputerCapabilities {
  const ComputerCapabilities(this.byName);

  final Map<String, ComputerCapabilityStatus> byName;

  static const empty = ComputerCapabilities(
    <String, ComputerCapabilityStatus>{},
  );

  List<String> get offered => <String>[
    for (final entry in byName.entries)
      if (entry.value.offered) entry.key,
  ];

  ComputerCapabilityStatus? operator [](String name) => byName[name];

  Map<String, Object?> get statesWire => <String, Object?>{
    for (final entry in byName.entries) entry.key: entry.value.toWire(),
  };

  ComputerCapabilities withCapability(
    String name,
    ComputerCapabilityStatus status,
  ) {
    return ComputerCapabilities(<String, ComputerCapabilityStatus>{
      ...byName,
      name: status,
    });
  }
}

import '../acp/acp_message.dart';

/// A machine the harness may use, as `_harness/computer/list` answers it.
///
/// A computer is not a client and not a session's host: it offers **tools**
/// (MCP servers the client running there keeps) and **resources** (a git
/// repository, a directory, a display).  `capabilities` are the computer-use
/// ones its implementation really has, and [vnc] and [vncSocket] are where a
/// person and a client can see its screen.
class Computer {
  const Computer({
    required this.id,
    required this.name,
    this.kind = 'client',
    this.state = 'registered',
    this.implicit = false,
    this.connected = false,
    this.host,
    this.user,
    this.os,
    this.arch,
    this.display,
    this.vnc,
    this.vncSocket,
    this.windowScoped = false,
    this.control,
    this.controlSince,
    this.capabilityNames = const [],
    this.capabilities = const [],
    this.servers = const [],
    this.resources = const [],
    this.allowed,
    this.why,
    this.capabilitiesAllowed = const [],
    this.window,
    this.lastSeen,
    this.registeredAt,
  });

  factory Computer.fromWire(JsonMap wire) {
    return Computer(
      id: asStringOr(wire['id'], ''),
      name: asStringOr(wire['name'], 'Computer'),
      kind: asStringOr(wire['kind'], 'client'),
      state: asStringOr(wire['state'], 'registered'),
      implicit: asBool(wire['implicit']),
      connected: asBool(wire['connected']),
      host: asString(wire['host']),
      user: asString(wire['user']),
      os: asString(wire['os']),
      arch: asString(wire['arch']),
      display: asString(wire['display']),
      vnc: asString(wire['vnc']),
      vncSocket: asString(wire['vnc-socket'] ?? wire['vncSocket']),
      windowScoped: asBool(wire['window-scoped'] ?? wire['windowScoped']),
      control: asString(wire['control']),
      controlSince: _time(wire['control-since'] ?? wire['controlSince']),
      capabilityNames: [
        for (final name in asList(
          wire['capability-names'] ?? wire['capabilityNames'],
        ))
          if (asString(name) case final value? when value.isNotEmpty) value,
      ],
      capabilities: [
        for (final item in asMapList(wire['capabilities']))
          ComputerCapability.fromWire(item),
      ],
      servers: [
        for (final server in asList(wire['servers']))
          if (asString(server) case final value? when value.isNotEmpty) value,
      ],
      resources: [
        for (final item in asMapList(wire['resources']))
          ComputerResource.fromWire(item),
      ],
      allowed: wire.containsKey('allowed') ? asBool(wire['allowed']) : null,
      why: asString(wire['why']),
      capabilitiesAllowed: [
        for (final name in asList(
          wire['capabilities-allowed'] ?? wire['capabilitiesAllowed'],
        ))
          if (asString(name) case final value? when value.isNotEmpty) value,
      ],
      window: asString(wire['window']),
      lastSeen: _time(wire['last-seen'] ?? wire['lastSeen']),
      registeredAt: _time(wire['registered-at'] ?? wire['registeredAt']),
    );
  }

  /// A computer that a page can show with no harness behind it.
  factory Computer.preview({
    String id = 'local',
    String name = 'marcuse',
    String kind = 'local',
    String state = 'connected',
    bool connected = true,
    bool implicit = true,
    List<String> capabilities = const [
      'view',
      'windows',
      'pointer',
      'keyboard',
      'sandbox',
    ],
    String vnc = 'http://127.0.0.1:6080/vnc_lite.html',
    String? vncSocket = 'ws://127.0.0.1:6080/websockify?token=demo-token',
    List<ComputerResource> resources = const [],
  }) {
    return Computer(
      id: id,
      name: name,
      kind: kind,
      state: state,
      implicit: implicit,
      connected: connected,
      host: name,
      os: 'linux',
      arch: 'x86_64',
      display: ':99',
      control: 'agent',
      vnc: vnc,
      vncSocket: vncSocket,
      capabilities: [
        for (final capability in capabilities)
          ComputerCapability(name: capability, doc: _capabilityDoc(capability)),
      ],
      capabilityNames: capabilities,
      servers: const ['computer'],
      resources: resources,
      allowed: true,
      why: 'the local computer',
      capabilitiesAllowed: capabilities,
    );
  }

  final String id;
  final String name;
  final String kind;
  final String state;
  final bool implicit;
  final bool connected;
  final String? host;
  final String? user;
  final String? os;
  final String? arch;
  final String? display;
  final String? vnc;
  final String? vncSocket;
  final bool windowScoped;
  final String? control;
  final DateTime? controlSince;
  final List<String> capabilityNames;
  final List<ComputerCapability> capabilities;
  final List<String> servers;
  final List<ComputerResource> resources;

  /// From `computer/access`, when the page asked with a session: whether that
  /// session may use this computer, why, and which capabilities it may use.
  final bool? allowed;
  final String? why;
  final List<String> capabilitiesAllowed;
  final String? window;
  final DateTime? lastSeen;
  final DateTime? registeredAt;

  bool get isLocal => implicit || kind == 'local';
  bool get known => id.isNotEmpty;
  bool get viewable => (vncSocket ?? '').isNotEmpty || (vnc ?? '').isNotEmpty;
  bool get hasSocket => (vncSocket ?? '').isNotEmpty;

  /// `connected`, `registered` or `disconnected`, as a person reads it.
  String get stateLabel => switch (state) {
    'connected' => 'Connected',
    'registered' => 'Registered',
    'disconnected' => 'Disconnected',
    _ => 'Unknown',
  };

  String get kindLabel => switch (kind) {
    'local' => 'Local',
    'ssh' => 'SSH',
    _ => 'Client',
  };

  String get controlLabel => switch (control) {
    'user' => 'User',
    'agent' => 'Agent',
    _ => 'Nobody',
  };

  /// Whether [capability] is one this session may use here.
  bool allows(String capability) => capabilitiesAllowed.contains(capability);

  /// The computer-use capabilities the implementation offers, one line each.
  String get capabilityLine {
    if (capabilityNames.isEmpty) return 'No computer use';
    return capabilityNames.join(' · ');
  }

  Computer withAccess({
    bool? allowed,
    String? why,
    List<String>? capabilitiesAllowed,
    String? window,
  }) {
    return Computer(
      id: id,
      name: name,
      kind: kind,
      state: state,
      implicit: implicit,
      connected: connected,
      host: host,
      user: user,
      os: os,
      arch: arch,
      display: display,
      vnc: vnc,
      vncSocket: vncSocket,
      windowScoped: windowScoped,
      control: control,
      controlSince: controlSince,
      capabilityNames: capabilityNames,
      capabilities: capabilities,
      servers: servers,
      resources: resources,
      allowed: allowed ?? this.allowed,
      why: why ?? this.why,
      capabilitiesAllowed: capabilitiesAllowed ?? this.capabilitiesAllowed,
      window: window ?? this.window,
      lastSeen: lastSeen,
      registeredAt: registeredAt,
    );
  }
}

class ComputerCapability {
  const ComputerCapability({required this.name, this.doc});

  factory ComputerCapability.fromWire(JsonMap wire) => ComputerCapability(
    name: asStringOr(wire['name'], ''),
    doc: asString(wire['doc']),
  );

  final String name;
  final String? doc;

  String get label => switch (name) {
    'view' => 'View',
    'windows' => 'Windows',
    'pointer' => 'Pointer',
    'keyboard' => 'Keyboard',
    'clipboard' => 'Clipboard',
    'audio' => 'Audio',
    'sandbox' => 'Sandbox',
    'exec' => 'Exec',
    _ => name,
  };
}

/// A resource a computer offers: a git repository, a directory, a display.
class ComputerResource {
  const ComputerResource({
    required this.id,
    required this.kind,
    required this.name,
    this.path,
    this.branch,
    this.computer,
    this.computerName,
    this.project = false,
  });

  factory ComputerResource.fromWire(JsonMap wire) => ComputerResource(
    id: asStringOr(wire['id'], ''),
    kind: asStringOr(wire['kind'], 'directory'),
    name: asStringOr(wire['name'], 'Resource'),
    path: asString(wire['path']),
    branch: asString(wire['branch']),
    computer: asString(wire['computer']),
    computerName: asString(wire['computer-name'] ?? wire['computerName']),
    project: asBool(wire['project']),
  );

  final String id;
  final String kind;
  final String name;
  final String? path;
  final String? branch;
  final String? computer;
  final String? computerName;
  final bool project;

  String get kindLabel => switch (kind) {
    'git-repo' => 'Git repository',
    'directory' => 'Directory',
    'display' => 'Display',
    'gpu' => 'GPU',
    'audio' => 'Audio',
    _ => kind,
  };
}

/// `_harness/computer/access`: what one session may do on the computers.
class ComputerAccess {
  const ComputerAccess({
    required this.session,
    this.policy = 'local',
    this.preferred,
    this.revoked = const [],
    this.available = const [],
    this.entries = const [],
  });

  factory ComputerAccess.fromWire(JsonMap wire) => ComputerAccess(
    session: asStringOr(wire['session'], ''),
    policy: asStringOr(wire['policy'], 'local'),
    preferred: asString(wire['preferred']),
    revoked: [
      for (final id in asList(wire['revoked']))
        if (asString(id) case final value? when value.isNotEmpty) value,
    ],
    available: [
      for (final id in asList(wire['available']))
        if (asString(id) case final value? when value.isNotEmpty) value,
    ],
    entries: [
      for (final item in asMapList(wire['computers']))
        ComputerAccessEntry.fromWire(item),
    ],
  );

  final String session;
  final String policy;
  final String? preferred;
  final List<String> revoked;
  final List<String> available;
  final List<ComputerAccessEntry> entries;

  String get policyLabel => switch (policy) {
    'all' => 'Every computer',
    'none' => 'No computer',
    _ => 'The local computer',
  };

  ComputerAccessEntry? entry(String id) {
    for (final item in entries) {
      if (item.id == id) return item;
    }
    return null;
  }
}

class ComputerAccessEntry {
  const ComputerAccessEntry({
    required this.id,
    required this.name,
    this.kind = 'client',
    this.state = 'registered',
    this.connected = false,
    this.allowed = false,
    this.why,
    this.capabilitiesAllowed = const [],
    this.control,
    this.window,
  });

  factory ComputerAccessEntry.fromWire(JsonMap wire) => ComputerAccessEntry(
    id: asStringOr(wire['id'], ''),
    name: asStringOr(wire['name'], 'Computer'),
    kind: asStringOr(wire['kind'], 'client'),
    state: asStringOr(wire['state'], 'registered'),
    connected: asBool(wire['connected']),
    allowed: asBool(wire['allowed']),
    why: asString(wire['why']),
    capabilitiesAllowed: [
      for (final name in asList(
        wire['capabilities-allowed'] ?? wire['capabilitiesAllowed'],
      ))
        if (asString(name) case final value? when value.isNotEmpty) value,
    ],
    control: asString(wire['control']),
    window: asString(wire['window']),
  );

  final String id;
  final String name;
  final String kind;
  final String state;
  final bool connected;
  final bool allowed;
  final String? why;
  final List<String> capabilitiesAllowed;
  final String? control;
  final String? window;

  String get stateLabel => switch (state) {
    'connected' => 'Connected',
    'registered' => 'Registered',
    'disconnected' => 'Disconnected',
    _ => 'Unknown',
  };
}

DateTime? _time(Object? value) {
  if (value == null) return null;
  final seconds = asDouble(value);
  if (seconds == null) return null;
  return DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
}

String? _capabilityDoc(String name) => switch (name) {
  'view' => 'See the screen, or one window',
  'windows' => "List the desktop's windows",
  'pointer' => 'Move, click, scroll, drag',
  'keyboard' => 'Type text, press a key',
  'clipboard' => 'Read and write the clipboard',
  'audio' => 'List audio devices, record a little',
  'sandbox' => 'A desktop separate from the computer\'s own',
  'exec' => "Run the computer's extra tools",
  _ => null,
};

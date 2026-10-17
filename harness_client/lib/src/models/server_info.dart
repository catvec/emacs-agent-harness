import '../acp/acp_message.dart';

class HarnessVersion {
  const HarnessVersion({this.version, this.emacs, this.protocolVersion});

  factory HarnessVersion.fromWire(JsonMap wire) => HarnessVersion(
    version: asString(wire['version']),
    emacs: asString(wire['emacs']),
    protocolVersion: asInt(wire['protocolVersion'] ?? wire['protocol-version']),
  );

  final String? version;
  final String? emacs;
  final int? protocolVersion;
}

class HarnessModule {
  const HarnessModule({
    required this.name,
    this.description = '',
    this.optional = false,
    this.loaded = true,
  });

  factory HarnessModule.fromWire(JsonMap wire) => HarnessModule(
    name: asStringOr(wire['name'], asStringOr(wire['module'], '')),
    description: asStringOr(wire['description'], asStringOr(wire['doc'], '')),
    optional: asBool(wire['optional']),
    loaded: asBool(wire['loaded'], fallback: true),
  );

  final String name;
  final String description;
  final bool optional;
  final bool loaded;
}

class ProviderInfo {
  const ProviderInfo({
    required this.id,
    required this.label,
    this.doc = '',
    this.models = const [],
  });

  factory ProviderInfo.fromWire(JsonMap wire) => ProviderInfo(
    id: asStringOr(wire['id'], ''),
    label: asStringOr(wire['label'], asStringOr(wire['id'], '')),
    doc: asStringOr(wire['doc'], ''),
  );

  final String id;
  final String label;
  final String doc;
  final List<ModelInfo> models;
}

class ModelInfo {
  const ModelInfo({
    required this.id,
    required this.name,
    this.contextWindow,
    this.provider,
  });

  factory ModelInfo.fromWire(JsonMap wire) {
    final id = asStringOr(wire['id'], '');
    return ModelInfo(
      id: id,
      name: asStringOr(wire['name'], id),
      contextWindow: asInt(wire['contextWindow'] ?? wire['context-window']),
      provider: asString(wire['provider']),
    );
  }

  final String id;
  final String name;
  final int? contextWindow;
  final String? provider;
}

class ServerOverview {
  const ServerOverview({
    this.version,
    this.modules = const [],
    this.providers = const [],
    this.projects = const [],
    this.budgets = const [],
  });

  final HarnessVersion? version;
  final List<HarnessModule> modules;
  final List<ProviderInfo> providers;
  final List<String> projects;
  final List<JsonMap> budgets;
}

import 'acp_message.dart';

/// What an agent said it can do, in `initialize`'s answer.
///
/// Standard ACP fields drive the plain client; [methods] and [events] come
/// from the harness's `_harness` extension object.  Each enhanced view asks
/// [has] for the exact methods it needs, so a harness with only some
/// modules enabled degrades one panel at a time instead of all at once.
class HarnessCapabilities {
  HarnessCapabilities({
    required this.protocolVersion,
    required this.agentName,
    required this.agentVersion,
    required this.methods,
    required this.events,
    required this.authMethods,
    required this.loadSession,
    required this.sessionList,
    required this.promptImages,
    required this.promptAudio,
    required this.embeddedContext,
    this.raw = const <String, Object?>{},
  });

  factory HarnessCapabilities.fromInitialize(JsonMap result) {
    final agentInfo = asMap(result['agentInfo']);
    final agentCaps = asMap(result['agentCapabilities']);
    final promptCaps = asMap(agentCaps['promptCapabilities']);
    final sessionCaps = asMap(agentCaps['sessionCapabilities']);
    final harness = asMap(result['_harness']);
    final methods = <String>{
      for (final method in asList(harness['methods'])) asString(method) ?? '',
    }..remove('');
    final events = <String>{
      for (final event in asList(harness['events'])) asString(event) ?? '',
    }..remove('');
    final auth = <AuthMethod>[
      for (final method in asMapList(result['authMethods']))
        AuthMethod(
          id: asStringOr(method['id'], ''),
          name: asStringOr(method['name'], 'Authenticate'),
          description: asStringOr(method['description'], ''),
          url: asString(asMap(asMap(method['_meta'])['harness'])['url']),
        ),
    ];
    return HarnessCapabilities(
      protocolVersion: asInt(result['protocolVersion']) ?? 1,
      agentName: asStringOr(agentInfo['name'], 'ACP agent'),
      agentVersion: asStringOr(agentInfo['version'], ''),
      methods: methods,
      events: events,
      authMethods: auth,
      loadSession: asBool(agentCaps['loadSession']),
      sessionList: sessionCaps.containsKey('list'),
      promptImages: asBool(promptCaps['image']),
      promptAudio: asBool(promptCaps['audio']),
      embeddedContext: asBool(promptCaps['embeddedContext']),
      raw: result,
    );
  }

  final int protocolVersion;
  final String agentName;
  final String agentVersion;
  final Set<String> methods;
  final Set<String> events;
  final List<AuthMethod> authMethods;
  final bool loadSession;
  final bool sessionList;
  final bool promptImages;
  final bool promptAudio;
  final bool embeddedContext;
  final JsonMap raw;

  bool has(String method) => methods.contains(method);
  bool hasEvent(String event) => events.contains(event);

  /// A harness, rather than some other ACP agent.  Extensions may still be
  /// partial; feature getters below are the authority for each view.
  bool get isHarness =>
      methods.isNotEmpty ||
      events.isNotEmpty ||
      agentName.toLowerCase().contains('emacs-agent-harness') ||
      agentName.toLowerCase() == 'harness';

  bool get richNodes => has('session/nodes') && has('session/get');
  bool get activity =>
      has('agent/activity') || hasEvent('agent/activity-changed');
  bool get tasks => has('task/list');
  bool get taskActions => has('task/start') && has('task/verify');
  bool get taskSubmit => has('task/submit');
  bool get usage => has('usage/totals') || has('usage/summary');
  bool get liveUsage => has('usage/live-all');
  bool get budgets => has('usage/budgets');
  bool get providers => has('provider/list');
  bool get models => has('provider/models');

  /// The plan quota of the providers that report it (`provider/quota`),
  /// found through the list of providers.
  bool get quota => has('provider/quota') && has('provider/list');
  bool get projects => has('insights/projects');
  bool get search => has('session/search');
  bool get fork => has('session/fork');
  bool get deleteSession => has('session/delete');
  bool get renameSession => has('session/update');
  bool get config => has('config/describe');
  bool get questionImages => has('question/image');
  bool get harnessInfo => has('harness/version') || has('harness/api');
  bool get modules => has('harness/modules');
  bool get setMode => has('session/set_mode');
  bool get setModel => has('session/set_model');
  bool get priority => has('priority/set');
  bool get setNonInteractive => has('session/update');
  bool get setAllNonInteractive => has('session/set-all');

  /// How many enhanced methods the agent offers, for the discovery chip.
  int get extensionCount => methods.length;

  /// Feature rows for the discovery and server screens.
  List<CapabilityFeature> get features => [
    CapabilityFeature(
      'Sessions',
      'List, open and continue conversations',
      true,
      standard: true,
    ),
    CapabilityFeature(
      'Live transcript',
      'Streamed messages, thoughts, tools and plans',
      true,
      standard: true,
    ),
    CapabilityFeature(
      'Permission prompts',
      'Approve or deny a tool call from the phone',
      true,
      standard: true,
    ),
    CapabilityFeature(
      'Rich nodes',
      'Sender attribution, hints, compaction and final nodes',
      richNodes,
    ),
    CapabilityFeature('Activity', 'What the turn is doing right now', activity),
    CapabilityFeature(
      'Task board',
      'Start, review and verify harness tasks',
      tasks,
    ),
    CapabilityFeature(
      'Usage',
      'Spend, tokens, live sessions and budgets',
      usage,
    ),
    CapabilityFeature(
      'Plan quota',
      'How much of the plan is used, and when it resets',
      quota,
    ),
    CapabilityFeature(
      'Projects',
      'Pick a project directory for a new session',
      projects,
    ),
    CapabilityFeature(
      'Question images',
      'Show the diagrams an ask_user question carries',
      questionImages,
    ),
    CapabilityFeature(
      'Session search',
      'Search transcripts on the harness',
      search,
    ),
    CapabilityFeature('Fork', 'Branch a conversation', fork),
    CapabilityFeature(
      'Providers',
      'Browse the model catalogue',
      providers || models,
    ),
    CapabilityFeature(
      'Harness info',
      'Version, modules and API of the server',
      harnessInfo,
    ),
  ];
}

/// A way to sign in that an agent lists in `initialize`.
class AuthMethod {
  const AuthMethod({
    required this.id,
    required this.name,
    required this.description,
    this.url,
  });

  final String id;
  final String name;
  final String description;

  /// Where a browser goes for this method, when it has a page of its own
  /// (the harness's login at an OpenID Connect provider).
  final String? url;

  bool get isToken => id == 'token' || id == 'bearer';

  /// The harness asks the person at its Emacs.
  bool get isApproval => id == 'emacs-approval';

  /// The user signs in at the harness's identity provider, in a browser.
  bool get isOidc => id == 'oidc';

  /// The code the description tells the user to compare with the one the
  /// person who approves sees (four digits), when it holds one.
  String? get code => RegExp(r'code (\d{4})').firstMatch(description)?.group(1);
}

class CapabilityFeature {
  const CapabilityFeature(
    this.name,
    this.description,
    this.enabled, {
    this.standard = false,
  });

  final String name;
  final String description;
  final bool enabled;

  /// Standard ACP, not a harness extension.
  final bool standard;
}

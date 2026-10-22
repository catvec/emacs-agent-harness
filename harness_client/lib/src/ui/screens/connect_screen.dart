import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../acp/capabilities.dart';
import '../../acp/connection_target.dart';
import '../../models/session.dart';
import '../../state/app_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/mark.dart';
import '../app_scope.dart';
import '../format.dart';
import '../theme/harness_theme.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, required this.app});

  final AppController app;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  late final TextEditingController _address;
  late final TextEditingController _token;
  final _tokenFocus = FocusNode();
  bool _obscure = true;
  bool _remember = true;
  bool _rememberTouched = false;
  String? _localError;

  @override
  void initState() {
    super.initState();
    final settings = widget.app.settings;
    _address = TextEditingController(text: settings.address);
    _token = TextEditingController(text: settings.token);
    _remember = settings.rememberConnection;
    // The connection screen is shown before preferences have been read.  Fill
    // in the remembered address and token when they arrive, without
    // overwriting anything already typed.
    settings.addListener(_settingsChanged);
  }

  void _settingsChanged() {
    if (!mounted) return;
    final settings = widget.app.settings;
    if (_address.text.isEmpty && settings.address.isNotEmpty) {
      _address.text = settings.address;
    }
    if (_token.text.isEmpty && settings.token.isNotEmpty) {
      _token.text = settings.token;
    }
    if (!_rememberTouched && _remember != settings.rememberConnection) {
      setState(() => _remember = settings.rememberConnection);
    }
  }

  @override
  void dispose() {
    widget.app.settings.removeListener(_settingsChanged);
    _address.dispose();
    _token.dispose();
    _tokenFocus.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    FocusScope.of(context).unfocus();
    setState(() => _localError = null);
    try {
      ConnectionTarget.parse(_address.text, web: kIsWeb);
    } on FormatException catch (failure) {
      setState(() => _localError = failure.message);
      return;
    }
    // Saving is best-effort and must not delay the connection when the
    // platform's preference store is slow or unavailable.
    unawaited(
      HarnessScope.settingsOf(context).setRememberConnection(_remember),
    );
    await widget.app.connect(_address.text, token: _token.text.trim());
    if (mounted) {
      // The connection screen is replaced on success; this only keeps a
      // keyboard from covering the error that remains.
      setState(() {});
    }
    if (mounted && widget.app.error != null) {
      // Give the field a chance to scroll into view on small screens.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (mounted) {
      _tokenFocus.unfocus();
    }
  }

  Future<void> _unlock() async {
    FocusScope.of(context).unfocus();
    setState(() => _localError = null);
    await widget.app.submitToken(_token.text.trim());
    if (mounted) setState(() {});
  }

  Future<void> _signIn(AuthMethod method) async {
    FocusScope.of(context).unfocus();
    setState(() => _localError = null);
    await widget.app.signIn(method);
    if (mounted) setState(() {});
  }

  String get _addressHint {
    if (kIsWeb) return 'ws://HOST:4276/acp';
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      return 'ws://192.168.1.20:4276/acp';
    }
    return 'tcp://127.0.0.1:4276 or ws://…';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = widget.app;
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Stack(
        children: [
          const Positioned.fill(
            child: IgnorePointer(child: _ConnectBackdrop()),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 26, 22, 40),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          HarnessWordmark(
                            size: 34,
                            color: theme.colorScheme.onSurface,
                            subtitle: 'AGENT CLIENT',
                          ),
                          const Spacer(),
                          HarnessStatusPill(
                            label: 'ACP 1',
                            color: theme.colorScheme.primary,
                            icon: Icons.cable_rounded,
                          ),
                        ],
                      ),
                      const SizedBox(height: 38),
                      if (app.resuming)
                        ..._resumeSection(theme)
                      else
                        ..._formSection(theme),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The form for an address and a secret, and the ways to sign in: for a
  /// device that has no harness to go back into, or that the harness
  /// turned away.
  List<Widget> _formSection(ThemeData theme) {
    final app = widget.app;
    final waiting = app.signingInWith != null;
    final busy =
        app.phase == ConnectionPhase.connecting ||
        (app.phase == ConnectionPhase.authenticating && !waiting);
    final error = _localError ?? app.error;
    return [
      Text(
        'Your agents,\nwithin reach.',
        style: theme.textTheme.displaySmall?.copyWith(
          fontSize: 42,
          height: 1.02,
          fontWeight: FontWeight.w700,
          letterSpacing: -1.8,
        ),
      ),
      const SizedBox(height: 14),
      Text(
        'A native client for the emacs-agent-harness. '
        'Watch every step, answer when it needs you, and keep '
        'the work moving from your phone or desktop.',
        style: theme.textTheme.bodyLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          height: 1.5,
        ),
      ),
      const SizedBox(height: 26),
      _ConnectionCard(
        address: _address,
        token: _token,
        addressHint: _addressHint,
        obscure: _obscure,
        remember: _remember,
        busy: busy,
        onRemember: (value) => setState(() {
          _remember = value;
          _rememberTouched = true;
        }),
        onObscure: () => setState(() => _obscure = !_obscure),
        onConnect: busy ? null : _connect,
      ),
      if (error != null && error.trim().isNotEmpty) ...[
        const SizedBox(height: 12),
        HarnessErrorBanner(
          message: error,
          onDismiss: () {
            setState(() => _localError = null);
            app.clearActionError();
          },
        ),
      ],
      if (app.phase == ConnectionPhase.needsAuth || waiting) ...[
        const SizedBox(height: 14),
        _AuthCard(
          app: app,
          token: _token,
          busy: busy,
          onUnlock: busy ? null : _unlock,
          onSignIn: _signIn,
          onCancel: () => widget.app.cancelSignIn(),
        ),
      ],
      if (app.capability != null && app.phase != ConnectionPhase.connected) ...[
        const SizedBox(height: 14),
        _DiscoveryCard(app: app),
      ],
      const SizedBox(height: 28),
      _FeatureTeaser(),
      const SizedBox(height: 22),
      Center(
        child: Text(
          'JSON-RPC 2.0 · WebSocket or TCP · your network, your machine',
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            letterSpacing: 0.2,
          ),
        ),
      ),
    ];
  }

  /// A device that remembers its harness: the app goes back in by itself,
  /// with the session it kept, and the person has nothing to type.
  List<Widget> _resumeSection(ThemeData theme) => [
    Text(
      'Welcome\nback.',
      style: theme.textTheme.displaySmall?.copyWith(
        fontSize: 42,
        height: 1.02,
        fontWeight: FontWeight.w700,
        letterSpacing: -1.8,
      ),
    ),
    const SizedBox(height: 14),
    Text(
      'This device is signed in. The app is going back into the harness by '
      'itself, with the session it kept: there is nothing to type.',
      style: theme.textTheme.bodyLarge?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        height: 1.5,
      ),
    ),
    const SizedBox(height: 26),
    _ResumeCard(app: widget.app),
  ];
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.address,
    required this.token,
    required this.addressHint,
    required this.obscure,
    required this.remember,
    required this.busy,
    required this.onRemember,
    required this.onObscure,
    required this.onConnect,
  });

  final TextEditingController address;
  final TextEditingController token;
  final String addressHint;
  final bool obscure;
  final bool remember;
  final bool busy;
  final ValueChanged<bool> onRemember;
  final VoidCallback onObscure;
  final VoidCallback? onConnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: theme.brightness == Brightness.dark ? 0.22 : 0.05,
            ),
            blurRadius: 30,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'CONNECT',
                style: theme.textTheme.labelSmall?.copyWith(
                  letterSpacing: 1.3,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: busy ? HarnessColors.amber : HarnessColors.moss,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                busy ? 'Working' : 'Ready',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _FieldLabel('SERVER ADDRESS'),
          const SizedBox(height: 7),
          Semantics(
            textField: true,
            label: 'Server address',
            child: HarnessTextField(
              key: const Key('connect-address'),
              controller: address,
              hint: addressHint,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              prefix: Icon(
                Icons.link_rounded,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 14),
          _FieldLabel('SESSION SECRET'),
          const SizedBox(height: 7),
          Semantics(
            textField: true,
            label: 'Session secret',
            child: HarnessTextField(
              key: const Key('connect-token'),
              controller: token,
              hint: 'Only if you were given one',
              obscure: obscure,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => onConnect?.call(),
              prefix: Icon(
                Icons.key_rounded,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              suffix: HarnessIconButton(
                icon: obscure
                    ? Icons.visibility_rounded
                    : Icons.visibility_off_rounded,
                label: obscure ? 'Show token' : 'Hide token',
                size: 18,
                onPressed: onObscure,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Stay signed in here: reconnect when the app opens.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              HarnessSwitch(value: remember, onChanged: onRemember),
            ],
          ),
          const SizedBox(height: 16),
          HarnessPrimaryButton(
            key: const Key('connect-button'),
            label: busy ? 'Connecting…' : 'Connect',
            icon: busy ? null : Icons.arrow_forward_rounded,
            busy: busy,
            expand: true,
            onPressed: onConnect,
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.lightbulb_outline_rounded,
                size: 15,
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.7,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'In Emacs press C-c h P, start serving, and enter the ACP '
                  'address it shows. This app then asks how to sign in: '
                  'choose Approve in Emacs and press Approve there.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.78,
                    ),
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// What shows while the app goes back into the harness this device
/// remembers: where, what the last try said when it did not work, and the two
/// things a person may want then.  It is not a form: the address and the
/// secret are known.
class _ResumeCard extends StatelessWidget {
  const _ResumeCard({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = app.resumeError;
    final where = shortAddress(app.address ?? app.settings.address);
    return Container(
      key: const Key('resume-card'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: theme.brightness == Brightness.dark ? 0.22 : 0.05,
            ),
            blurRadius: 30,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Announced when it comes up, to somebody who cannot see it: what
          // it says is read out as it is written.
          Semantics(
            container: true,
            liveRegion: true,
            child: Row(
              children: [
                const HarnessActivity(radius: 10),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Reconnecting…',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        where,
                        key: const Key('resume-address'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (detail != null && detail.isNotEmpty) ...[
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 1),
                  child: Icon(
                    Icons.info_outline_rounded,
                    size: 15,
                    color: HarnessColors.amber,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    detail,
                    key: const Key('resume-detail'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (app.waitingToRetry)
                HarnessSecondaryButton(
                  key: const Key('resume-retry'),
                  label: 'Retry now',
                  icon: Icons.refresh_rounded,
                  onPressed: app.retryNow,
                ),
              HarnessTextButton(
                key: const Key('resume-change'),
                label: 'Use another address',
                onPressed: app.cancelResume,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        letterSpacing: 1.1,
        fontWeight: FontWeight.w700,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _AuthCard extends StatelessWidget {
  const _AuthCard({
    required this.app,
    required this.token,
    required this.busy,
    required this.onUnlock,
    required this.onSignIn,
    required this.onCancel,
  });

  final AppController app;
  final TextEditingController token;
  final bool busy;
  final VoidCallback? onUnlock;
  final ValueChanged<AuthMethod> onSignIn;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final waitingFor = app.signingInWith;
    final methods = app.signInMethods;
    final canToken = app.canUseToken || (methods.isEmpty && !busy);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.lock_outline_rounded,
                size: 19,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  'Sign in to this harness',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (waitingFor != null)
            _Waiting(method: waitingFor, onCancel: onCancel)
          else ...[
            Text(
              methods.isEmpty
                  ? 'This harness needs this device to sign in with a '
                        'session secret: put it in the field above.'
                  : 'Choose how this device signs in. The harness keeps a '
                        'session for it, so the next connection needs none.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            if (busy) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  HarnessActivity(radius: 8),
                  const SizedBox(width: 10),
                  Text(
                    'Checking the session…',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ],
            for (final method in methods) ...[
              const SizedBox(height: 14),
              if (method.isApproval)
                HarnessPrimaryButton(
                  key: Key('signin-${method.id}'),
                  label: method.name,
                  icon: Icons.verified_user_outlined,
                  expand: true,
                  onPressed: busy ? null : () => onSignIn(method),
                )
              else
                HarnessSecondaryButton(
                  key: Key('signin-${method.id}'),
                  label: method.name,
                  icon: method.isOidc ? Icons.open_in_new_rounded : null,
                  expand: true,
                  onPressed: busy ? null : () => onSignIn(method),
                ),
              if (method.description.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  method.description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
              ],
            ],
            if (canToken) ...[
              const SizedBox(height: 14),
              HarnessSecondaryButton(
                label: 'Unlock with the token above',
                icon: Icons.key_rounded,
                expand: true,
                onPressed: onUnlock,
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// What shows while the harness waits for the user to do what a method asks.
class _Waiting extends StatelessWidget {
  const _Waiting({required this.method, required this.onCancel});

  final AuthMethod method;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final code = method.code;
    final what = method.isOidc
        ? 'Finish signing in in the browser. When it asks, confirm the code'
        : 'Emacs asks to approve this device. Check that it shows the code';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            HarnessActivity(radius: 8),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                method.isOidc
                    ? 'Waiting for your sign-in'
                    : 'Waiting for approval in Emacs',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          what,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        if (code != null) ...[
          const SizedBox(height: 8),
          Center(
            child: Text(
              code,
              key: const Key('signin-code'),
              style: theme.textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 6,
              ),
            ),
          ),
        ],
        const SizedBox(height: 10),
        Text(
          method.isOidc
              ? 'Come back here once the page says you are signed in.'
              : 'Then press Approve there (C-c h y). Nothing to type here.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 12),
        HarnessSecondaryButton(
          key: const Key('signin-cancel'),
          label: 'Cancel',
          expand: true,
          onPressed: onCancel,
        ),
      ],
    );
  }
}

class _DiscoveryCard extends StatelessWidget {
  const _DiscoveryCard({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final caps = app.capability!;
    final enabled = caps.features.where((feature) => feature.enabled).length;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              HarnessMark(size: 22, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  caps.agentName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              HarnessStatusPill(
                label: caps.isHarness
                    ? '${caps.extensionCount} extensions'
                    : 'Standard ACP',
                color: caps.isHarness
                    ? HarnessColors.moss
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${caps.agentVersion.isEmpty ? '' : 'v${caps.agentVersion} · '}'
            'ACP ${caps.protocolVersion} · $enabled features detected',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final feature
                  in caps.features.where((feature) => feature.enabled).take(7))
                HarnessStatusPill(
                  label: feature.name,
                  color: feature.standard
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.primary,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FeatureTeaser extends StatelessWidget {
  const _FeatureTeaser();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = [
      (
        Icons.bolt_rounded,
        'Watch it think',
        'Streaming answers, tool calls, plans and the exact step the agent is on.',
      ),
      (
        Icons.shield_outlined,
        'Answer in context',
        'Approve a command, allow a directory, or answer a question with its diagrams.',
      ),
      (
        Icons.grid_view_rounded,
        'Go beyond chat',
        'The task board, usage and project views appear when your harness offers them.',
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 470;
        final cards = [
          for (final item in items)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow.withValues(
                  alpha: 0.6,
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(item.$1, size: 19, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.$2,
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          item.$3,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ];
        if (narrow) {
          return Column(
            children: [
              for (var index = 0; index < cards.length; index++) ...[
                if (index > 0) const SizedBox(height: 8),
                cards[index],
              ],
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var index = 0; index < cards.length; index++) ...[
              if (index > 0) const SizedBox(width: 8),
              Expanded(child: cards[index]),
            ],
          ],
        );
      },
    );
  }
}

class _ConnectBackdrop extends StatelessWidget {
  const _ConnectBackdrop();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      children: [
        Positioned(
          top: -120,
          left: -80,
          width: 420,
          height: 420,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  HarnessColors.oxide.withValues(alpha: dark ? 0.18 : 0.12),
                  HarnessColors.oxide.withValues(alpha: 0),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          right: -110,
          bottom: -100,
          child: Opacity(
            opacity: dark ? 0.035 : 0.045,
            child: HarnessMark(
              size: 420,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ],
    );
  }
}

/// Small helper used by task and session surfaces to label a session.
String sessionSubtitle(SessionSummary session) {
  final model = session.model;
  return model == null || model.isEmpty
      ? projectName(session.project ?? session.cwd)
      : '${projectName(session.project ?? session.cwd)} · ${modelName(model)}';
}

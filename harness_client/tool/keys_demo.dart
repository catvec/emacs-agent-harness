// A window to try the client's keys without a harness: the real
// Settings › Keys on the left, and a message box with the harness's C-c
// commands on the right.
//
//   harness_client/tool/keys_demo.sh
//
// The settings are the app's own, so a choice made here is the one the app
// keeps.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/app_scope.dart';
import 'package:harness_client/src/ui/harness_keys.dart';
import 'package:harness_client/src/ui/screens/settings_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/message_composer.dart';

void main() => runApp(const KeysDemoApp());

class KeysDemoApp extends StatefulWidget {
  const KeysDemoApp({super.key});

  @override
  State<KeysDemoApp> createState() => _KeysDemoAppState();
}

class _KeysDemoAppState extends State<KeysDemoApp> {
  final _settings = SettingsController();
  late final _app = AppController(settings: _settings);
  final _composerKey = GlobalKey<MessageComposerState>();
  final _scroll = ScrollController();
  final _sent = <String>[];

  @override
  void initState() {
    super.initState();
    // A demo opened twice starts from the keys it was left with, as the app
    // does; a phone's store is what remembers them.
    unawaited(_settings.load());
  }

  static const _reply =
      'The keys are the harness\'s own: C-c C-c sends, C-c C-k stops, '
      'C-c C-w copies this reply.';

  @override
  void dispose() {
    _app.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _copyLastReply() {
    unawaited(Clipboard.setData(const ClipboardData(text: _reply)));
    _say('Last reply copied');
  }

  void _jumpToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return HarnessStyle(
      style: HarnessPlatformStyle.material,
      child: HarnessScope(
        app: _app,
        settings: _settings,
        child: MaterialApp(
          title: 'Keys demo',
          debugShowCheckedModeBanner: false,
          theme: HarnessTheme.material(Brightness.dark),
          home: Scaffold(
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: SettingsScreen(app: _app)),
                const VerticalDivider(width: 1),
                Expanded(child: _conversation(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The message box under the harness's C-c commands, as a conversation has
  /// them: send, stop, attach, search, copy the last reply and jump to it.
  Widget _conversation(BuildContext context) {
    return HarnessKeyLayer(
      commands: {
        LogicalKeyboardKey.keyC: () => _composerKey.currentState?.sendNow(),
        LogicalKeyboardKey.keyK: () => _say('Nothing running'),
        LogicalKeyboardKey.keyA: () => _say('No images'),
        LogicalKeyboardKey.keyS: () => _say('No harness'),
        LogicalKeyboardKey.keyW: _copyLastReply,
        LogicalKeyboardKey.keyE: _jumpToBottom,
      },
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 18, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'A conversation, without a harness',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'C-c commands with Harness keys on',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                const SizedBox(height: 8),
                _Bubble(text: _reply, mine: false),
                for (final text in _sent) _Bubble(text: text, mine: true),
                const SizedBox(height: 12),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: MessageComposer(
              key: _composerKey,
              autofocus: true,
              onSend: (text, _) {
                setState(() => _sent.add(text));
                return true;
              },
              onStop: () {},
              running: false,
              cancelling: false,
              canAttach: false,
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.text, required this.mine});

  final String text;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: mine
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text),
      ),
    );
  }
}

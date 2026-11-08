import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app_scope.dart';

/// Whether the keyboard of this platform has the Control key these commands
/// are typed with.  A phone's on-screen keyboard has none, and sends no key
/// events for it; a hardware one that does still reaches these handlers.
bool get harnessControlKeyboard =>
    kIsWeb ||
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.windows;

/// An Emacs prefix: C-c, then one more key with Control.  The commands are
/// the screen's, by the key that follows the prefix.  A key the screen has
/// no command for is taken by the prefix all the same, as Emacs's beep is:
/// it never types itself into the text.
class EmacsPrefix {
  EmacsPrefix({Map<LogicalKeyboardKey, VoidCallback> commands = const {}})
    : _commands = Map<LogicalKeyboardKey, VoidCallback>.of(commands);

  Map<LogicalKeyboardKey, VoidCallback> _commands;

  bool _pending = false;

  /// Whether C-c was typed and the next key is a command of the prefix.
  bool get pending => _pending;

  /// The commands the prefix runs, by the key after it.  A screen whose
  /// commands come and go (the composer's send, say) sets them here.
  set commands(Map<LogicalKeyboardKey, VoidCallback> commands) {
    _commands = Map<LogicalKeyboardKey, VoidCallback>.of(commands);
    if (_commands.isEmpty) _pending = false;
  }

  /// Forget a prefix that was begun and not finished.
  void reset() => _pending = false;

  /// Runs [event] as the prefix.  Whether it took the key: a field that gets
  /// false leaves it to its usual meaning.
  KeyEventResult handle(KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (!_pending) {
      final begins =
          event.logicalKey == LogicalKeyboardKey.keyC &&
          keyboard.isControlPressed &&
          !keyboard.isAltPressed &&
          !keyboard.isMetaPressed;
      if (!begins) return KeyEventResult.ignored;
      _pending = true;
      return KeyEventResult.handled;
    }
    _pending = false;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      return KeyEventResult.handled;
    }
    if (keyboard.isControlPressed) {
      final command = _commands[event.logicalKey];
      if (command != null) {
        command();
        return KeyEventResult.handled;
      }
    }
    // An undefined C-c key, as Emacs answers one: the key goes nowhere, and
    // is not typed into the words.
    return KeyEventResult.handled;
  }
}

/// The C-c commands of a screen: the Emacs harness's own bindings, for the
/// functions this screen has.  A command runs when the focus is anywhere in
/// the subtree, the message field included.
///
///   C-c C-c  send the message          C-c C-k  stop the turn
///   C-c C-a  attach images             C-c C-s  quick search
///   C-c C-w  copy the last reply        C-c C-e  jump to the bottom
///
/// The setting [SettingsController.harnessKeys] turns them on; [enabled]
/// overrides it for a test, or for a screen that has a command of its own.
class HarnessKeyLayer extends StatefulWidget {
  const HarnessKeyLayer({
    super.key,
    required this.commands,
    required this.child,
    this.enabled,
  });

  final Map<LogicalKeyboardKey, VoidCallback> commands;
  final Widget child;
  final bool? enabled;

  @override
  State<HarnessKeyLayer> createState() => _HarnessKeyLayerState();
}

class _HarnessKeyLayerState extends State<HarnessKeyLayer> {
  final _prefix = EmacsPrefix();
  bool _enabled = false;

  @override
  Widget build(BuildContext context) {
    _enabled =
        harnessControlKeyboard &&
        (widget.enabled ??
            HarnessScope.maybeSettingsOf(context)?.harnessKeys ??
            false);
    _prefix.commands = widget.commands;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: widget.child,
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_enabled) {
      _prefix.reset();
      return KeyEventResult.ignored;
    }
    return _prefix.handle(event);
  }
}

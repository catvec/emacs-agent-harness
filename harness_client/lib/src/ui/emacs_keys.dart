import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// What Emacs's kill commands took, most recent last: one ring for the app,
/// so that a line killed in one field can be yanked into another.  It is
/// kept for the run of the app, like a clipboard; it is never written to the
/// device.
class KillRing {
  KillRing();

  /// The ring the app's text fields share.
  static final KillRing shared = KillRing();

  static const _limit = 60;

  final List<String> _entries = <String>[];

  /// The kills, oldest first.
  List<String> get entries => List<String>.unmodifiable(_entries);

  /// What C-y yanks: the last kill.
  String? get last => _entries.isEmpty ? null : _entries.last;

  void push(String text) {
    if (text.isEmpty) return;
    _entries.add(text);
    if (_entries.length > _limit) _entries.removeAt(0);
  }

  /// Forget every kill.  The app never does; a test does, so that one does
  /// not yank what another killed.
  void clear() => _entries.clear();
}

/// The Emacs keys a text field answers to when `SettingsController
/// .emacsEditing` is on.  One of these belongs to each field, because the
/// mark and the last yank are the field's own; the kill ring is shared.
///
/// Keys with Control:
///
///   C-a  beginning of line          C-e  end of line
///   C-f  forward one character      C-b  backward one character
///   C-n  next line                  C-p  previous line
///   C-k  kill to the end of line    C-y  yank
///   C-d  delete forward             C-w  kill the region
///   C-space  set the mark           C-g  drop the mark and the selection
///   C-t  transpose two characters   C-o  open a line
///
/// Keys with Alt (Meta):
///
///   M-f  forward one word           M-b  backward one word
///   M-d  kill the next word         M-Backspace  kill the previous word
///   M-w  copy the region            M-y  yank the next kill
///   M-<  beginning of the field     M->  end of the field
///
/// A mark set with C-space makes the movement commands select; otherwise
/// they move the cursor.  The keys not named here are left to the field.
class EmacsEditing {
  EmacsEditing({KillRing? killRing}) : ring = killRing ?? KillRing.shared;

  final KillRing ring;

  /// Where C-space put the mark, while a movement still selects from it.
  int? _mark;

  int _yankStart = -1;
  int _yankEnd = -1;
  int _yankIndex = -1;

  /// Where the mark is, for the tests; null between commands.
  int? get mark => _mark;

  /// Runs [event] as an Emacs editing key.  Whether it was one: a field that
  /// gets false leaves the key to its usual meaning (typing, copy, undo).
  bool handle(TextEditingController controller, KeyEvent event) {
    if (event is KeyUpEvent) return false;
    final keyboard = HardwareKeyboard.instance;
    final control = keyboard.isControlPressed;
    final alt = keyboard.isAltPressed;
    // One of the two, not both, and no window manager key: Emacs would not
    // see a C-M- key or a Super one as these either.
    if (control == alt || keyboard.isMetaPressed) return false;
    final value = controller.value;
    final text = value.text;
    final selection = value.selection;
    final point = _point(selection, text.length);
    _dropStaleMark(selection, point);

    if (control) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.keyA:
          return _motion(controller, text, _lineStart(text, point));
        case LogicalKeyboardKey.keyE:
          return _motion(controller, text, _lineEnd(text, point));
        case LogicalKeyboardKey.keyF:
          if (_mark == null && selection.isValid && !selection.isCollapsed) {
            return _collapse(controller, selection.end);
          }
          return _motion(controller, text, point + 1);
        case LogicalKeyboardKey.keyB:
          if (_mark == null && selection.isValid && !selection.isCollapsed) {
            return _collapse(controller, selection.start);
          }
          return _motion(controller, text, point - 1);
        case LogicalKeyboardKey.keyN:
          return _motion(controller, text, _nextLine(text, point));
        case LogicalKeyboardKey.keyP:
          return _motion(controller, text, _previousLine(text, point));
        case LogicalKeyboardKey.keyD:
          return _deleteForward(controller, value, text, selection, point);
        case LogicalKeyboardKey.keyK:
          return _killLine(controller, value, text, selection, point);
        case LogicalKeyboardKey.keyY:
          return _yank(controller, value, text, selection, point);
        case LogicalKeyboardKey.keyW:
          return _killRegion(controller, value, text, selection, point);
        case LogicalKeyboardKey.keyG:
          _mark = null;
          return _collapse(controller, point);
        case LogicalKeyboardKey.space:
          _mark = point;
          return _collapse(controller, point);
        case LogicalKeyboardKey.keyT:
          return _transpose(controller, value, text, point);
        case LogicalKeyboardKey.keyO:
          controller.value = TextEditingValue(
            text: '${text.substring(0, point)}\n${text.substring(point)}',
            selection: TextSelection.collapsed(offset: point),
          );
          _mark = null;
          return true;
      }
      return false;
    }

    final shift = keyboard.isShiftPressed;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.keyF:
        if (_mark == null && selection.isValid && !selection.isCollapsed) {
          return _collapse(controller, selection.end);
        }
        return _motion(controller, text, _forwardWord(text, point));
      case LogicalKeyboardKey.keyB:
        if (_mark == null && selection.isValid && !selection.isCollapsed) {
          return _collapse(controller, selection.start);
        }
        return _motion(controller, text, _backwardWord(text, point));
      case LogicalKeyboardKey.keyD:
        return _killWord(controller, value, text, point, forward: true);
      case LogicalKeyboardKey.backspace:
        return _killWord(controller, value, text, point, forward: false);
      case LogicalKeyboardKey.keyW:
        return _copyRegion(value, text, selection, point);
      case LogicalKeyboardKey.keyY:
        return _yankPop(controller, value, text);
      case LogicalKeyboardKey.comma when shift:
        return _motion(controller, text, 0);
      case LogicalKeyboardKey.period when shift:
        return _motion(controller, text, text.length);
    }
    return false;
  }

  /// Move the cursor to [offset], or to it from the mark when one is set.
  bool _motion(TextEditingController controller, String text, int offset) {
    final target = offset.clamp(0, text.length);
    final mark = _mark;
    controller.value = controller.value.copyWith(
      selection: mark == null
          ? TextSelection.collapsed(offset: target)
          : TextSelection(baseOffset: mark, extentOffset: target),
    );
    return true;
  }

  /// Leave the selection at [offset], with nothing selected.
  bool _collapse(TextEditingController controller, int offset) {
    final length = controller.text.length;
    controller.value = controller.value.copyWith(
      selection: TextSelection.collapsed(offset: offset.clamp(0, length)),
    );
    return true;
  }

  bool _deleteForward(
    TextEditingController controller,
    TextEditingValue value,
    String text,
    TextSelection selection,
    int point,
  ) {
    final region = _region(selection, text.length, point);
    if (region != null) {
      _setText(
        controller,
        text.replaceRange(region.$1, region.$2, ''),
        region.$1,
      );
      _mark = null;
      return true;
    }
    if (point >= text.length) return true;
    _setText(controller, text.replaceRange(point, point + 1, ''), point);
    _mark = null;
    return true;
  }

  bool _killLine(
    TextEditingController controller,
    TextEditingValue value,
    String text,
    TextSelection selection,
    int point,
  ) {
    if (_hasRegion(selection, point)) {
      return _killRegion(controller, value, text, selection, point);
    }
    final end = _lineEnd(text, point);
    if (end > point) {
      ring.push(text.substring(point, end));
      _setText(controller, text.replaceRange(point, end, ''), point);
    } else if (point < text.length) {
      // At the end of a line, C-k takes its newline with it.
      ring.push(text.substring(point, point + 1));
      _setText(controller, text.replaceRange(point, point + 1, ''), point);
    }
    _mark = null;
    _yankStart = -1;
    return true;
  }

  bool _killRegion(
    TextEditingController controller,
    TextEditingValue value,
    String text,
    TextSelection selection,
    int point,
  ) {
    final region = _region(selection, text.length, point);
    if (region == null) {
      _mark = null;
      return true;
    }
    ring.push(text.substring(region.$1, region.$2));
    _setText(
      controller,
      text.replaceRange(region.$1, region.$2, ''),
      region.$1,
    );
    _mark = null;
    _yankStart = -1;
    return true;
  }

  bool _copyRegion(
    TextEditingValue value,
    String text,
    TextSelection selection,
    int point,
  ) {
    final region = _region(selection, text.length, point);
    if (region != null) {
      unawaited(
        Clipboard.setData(
          ClipboardData(text: text.substring(region.$1, region.$2)),
        ),
      );
    }
    _mark = null;
    return true;
  }

  bool _yank(
    TextEditingController controller,
    TextEditingValue value,
    String text,
    TextSelection selection,
    int point,
  ) {
    final last = ring.last;
    if (last == null) return true;
    final start = selection.isValid && !selection.isCollapsed
        ? selection.start
        : point;
    final end = selection.isValid && !selection.isCollapsed
        ? selection.end
        : point;
    final yanked = text.replaceRange(start, end, last);
    controller.value = TextEditingValue(
      text: yanked,
      selection: TextSelection.collapsed(offset: start + last.length),
    );
    _yankStart = start;
    _yankEnd = start + last.length;
    _yankIndex = ring.entries.length - 1;
    _mark = null;
    return true;
  }

  /// Replace the words C-y just put in with the kill before them, as M-y
  /// does straight after a yank.
  bool _yankPop(
    TextEditingController controller,
    TextEditingValue value,
    String text,
  ) {
    final index = _yankIndex - 1;
    if (_yankStart < 0 || _yankEnd > text.length || index < 0) {
      _yankStart = -1;
      return true;
    }
    final selection = value.selection;
    if (!selection.isCollapsed || selection.end != _yankEnd) {
      _yankStart = -1;
      return true;
    }
    final entries = ring.entries;
    if (index >= entries.length) {
      _yankStart = -1;
      return true;
    }
    final replacement = entries[index];
    final popped = text.replaceRange(_yankStart, _yankEnd, replacement);
    _yankEnd = _yankStart + replacement.length;
    _yankIndex = index;
    controller.value = TextEditingValue(
      text: popped,
      selection: TextSelection.collapsed(offset: _yankEnd),
    );
    return true;
  }

  bool _transpose(
    TextEditingController controller,
    TextEditingValue value,
    String text,
    int point,
  ) {
    if (text.length < 2 || point == 0) return true;
    final left = point >= text.length ? text.length - 1 : point - 1;
    final right = left + 1;
    final swapped =
        text.substring(0, left) +
        text.substring(right, right + 1) +
        text.substring(left, left + 1) +
        text.substring(right + 1);
    controller.value = TextEditingValue(
      text: swapped,
      selection: TextSelection.collapsed(
        offset: math.min(point + 1, swapped.length),
      ),
    );
    _mark = null;
    return true;
  }

  bool _killWord(
    TextEditingController controller,
    TextEditingValue value,
    String text,
    int point, {
    required bool forward,
  }) {
    final selection = value.selection;
    if (_hasRegion(selection, point)) {
      return _killRegion(controller, value, text, selection, point);
    }
    if (forward) {
      final end = _forwardWord(text, point);
      if (end > point) {
        ring.push(text.substring(point, end));
        _setText(controller, text.replaceRange(point, end, ''), point);
      }
    } else {
      final start = _backwardWord(text, point);
      if (start < point) {
        ring.push(text.substring(start, point));
        _setText(controller, text.replaceRange(start, point, ''), start);
      }
    }
    _mark = null;
    _yankStart = -1;
    return true;
  }

  bool _hasRegion(TextSelection selection, int point) {
    if (_mark != null) return _mark != point;
    return selection.isValid && !selection.isCollapsed;
  }

  (int, int)? _region(TextSelection selection, int length, int point) {
    if (_mark != null) {
      if (_mark == point) return null;
      return (math.min(_mark!, point), math.max(_mark!, point));
    }
    if (!selection.isValid || selection.isCollapsed) return null;
    return (selection.start.clamp(0, length), selection.end.clamp(0, length));
  }

  void _setText(TextEditingController controller, String text, int offset) {
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: offset.clamp(0, text.length)),
    );
  }

  /// Forget the mark when a change to the field did not come from one of
  /// these commands: a mouse click, a letter typed, a line pasted.
  void _dropStaleMark(TextSelection selection, int point) {
    final mark = _mark;
    if (mark == null) return;
    if (!selection.isValid) {
      _mark = null;
      return;
    }
    final collapsedAtMark = selection.isCollapsed && point == mark;
    final region =
        !selection.isCollapsed &&
        selection.start == math.min(mark, point) &&
        selection.end == math.max(mark, point);
    if (!collapsedAtMark && !region) _mark = null;
  }

  /// Where the cursor is: the moving end of the selection.
  int _point(TextSelection selection, int length) {
    if (!selection.isValid) return length;
    return selection.extentOffset.clamp(0, length);
  }

  int _lineStart(String text, int at) {
    if (at <= 0) return 0;
    final found = text.lastIndexOf('\n', at - 1);
    return found < 0 ? 0 : found + 1;
  }

  int _lineEnd(String text, int at) {
    final found = text.indexOf('\n', at);
    return found < 0 ? text.length : found;
  }

  int _nextLine(String text, int at) {
    final end = _lineEnd(text, at);
    if (end >= text.length) return text.length;
    final start = end + 1;
    final column = at - _lineStart(text, at);
    return math.min(start + column, _lineEnd(text, start));
  }

  int _previousLine(String text, int at) {
    final start = _lineStart(text, at);
    if (start == 0) return 0;
    final previous = _lineStart(text, start - 1);
    final column = at - start;
    return math.min(previous + column, _lineEnd(text, previous));
  }

  int _forwardWord(String text, int from) {
    var at = from;
    while (at < text.length && !_isWordChar(text.codeUnitAt(at))) {
      at++;
    }
    while (at < text.length && _isWordChar(text.codeUnitAt(at))) {
      at++;
    }
    return at;
  }

  int _backwardWord(String text, int from) {
    var at = from;
    while (at > 0 && !_isWordChar(text.codeUnitAt(at - 1))) {
      at--;
    }
    while (at > 0 && _isWordChar(text.codeUnitAt(at - 1))) {
      at--;
    }
    return at;
  }

  bool _isWordChar(int code) =>
      code == 0x5f ||
      (code >= 0x30 && code <= 0x39) ||
      (code >= 0x41 && code <= 0x5a) ||
      (code >= 0x61 && code <= 0x7a) ||
      code > 0x7f;
}

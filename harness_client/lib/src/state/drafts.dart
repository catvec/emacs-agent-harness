import 'package:flutter/foundation.dart';

import 'prompt_attachment.dart';

/// What a person typed and has not sent yet, kept apart from the screens it
/// is typed on.
///
/// A screen is thrown away whenever the app leaves it, and the app leaves
/// all of them when it loses its connection and has to start over (it falls
/// back to the connection screen to sign in again, say).  A message that
/// took minutes to write must not go with them, nor must a task that was
/// being described.  The fields keep their text here as it changes, and
/// read it back when they come up again; sending clears it.  Nothing is
/// written to disk: this is for the life of the app, which is as long as
/// the connection lasts, and then some.
///
/// It is observable, so that a field on screen follows what is put back in it
/// from outside (a message that was not sent after all).
class DraftStore extends ChangeNotifier {
  final Map<String, String> _texts = <String, String>{};

  /// The task being described in the new-task sheet.
  final TaskDraft task = TaskDraft();

  /// The text left in the field called [key] (a session's composer is
  /// `session:ID`), or '' when there is none.
  String text(String key) => _texts[key] ?? '';

  /// Remember [value] as the text of the field [key]; empty forgets it.
  /// Listeners hear of it when the text changed.
  void setText(String key, String value) {
    if (text(key) == value) return;
    if (value.isEmpty) {
      _texts.remove(key);
    } else {
      _texts[key] = value;
    }
    notifyListeners();
  }

  /// Forget the text of the field [key].
  void clear(String key) => setText(key, '');

  /// Put [value] in front of what the field [key] holds, as a message that
  /// was not sent goes back to its field: what was typed meanwhile stays.
  void putBack(String key, String value) {
    if (value.isEmpty) return;
    final current = text(key);
    setText(key, current.isEmpty ? value : '$value\n\n$current');
  }

  /// The key of the field in which the conversation [sessionId] is written.
  static String composerKey(String sessionId) => 'session:$sessionId';
}

/// A task as far as the new-task sheet got with it.
class TaskDraft {
  String prompt = '';
  String cwd = '';

  /// The project chosen among the known ones; null when the path was typed.
  String? project;
  String priority = 'medium';
  bool refine = false;
  bool plan = false;
  bool mainTree = false;

  /// The pictures attached so far.  They are kept like the words, in memory:
  /// picking them again is worse than retyping.
  List<PromptAttachment> attachments = const [];

  /// Whether anything worth keeping was typed: the prompt is the work, and
  /// the pictures attached to it, the rest is a choice among defaults.
  bool get isEmpty => prompt.trim().isEmpty && attachments.isEmpty;

  void clear() {
    prompt = '';
    cwd = '';
    project = null;
    priority = 'medium';
    refine = false;
    plan = false;
    mainTree = false;
    attachments = const [];
  }
}

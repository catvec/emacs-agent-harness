import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/chat_thread.dart';
import '../../models/session.dart';
import '../../models/session_modes.dart';
import '../../models/task_chat.dart';
import '../../models/transcript.dart';
import '../../models/usage.dart';
import '../../models/task.dart';
import '../../state/app_controller.dart';
import '../../state/drafts.dart';
import '../../state/interaction.dart';
import '../../state/session_controller.dart';
import '../../services/voice_runtime.dart';
import '../../voice/voice_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../adaptive/platform_style.dart';
import '../app_scope.dart';
import '../format.dart';
import '../harness_keys.dart';
import '../navigation.dart';
import '../theme/harness_theme.dart';
import '../widgets/activity_bar.dart';
import '../widgets/chat_threads.dart';
import '../widgets/connection_banner.dart';
import '../widgets/interaction_card.dart';
import '../widgets/message_composer.dart';
import '../widgets/queued_messages.dart';
import '../widgets/quick_search_entry.dart';
import '../widgets/quota_widgets.dart';
import '../widgets/task_bar.dart';
import '../widgets/transcript_view.dart';
import 'review_file_screen.dart';
import 'review_thread_screen.dart';
import 'voice_screen.dart';

/// The icon a mode's id is known by; a mode of another agent gets the shield.
IconData _modeIcon(String id) => switch (id) {
  'ask' => Icons.help_outline_rounded,
  'accept-edits' => Icons.edit_outlined,
  'auto' => Icons.auto_awesome_rounded,
  'yolo' => Icons.bolt_rounded,
  _ => Icons.shield_outlined,
};

class SessionScreen extends StatefulWidget {
  const SessionScreen({
    super.key,
    required this.sessionId,
    this.embedded = false,
    this.voiceBackendFactory,
    this.startVoice = false,
  });

  final String sessionId;
  final bool embedded;

  /// What voice mode opens its microphone and provider with.  The app leaves
  /// it null and builds the real ones; a test hands it a scripted backend.
  final VoiceBackendFactory? voiceBackendFactory;

  /// Whether voice mode opens by itself, once the conversation is loaded.
  /// The app leaves it false; a walkthrough opens it while the answer to its
  /// question is already streaming, so that the answer is spoken.
  final bool startVoice;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  late AppController _app;
  late SessionController _controller;
  bool _bound = false;
  int _scrollTick = 0;

  /// The focus of the message box, for what asks for something to be typed
  /// in it: a task's *Send back* is feedback, written there.
  final _composerFocus = FocusNode();

  /// The message box itself, for the Emacs C-c commands of the screen: they
  /// send, attach images, and leave the box as it was.
  final _composerKey = GlobalKey<MessageComposerState>();

  /// The voice screen is a route of its own; a second tap while it opens must
  /// not stack another one.
  bool _voiceOpen = false;

  /// A screen asked for voice when it opened has done so already, however
  /// often it is built again after that.
  bool _voiceStarted = false;

  /// The message a quote was tapped from, to bring into view, and a count
  /// so that a second tap brings it again.
  String? _focusNodeId;
  int _focusTick = 0;

  /// The longest quote a reply takes, as the harness's own reply does: a
  /// quote is a reminder, and the message is a link away.
  static const _quoteLimit = 2000;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_bound) {
      _app = HarnessScope.appOf(context);
      _controller = _app.sessionController(widget.sessionId);
      _bound = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _app.openSession(widget.sessionId);
      });
    }
  }

  @override
  void didUpdateWidget(SessionScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) {
      _controller = _app.sessionController(widget.sessionId);
      _scrollTick++;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _app.openSession(widget.sessionId);
      });
    }
  }

  @override
  void dispose() {
    if (!widget.embedded && _bound) {
      _app.closeSession();
    }
    _composerFocus.dispose();
    super.dispose();
  }

  /// Answer the message [item] with the next one.  The quote is its words,
  /// whole unless it is very long, and names the message and the session so
  /// that the model can read it again.
  void _replyToMessage(TranscriptItem item) {
    final node = item.nodeId;
    if (node == null) return;
    var text = item.bodyText.trim();
    if (text.isEmpty) {
      text = item.threads
          .map((thread) => thread.response.trim())
          .where((words) => words.isNotEmpty)
          .join('\n\n');
    }
    if (text.isEmpty) return;
    _controller.replyTo(
      ChatReplyDraft(
        refs: [
          ChatThreadRef.message(
            node: node,
            who: item.isUser ? 'you' : 'agent',
            text: _quoted(text),
            session: widget.sessionId,
            label: item.isThinking ? 'thinking' : null,
          ),
        ],
      ),
    );
    _composerFocus.requestFocus();
  }

  /// Answer the reply in [thread] of [item].  A reply of the user's quotes
  /// what its own card quotes, as the Emacs chat does; one an agent wrote is
  /// the answer itself, and its message is what the answer links to.
  void _replyToThread(TranscriptItem item, ChatThread thread) {
    var refs = thread.refs;
    if (refs.isEmpty) {
      final answer = thread.response.trim();
      final text = answer.isNotEmpty ? answer : item.bodyText.trim();
      if (text.isNotEmpty) {
        refs = [
          if (item.nodeId != null)
            ChatThreadRef.message(
              node: item.nodeId!,
              who: item.isUser ? 'you' : 'agent',
              text: _quoted(text),
              session: widget.sessionId,
            )
          else
            ChatThreadRef(
              kind: 'chat',
              who: item.isUser ? 'you' : 'agent',
              text: _quoted(text),
            ),
        ];
      }
    }
    _controller.replyTo(ChatReplyDraft(refs: refs, threadId: thread.id));
    _composerFocus.requestFocus();
  }

  String _quoted(String text) {
    if (text.length <= _quoteLimit) return text;
    return '${text.substring(0, _quoteLimit).trimRight()}\n[...]';
  }

  /// Show what [ref] quotes: the message it is of, the thread of a review,
  /// or the file of a change at the revision it was read at.
  void _showRef(ChatThreadRef ref) {
    if (ref.isChat && ref.node != null) {
      if (ref.session != null && ref.session != widget.sessionId) {
        _notice('Another session');
        return;
      }
      setState(() {
        _focusNodeId = ref.node;
        _focusTick++;
      });
      return;
    }
    if (ref.isComment || ref.reviewThread != null) {
      final task = ref.reviewTask;
      final thread = ref.reviewThread;
      if (task != null && thread != null) {
        unawaited(_openReviewThread(task, thread));
        return;
      }
    }
    final task = _app.tasks?.forSession(widget.sessionId);
    if (task == null) {
      _notice(ref.isDiff ? 'No change' : 'No message');
      return;
    }
    if (ref.isDiff && (ref.file ?? '').isNotEmpty) {
      unawaited(_openChange(task, ref));
      return;
    }
    if (ref.isComment && ref.reviewThread != null) {
      unawaited(_openReviewThread(task.id, ref.reviewThread!));
      return;
    }
    _notice(ref.isDiff ? 'No change' : 'No message');
  }

  /// Open the thread of the task's review that [thread] in the chat names.
  Future<void> _openThread(TranscriptItem item, ChatThread thread) async {
    final id = thread.id;
    final task = _app.tasks?.forSession(widget.sessionId);
    if (id == null || task == null) {
      _notice('No review thread');
      return;
    }
    await _openReviewThread(task.id, id);
  }

  Future<void> _openReviewThread(String taskId, String threadId) async {
    final service = _app.api;
    if (service == null) {
      _notice('No review thread');
      return;
    }
    HarnessTask task;
    try {
      task = await service.task(taskId);
    } catch (_) {
      _notice('No review thread');
      return;
    }
    final review = _app.reviewFor(task);
    if (review == null) {
      _notice('No review thread');
      return;
    }
    await review.load();
    if (!mounted) return;
    if (review.thread(threadId) == null) {
      _notice('No review thread');
      return;
    }
    await Navigator.of(context).push<void>(
      harnessRoute(
        context,
        (_) => ReviewThreadScreen(controller: review, threadId: threadId),
      ),
    );
  }

  /// Open the file of a change a quote is of, at the revision it was read
  /// at, so that its lines are the ones the comment records.
  Future<void> _openChange(HarnessTask task, ChatThreadRef ref) async {
    final review = _app.reviewFor(task);
    final path = ref.file;
    if (review == null || path == null) {
      _notice('No change');
      return;
    }
    await review.load();
    if (!mounted) return;
    final revision = ref.revision;
    if (revision != null &&
        review.versions.any((version) => version.id == revision) &&
        revision != review.changes?.versionId) {
      await review.selectVersion(revision);
      if (!mounted) return;
    }
    if (!mounted) return;
    final known = review.changes?.files.where(
      (file) => file.path == path || file.oldPath == path,
    );
    if (known == null || known.isEmpty) {
      _notice('No change');
      return;
    }
    review.selectFile(path);
    await Navigator.of(context).push<void>(
      harnessRoute(
        context,
        (_) => ReviewFileScreen(controller: review, path: path),
      ),
    );
  }

  void _notice(String text) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));
  }

  /// What the screen's Emacs C-c prefix runs, as the harness's own chat binds
  /// it: send, stop, attach, search, copy the last reply, jump to the end.
  Map<LogicalKeyboardKey, VoidCallback> _keyCommands(BuildContext context) => {
    LogicalKeyboardKey.keyC: () => _composerKey.currentState?.sendNow(),
    LogicalKeyboardKey.keyK: () => unawaited(_controller.cancel()),
    LogicalKeyboardKey.keyA: () => _composerKey.currentState?.attachNow(),
    LogicalKeyboardKey.keyS: () => QuickSearchEntry.maybeOf(context)?.open(),
    LogicalKeyboardKey.keyW: _copyLastReply,
    LogicalKeyboardKey.keyE: _jumpToBottom,
  };

  /// Copy the agent's latest message, as the Emacs chat's C-c C-w does.
  void _copyLastReply() {
    for (final item in _controller.transcript.displayItems.reversed) {
      if (!item.isAssistant || item.isThinking) continue;
      final words = item.bodyText.trim();
      if (words.isEmpty) continue;
      unawaited(Clipboard.setData(ClipboardData(text: words)));
      _notice('Last reply copied');
      return;
    }
    _notice('Nothing to copy');
  }

  /// The list follows what the running turn writes; this takes the person
  /// back to its end.
  void _jumpToBottom() => setState(() => _scrollTick++);

  Future<void> _rename() async {
    final current = _controller.summary?.displayTitle ?? '';
    final name = await showHarnessTextPrompt(
      context: context,
      title: 'Rename session',
      initial: current,
      hint: 'A short title',
      confirmLabel: 'Rename',
    );
    if (name != null && name.trim().isNotEmpty) {
      await _controller.rename(name.trim());
    }
  }

  Future<void> _fork() async {
    final id = await _controller.fork();
    if (id == null || !mounted) return;
    if (widget.embedded) {
      _app.openSession(id);
    } else {
      await Navigator.of(context).pushReplacement(
        harnessRoute(context, (context) => SessionScreen(sessionId: id)),
      );
    }
  }

  Future<void> _delete() async {
    final confirmed = await showHarnessDialog<bool>(
      context: context,
      title: 'Session deletion',
      message:
          'Transcript and temporary files removed · irreversible',
      confirmLabel: 'Deletion',
      cancelLabel: 'Cancel',
      destructive: true,
    );
    if (confirmed != true) return;
    final removed = await _controller.deleteSession();
    if (removed && mounted) {
      if (widget.embedded) {
        _app.closeSession();
      } else {
        Navigator.of(context).pop();
      }
    }
  }

  /// A conversation opened for a walkthrough opens voice mode by itself,
  /// once it is loaded: the answer to the question that started it is meant
  /// to be spoken, and voice mode attaches while that answer streams.  It
  /// happens once: the screen stays open behind voice mode.
  void _openVoiceIfAsked() {
    if (!widget.startVoice || _voiceStarted || _controller.loading) return;
    _voiceStarted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_openVoice());
      }
    });
  }

  Future<void> _openVoice() async {
    if (_voiceOpen || !_controller.canSend || _controller.loading) return;
    _voiceOpen = true;
    final bridge = SessionVoiceBridge(_controller);
    final controller = VoiceController(
      settings: _app.settings.voiceSettings,
      bridge: bridge,
      harnessAddress: _app.address ?? _app.settings.address,
      backendFactory:
          widget.voiceBackendFactory ??
          (settings, address) => createVoiceBackend(settings, address, bridge),
      onSettingsChanged: _app.settings.setVoiceSettings,
    );
    try {
      await Navigator.of(context).push(
        harnessRoute(context, (context) => VoiceScreen(controller: controller)),
      );
    } finally {
      _voiceOpen = false;
    }
  }

  Future<void> _chooseModel() async {
    final models = [
      for (final provider in _app.server?.providers ?? const [])
        for (final model in provider.models) model,
    ];
    if (models.isEmpty) {
      final value = await showHarnessTextPrompt(
        context: context,
        title: 'Model change',
        message: 'Provider:model',
        initial: _controller.summary?.model ?? '',
        hint: 'provider:model',
        confirmLabel: 'Model',
      );
      if (value != null && value.trim().isNotEmpty) {
        await _controller.setModel(value.trim());
      }
      return;
    }
    final chosen = await showHarnessMenu<String>(
      context: context,
      title: 'Model',
      items: [
        for (final model in models)
          HarnessMenuItem(
            value: model.id,
            label: model.name == model.id
                ? model.id
                : '${model.name} · ${model.id}',
            icon: Icons.memory_rounded,
          ),
      ],
    );
    if (chosen != null) await _controller.setModel(chosen);
  }

  Future<void> _chooseMode() async {
    final modes = _controller.modes?.available ?? const <SessionMode>[];
    if (modes.isEmpty) return;
    final chosen = await showHarnessMenu<String>(
      context: context,
      title: 'Permission mode',
      items: [
        for (final mode in modes)
          HarnessMenuItem(
            value: mode.id,
            label: mode.name,
            icon: _modeIcon(mode.id),
          ),
      ],
    );
    if (chosen != null) await _controller.setMode(chosen);
  }

  Future<void> _toggleInteractive() => _controller.setNonInteractive(
    _controller.summary?.nonInteractive != true,
  );

  Future<void> _choosePriority() async {
    final chosen = await showHarnessMenu<String>(
      context: context,
      title: 'Session priority',
      items: const [
        HarnessMenuItem(
          value: 'high',
          label: 'High',
          icon: Icons.keyboard_double_arrow_up_rounded,
        ),
        HarnessMenuItem(
          value: 'medium',
          label: 'Medium',
          icon: Icons.drag_handle_rounded,
        ),
        HarnessMenuItem(
          value: 'low',
          label: 'Low',
          icon: Icons.keyboard_double_arrow_down_rounded,
        ),
      ],
    );
    if (chosen != null) await _controller.setPriority(chosen);
  }

  List<Widget> _actions(BuildContext context) {
    final caps = _app.capability;
    return [
      HarnessIconButton(
        icon: adaptiveIcon(
          context,
          Icons.refresh_rounded,
          CupertinoIcons.arrow_clockwise,
        ),
        label: 'Reload transcript',
        onPressed: () => _controller.open(force: true),
      ),
      HarnessIconButton(
        icon: adaptiveIcon(
          context,
          Icons.more_horiz_rounded,
          CupertinoIcons.ellipsis_circle,
        ),
        label: 'Session menu',
        onPressed: () async {
          final action = await showHarnessMenu<String>(
            context: context,
            title: _controller.summary?.displayTitle ?? 'Session',
            items: [
              if (caps?.renameSession == true)
                const HarnessMenuItem(
                  value: 'rename',
                  label: 'Rename',
                  icon: Icons.edit_outlined,
                ),
              if (caps?.fork == true)
                const HarnessMenuItem(
                  value: 'fork',
                  label: 'Fork conversation',
                  icon: Icons.call_split_rounded,
                ),
              if (caps?.priority == true)
                const HarnessMenuItem(
                  value: 'priority',
                  label: 'Priority',
                  icon: Icons.sort_rounded,
                ),
              if (caps?.setNonInteractive == true)
                HarnessMenuItem(
                  value: 'interactive',
                  label: _controller.summary?.nonInteractive == true
                      ? 'Interactive'
                      : 'Non-interactive',
                  icon: _controller.summary?.nonInteractive == true
                      ? Icons.touch_app_outlined
                      : Icons.hourglass_disabled_rounded,
                ),
              const HarnessMenuItem(
                value: 'model',
                label: 'Model change',
                icon: Icons.memory_rounded,
              ),
              if (_controller.canChangeMode)
                const HarnessMenuItem(
                  value: 'mode',
                  label: 'Permission mode',
                  icon: Icons.shield_outlined,
                ),
              if (caps?.deleteSession == true)
                const HarnessMenuItem(
                  value: 'delete',
                  label: 'Delete session',
                  icon: Icons.delete_outline_rounded,
                  destructive: true,
                ),
            ],
          );
          if (!mounted) return;
          switch (action) {
            case 'rename':
              await _rename();
            case 'fork':
              await _fork();
            case 'priority':
              await _choosePriority();
            case 'model':
              await _chooseModel();
            case 'mode':
              await _chooseMode();
            case 'interactive':
              await _toggleInteractive();
            case 'delete':
              await _delete();
          }
        },
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (!_bound) {
      return const SizedBox.shrink();
    }
    // Whether the keyboard is up.  Asked here, above the page: the page's
    // body is given what the keyboard leaves, and is told nothing of it.
    final typing = MediaQuery.viewInsetsOf(context).bottom > 0;
    return AnimatedBuilder(
      // The task board too: a task's state is in this conversation (what its
      // bar offers, what its message box says a message does).
      animation: Listenable.merge([
        _controller,
        _app.settings,
        _app,
        _app.tasks,
      ]),
      builder: (context, _) {
        _openVoiceIfAsked();
        final summary =
            _controller.summary ?? _app.summaryFor(widget.sessionId);
        final title = summary?.displayTitle ?? 'Session';
        final body = _buildBody(context, summary, typing);
        // Where the conversation is and what it is doing, under its title.
        final context_ = summary == null
            ? null
            : _SessionContext(
                app: _app,
                controller: _controller,
                summary: summary,
              );
        if (widget.embedded) {
          return HarnessKeyLayer(
            commands: _keyCommands(context),
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                children: [
                  _EmbeddedHeader(
                    title: title,
                    subtitle: context_,
                    actions: _actions(context),
                    onClose: _app.closeSession,
                  ),
                  Expanded(child: body),
                ],
              ),
            ),
          );
        }
        return HarnessKeyLayer(
          commands: _keyCommands(context),
          child: HarnessPage(
            title: title,
            subtitle: context_,
            actions: _actions(context),
            body: body,
          ),
        );
      },
    );
  }

  Widget _buildBody(
    BuildContext context,
    SessionSummary? summary,
    bool typing,
  ) {
    final theme = Theme.of(context);
    final controller = _controller;
    if (_controller.deleted) {
      return Column(
        children: [
          Expanded(
            child: HarnessEmptyState(
              icon: Icons.delete_outline_rounded,
              title: 'Session deleted',
              message: 'No conversation in the harness',
              action: HarnessPrimaryButton(
                label: 'Sessions',
                onPressed: () {
                  if (widget.embedded) {
                    _app.closeSession();
                  } else {
                    Navigator.of(context).maybePop();
                  }
                },
              ),
            ),
          ),
        ],
      );
    }
    final plan = controller.transcript.plan;
    final interaction = controller.currentInteraction;
    // A question is answered in its card, which has a field for the answer:
    // the composer would only take its room (and the keyboard's, where the
    // answer is typed).  It is kept, not rebuilt, so what was typed in it,
    // and the images attached, are there when the question is answered.
    final question = interaction?.isQuestion == true;
    // A 320 by 640 phone at twice the text has a strip of a page above the
    // keyboard: the message box becomes one line of reply target, a field of
    // two lines and its controls.  The rest of the page has its room back.
    final tightKeyboard =
        typing &&
        MediaQuery.textScalerOf(context).scale(15) > 19.5 &&
        MediaQuery.sizeOf(context).height < 720;
    return Column(
      children: [
        // A conversation opened as a page of its own covers the home
        // screens, and with them their banner.
        if (!widget.embedded) ConnectionBanner(app: _app),
        if (controller.error != null)
          HarnessErrorBanner(
            message: controller.error!,
            onDismiss: controller.clearError,
            actionLabel: 'Retry',
            onAction: () => controller.open(force: true),
          ),
        // What is above the composer: the conversation, and what waits on
        // an answer.  A request is given the room this has, which is what
        // the screen has left once the keyboard and the rest are taken out,
        // never more: whatever the size of the phone, it can be answered.
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // With the keyboard up the person is typing the answer: the
              // card has all the room, and what shows the conversation goes
              // (it is a line of it, in a window with the keyboard in it).
              final room = constraints.maxHeight;
              final bar =
                  controller.promptInFlight ||
                  controller.activity != null ||
                  interaction != null;
              return Column(
                children: [
                  Expanded(
                    child:
                        controller.loading &&
                            controller.transcript.items.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                HarnessActivity(radius: 11),
                                const SizedBox(height: 14),
                                Text(
                                  'Loading the conversation…',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : TranscriptView(
                            items: controller.transcript.displayItems,
                            showThinking: _app.settings.showThinking,
                            streaming: controller.promptInFlight,
                            scrollTick: _scrollTick,
                            // The calls of the harness's allow list fold into
                            // runs, never one that waits for you.
                            tools: controller.tools,
                            waiting: controller.waitingCalls,
                            // The latest compaction can be taken back, and
                            // made again, where the harness can.
                            onToggleCompaction:
                                _app.capability?.compactionRevert == true
                                ? controller.toggleCompaction
                                : null,
                            sessionId: widget.sessionId,
                            onReply: _replyToMessage,
                            onReplyThread: _replyToThread,
                            onShowRef: _showRef,
                            onOpenThread: _openThread,
                            focusNodeId: _focusNodeId,
                            focusTick: _focusTick,
                          ),
                  ),
                  // With the keyboard up the room is for what is being
                  // written: the plan and the activity are one line each on
                  // a large screen, and most of the conversation on a phone
                  // held upright at twice the text.
                  if (plan.isNotEmpty && interaction == null && !typing)
                    _PlanStrip(key: const Key('session-plan'), plan: plan),
                  if (bar && !typing)
                    ActivityBar(
                      activity: controller.activity,
                      waiting: interaction != null,
                      running: controller.promptInFlight,
                    ),
                  if (interaction != null)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: _requestRoom(room, interaction, typing),
                      ),
                      child: InteractionCard(controller: controller),
                    ),
                ],
              );
            },
          ),
        ),
        // What waits for the next turn, above the box that sends it: the
        // harness's queue, from this phone or another client.  With a
        // request on screen the room is for its answer, and the queue is
        // back once it goes.
        if (interaction == null && controller.queued.isNotEmpty)
          QueuedMessages(
            key: const Key('session-queue'),
            items: controller.queued,
            onSendNow: controller.canSend
                ? (id) => unawaited(controller.sendQueued(id))
                : null,
            onSendAll: controller.canSend && controller.queued.length > 1
                ? () => unawaited(controller.sendQueuedAll())
                : null,
            onEdit: controller.canSend
                ? (id) => unawaited(controller.editQueued(id))
                : null,
            onRemove: controller.canSend
                ? (id) => unawaited(controller.removeQueued(id))
                : null,
          ),
        // A task's conversation is where the task is handled: where it
        // stands and what can be done about it, over the box that sends
        // feedback.  What waits on an answer has the room for that.
        if (interaction == null)
          SessionTaskBar(
            app: _app,
            sessionId: widget.sessionId,
            compact: typing,
            onSendBack: _composerFocus.requestFocus,
          ),
        Offstage(
          offstage: question,
          child: MessageComposer(
            key: _composerKey,
            autofocus: harnessControlKeyboard,
            focusNode: _composerFocus,
            tight: tightKeyboard,
            // What a message does here, where it is not the usual: for a task
            // in review it is the feedback that sends the task back.
            hint: controller.reply != null
                ? 'Reply'
                : taskMessageHint(_app.tasks?.forSession(widget.sessionId)),
            header: controller.reply == null
                ? null
                : ChatReplyBar(
                    tight: tightKeyboard,
                    draft: controller.reply!,
                    onCancel: controller.cancelReply,
                    onShow: controller.reply!.refs.isEmpty
                        ? null
                        : () => _showRef(controller.reply!.refs.first),
                  ),
            running: controller.promptInFlight,
            cancelling: controller.cancelling,
            canAttach: _app.capability?.promptImages == true,
            canQueue: controller.canQueue,
            onQueue: (text) {
              if (!controller.canQueue) return false;
              unawaited(controller.queue(text));
              return true;
            },
            canVoice:
                controller.canSend &&
                interaction == null &&
                !controller.loading,
            onVoice: _openVoice,
            awaitingAnswer: interaction != null,
            // Typing goes on while the connection is out; sending waits for it.
            offline: !controller.canSend,
            enabled: interaction == null && controller.canSend,
            onStop: controller.cancel,
            // How the next message is handled: the model, the permission mode,
            // how full the context is and what the conversation has cost.
            // The settings give the keyboard's room to the words: they are
            // one tap away again when it goes.
            footer: typing
                ? null
                : _SessionFooter(
                    key: const Key('session-footer'),
                    app: _app,
                    summary: summary,
                    mode:
                        _controller.currentMode?.name ??
                        permissionLabel(
                          _controller.currentModeId ?? summary?.permissionMode,
                        ),
                    onModel: _chooseModel,
                    onMode: _controller.canChangeMode ? _chooseMode : null,
                    onInteractive: _toggleInteractive,
                  ),
            // What is typed outlives this screen: see DraftStore.
            drafts: _app.drafts,
            draftKey: DraftStore.composerKey(widget.sessionId),
            onSend: (text, attachments) {
              // No connection to take it: the composer keeps the message.
              if (!controller.canSend) return false;
              setState(() => _scrollTick++);
              unawaited(controller.send(text, attachments: attachments));
              return true;
            },
          ),
        ),
      ],
    );
  }

  /// The most height the card of [request] may take of the [room] there is
  /// for it and the conversation above it: what it needs, but for a strip
  /// of the conversation, to keep where it is.  A card is as tall as what it
  /// says and offers, and no taller: this is only what it is never taller
  /// than.  With the keyboard up a question is being answered ([typing]),
  /// and takes all of it.
  double _requestRoom(double room, InteractionRequest request, bool typing) {
    if (typing && request.isQuestion) return room;
    return (room - 88).clamp(0.0, room);
  }
}

/// The header of a conversation that is a pane of a wide screen: the title
/// over where it is and what it is doing, and the actions.
class _EmbeddedHeader extends StatelessWidget {
  const _EmbeddedHeader({
    required this.title,
    required this.subtitle,
    required this.actions,
    required this.onClose,
  });

  final String title;
  final Widget? subtitle;
  final List<Widget> actions;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(
        HarnessSpace.gutter,
        HarnessSpace.md,
        HarnessSpace.sm,
        HarnessSpace.md,
      ),
      decoration: BoxDecoration(
        color: HarnessStyle.isCupertino(context)
            ? CupertinoTheme.of(context).barBackgroundColor
            : theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HarnessText.pageTitle(context),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  DefaultTextStyle(
                    style: HarnessText.subtitle(context),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    child: subtitle!,
                  ),
                ],
              ],
            ),
          ),
          ...actions,
          HarnessIconButton(
            icon: Icons.close_rounded,
            label: 'Close conversation',
            size: 19,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// The line under the title of a conversation: its state (a dot and a
/// word), the project it works on, and the task it belongs to, if any.
class _SessionContext extends StatelessWidget {
  const _SessionContext({
    required this.app,
    required this.controller,
    required this.summary,
  });

  final AppController app;
  final SessionController controller;
  final SessionSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final waiting = controller.currentInteraction != null;
    final status = waiting ? 'blocked' : summary.status;
    final color = HarnessColors.status(status, theme.brightness);
    final task = app.tasks?.forSession(summary.id);
    final project = app.projectOfSession(summary) ?? summary.project;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        HarnessDot(color: color, size: 6),
        const SizedBox(width: 6),
        Flexible(
          child: HarnessMetaLine(
            dropWhatDoesNotFit: true,
            parts: [
              HarnessMetaPart(
                waiting ? 'Your input' : statusLabel(status),
                color: color,
                weight: FontWeight.w600,
              ),
              // The project, where there is more than one to tell apart.
              if (app.projects.length != 1) projectName(project ?? summary.cwd),
              if (task != null) 'Task: ${task.title}',
            ],
          ),
        ),
      ],
    );
  }
}

/// The row under the message field.  On the left what decides how the next
/// message is handled, and can be changed (the model, the permission mode);
/// on the right how full the context is and what the conversation has cost.
class _SessionFooter extends StatelessWidget {
  const _SessionFooter({
    super.key,
    required this.app,
    required this.summary,
    required this.mode,
    required this.onModel,
    required this.onMode,
    required this.onInteractive,
  });

  final AppController app;
  final SessionSummary? summary;

  /// What the permission-mode picker reads: the session's current mode.
  final String mode;
  final VoidCallback onModel;

  /// Null: the session offers no modes, and the value is shown only.
  final VoidCallback? onMode;
  final VoidCallback onInteractive;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final usage = s?.usage;
    final window = s?.contextWindow;
    final used = usage?.contextInUse ?? 0;
    final spend = app.spendOf(s);
    return LayoutBuilder(
      builder: (context, constraints) {
        // On a narrow screen the figures give way to the pickers: the rule
        // goes, then the cost.  The context's figures stay.
        final narrow = constraints.maxWidth < 340;
        final ruled = constraints.maxWidth >= 400;
        return Row(
          children: [
            // The pickers take what the figures at the other end leave.  The
            // model takes the larger share, and the mode still has the room
            // its name needs, with the mark that it opens a choice.
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    flex: 4,
                    child: HarnessPicker(
                      icon: Icons.memory_rounded,
                      label: modelName(s?.model),
                      onTap: onModel,
                    ),
                  ),
                  Flexible(
                    flex: 3,
                    child: HarnessPicker(
                      icon: Icons.shield_outlined,
                      label: mode,
                      onTap: onMode,
                    ),
                  ),
                  // Only while it is on: the footer has no room for a third
                  // picker that mostly says "Interactive".  The menu turns it
                  // on, this turns it off.
                  if (s?.nonInteractive == true)
                    Flexible(
                      flex: 3,
                      child: HarnessPicker(
                        key: const Key('session-interactive'),
                        icon: Icons.hourglass_disabled_rounded,
                        label: 'Non-interactive',
                        color: HarnessColors.amber,
                        onTap: onInteractive,
                      ),
                    ),
                ],
              ),
            ),
            // The figures are never more than half the row: where they do
            // not fit in that, they shrink rather than crowd the pickers.
            if ((window != null && window > 0) ||
                (spend.worthShowing && !narrow))
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * (narrow ? 0.4 : 0.5),
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (window != null && window > 0)
                        _ContextMeter(used: used, window: window, rule: ruled),
                      // What it cost, or the plan that pays for it with the
                      // plan's quota.
                      if (spend.worthShowing && !narrow) ...[
                        const SizedBox(width: HarnessSpace.md),
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: SpendChip(
                            key: const Key('session-spend'),
                            status: spend,
                            onTap: () => showPlanSheet(
                              context,
                              status: spend,
                              providerLabel: app.providerLabelOf(spend),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// How much of the context window is used: the figures, and a rule that
/// turns amber as it fills.
class _ContextMeter extends StatelessWidget {
  const _ContextMeter({
    required this.used,
    required this.window,
    this.rule = true,
  });

  final int used;
  final int window;

  /// Whether the rule is drawn, or only the figures.
  final bool rule;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = (used / window).clamp(0.0, 1.0);
    return Semantics(
      label: 'Context ${formatTokens(used)} of ${formatTokens(window)}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (rule) ...[
            SizedBox(
              width: 30,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 3,
                  backgroundColor: theme.colorScheme.surfaceContainerHigh,
                  color: fraction > 0.8
                      ? HarnessColors.amber
                      : theme.colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            '${formatTokens(used)} / ${formatTokens(window)}',
            style: HarnessText.meta(context),
          ),
        ],
      ),
    );
  }
}

class _PlanStrip extends StatelessWidget {
  const _PlanStrip({super.key, required this.plan});
  final List<PlanEntry> plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final done = plan.where((entry) => entry.isDone).length;
    final active = plan.where((entry) => entry.isActive).firstOrNull;
    final progress = plan.isEmpty ? 0.0 : done / plan.length;
    // One line: the plan and how far it is, then the step being worked on.
    // How far is also a hairline along the top edge.
    return Semantics(
      button: true,
      label: 'Plan, $done of ${plan.length} done',
      child: HarnessTap(
        onTap: () => _showPlan(context),
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.04),
            border: Border(
              top: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
          ),
          child: Stack(
            children: [
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 2,
                  backgroundColor: Colors.transparent,
                  color: theme.colorScheme.primary,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  HarnessSpace.gutter,
                  10,
                  HarnessSpace.md,
                  10,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.map_outlined,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Plan',
                      style: HarnessText.meta(context).copyWith(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '$done / ${plan.length}',
                      style: HarnessText.meta(context),
                    ),
                    if (active != null) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          active.content,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HarnessText.subtitle(context),
                        ),
                      ),
                    ] else
                      const Spacer(),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.expand_less_rounded,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showPlan(BuildContext context) {
    showHarnessSheet<void>(
      context: context,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Plan', style: HarnessText.sheetTitle(sheetContext)),
            const SizedBox(height: 14),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.65,
              ),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final entry in plan)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              entry.isDone
                                  ? Icons.check_circle_rounded
                                  : entry.isActive
                                  ? Icons.radio_button_checked_rounded
                                  : Icons.radio_button_unchecked_rounded,
                              size: 19,
                              color: entry.isDone
                                  ? HarnessColors.moss
                                  : entry.isActive
                                  ? Theme.of(sheetContext).colorScheme.primary
                                  : Theme.of(sheetContext)
                                        .colorScheme
                                        .onSurfaceVariant,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                entry.content,
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.4,
                                  decoration: entry.isDone
                                      ? TextDecoration.lineThrough
                                      : null,
                                  color: entry.isDone
                                      ? Theme.of(sheetContext)
                                            .colorScheme
                                            .onSurfaceVariant
                                      : null,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

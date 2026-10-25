import '../acp/acp_message.dart';
import 'project_roots.dart';
import 'session.dart';
import 'tool_display.dart';

/// A task on the harness's task board.
class HarnessTask {
  const HarnessTask({
    required this.id,
    this.name,
    this.prompt = '',
    this.state,
    this.column,
    this.priority,
    this.project,
    this.cwd,
    this.sessionId,
    this.branch,
    this.worktree,
    this.createdAt,
    this.finishedAt,
    this.updatedAt,
    this.queuedAt,
    this.verifiedAt,
    this.outcome,
    this.error,
    this.report,
    this.feedback = const [],
    this.mergeStatus,
    this.conflicts = const [],
    this.verified = false,
    this.archived = false,
    this.backlog = false,
    this.plan = false,
    this.mainTree = false,
    this.noMerge = false,
    this.cannotContinue = false,
    this.queueSuspended = false,
    this.autoQueue = false,
    this.returned = false,
    this.returnReason,
    this.hold,
    this.merged = false,
    this.worktreeRemoved = false,
    this.model,
    this.thinking,
    this.attachments = const [],
    this.extra = const {},
  });

  factory HarnessTask.fromWire(JsonMap wire) {
    final report = asMap(wire['report']);
    final handedIn = report.isEmpty ? null : HandInReport.fromWire(report);
    return HarnessTask(
      id: asStringOr(wire['id'], ''),
      name: _blankToNull(asString(wire['name'] ?? wire['title'])),
      prompt: asStringOr(wire['prompt'], ''),
      state: asString(wire['state']),
      column: asString(wire['column']),
      priority: asString(wire['priority']) ?? 'medium',
      project: asString(wire['project']),
      cwd: asString(wire['cwd']),
      sessionId: asString(
        wire['session'] ?? wire['sessionId'] ?? wire['session-id'],
      ),
      branch: asString(wire['branch']),
      worktree: asString(wire['worktree']),
      createdAt: parseTime(wire['created']),
      finishedAt: parseTime(wire['finished']),
      updatedAt: parseTime(wire['updated'] ?? wire['updatedAt']),
      queuedAt: parseTime(wire['queuedAt'] ?? wire['queued-at']),
      verifiedAt: parseTime(wire['verifiedAt'] ?? wire['verified-at']),
      outcome: asString(wire['outcome']),
      error: asString(wire['error']),
      report: handedIn == null || handedIn.isEmpty ? null : handedIn,
      feedback: [
        for (final item in asMapList(wire['feedback']))
          TaskFeedback(
            text: asStringOr(item['text'], ''),
            at: parseTime(item['at']),
          ),
      ],
      mergeStatus: asString(wire['mergeStatus'] ?? wire['merge-status']),
      conflicts: [
        for (final item in asList(wire['conflicts'])) asStringOr(item, ''),
      ],
      verified: asBool(wire['verified']),
      archived: asBool(wire['archived']),
      backlog: asBool(wire['backlog']),
      plan: asBool(wire['plan']),
      mainTree: asBool(wire['mainTree'] ?? wire['main-tree']),
      noMerge:
          asBool(wire['noMerge'] ?? wire['no-merge']) ||
          asBool(report['noMerge'] ?? report['no-merge']),
      cannotContinue:
          asBool(wire['cannotContinue'] ?? wire['cannot-continue']) ||
          asBool(report['cannotContinue'] ?? report['cannot-continue']),
      queueSuspended: asBool(wire['queueSuspended'] ?? wire['queue-suspended']),
      autoQueue: asBool(wire['autoQueue'] ?? wire['auto-queue']),
      // When it was put back in the queue after it worked, or true.
      returned: asBool(wire['returned']),
      returnReason: asString(wire['returnReason'] ?? wire['return-reason']),
      hold: switch (asMap(wire['hold'])) {
        final hold when hold.isEmpty => null,
        final hold => TaskHold.fromWire(hold),
      },
      merged: asBool(wire['merged']),
      worktreeRemoved: asBool(
        wire['worktreeRemoved'] ?? wire['worktree-removed'],
      ),
      model: asString(wire['model']),
      thinking: asString(wire['thinking']),
      attachments: [
        for (final item in asList(wire['attachments']))
          if (_attachmentName(item) case final name?) name,
      ],
      extra: wire,
    );
  }

  final String id;
  final String? name;
  final String prompt;
  final String? state;
  final String? column;
  final String? priority;
  final String? project;
  final String? cwd;
  final String? sessionId;
  final String? branch;
  final String? worktree;
  final DateTime? createdAt;
  final DateTime? finishedAt;
  final DateTime? updatedAt;
  final DateTime? queuedAt;
  final DateTime? verifiedAt;
  final String? outcome;
  final String? error;

  /// What the task's work was handed in with, when it was: the same record
  /// as the report of the `hand_in` call in the task's session, which is
  /// read and drawn the same way ([HandInReport]).
  final HandInReport? report;
  final List<TaskFeedback> feedback;
  final String? mergeStatus;
  final List<String> conflicts;
  final bool verified;
  final bool archived;
  final bool backlog;
  final bool plan;
  final bool mainTree;
  final bool noMerge;
  final bool cannotContinue;
  final bool queueSuspended;
  final bool autoQueue;

  /// Whether the task was put back in the pending queue after it worked
  /// (paused, pre-empted, returned by hand, sent back while no slot could
  /// take it): its session has the work, and starting it carries on.  The
  /// harness clears it when the task starts again.
  final bool returned;

  /// Why it was returned: `returned`, `preempted`, `reclaimed`, `sent-back`,
  /// `quota` or `budget`.
  final String? returnReason;

  /// What holds a task in the queue back, when something does: the user
  /// paused it, or every model it could run on is out of quota or money.
  final TaskHold? hold;

  /// Whether the task's branch is merged.
  final bool merged;

  /// Whether the task's worktree was removed (it was archived and merged).
  final bool worktreeRemoved;
  final String? model;
  final String? thinking;

  /// The names of the files attached to the task: the pictures it was
  /// submitted with, say.
  final List<String> attachments;
  final JsonMap extra;

  String get title {
    final given = name;
    if (given != null && given.trim().isNotEmpty) return given.trim();
    final line = prompt
        .split('\n')
        .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '');
    return line.trim().isEmpty ? 'Untitled task' : _truncate(line.trim(), 80);
  }

  String get columnName {
    final value = column ?? state ?? 'pending';
    return value.replaceAll('_', '-');
  }

  int get columnOrder => switch (columnName) {
    'needs-input' => 0,
    'active' => 1,
    'merging' => 2,
    'review' => 3,
    'pending' => 4,
    'backlog' => 5,
    'done' => 7,
    'cancelled' => 8,
    _ => 6,
  };

  bool get needsInput => columnName == 'needs-input';
  bool get isReview => columnName == 'review';
  bool get isActive => columnName == 'active';
  bool get isPending => columnName == 'pending';
  bool get isBacklog => columnName == 'backlog';
  bool get isMerging => columnName == 'merging';
  bool get isDone => columnName == 'done';

  /// Stopped by the user, then marked done, its work never merged: the
  /// harness gives it a column of its own, apart from finished work.
  bool get isCancelled => columnName == 'cancelled';

  /// Over: finished work, or cancelled work.  Neither is stopped part way,
  /// and both are archived, not completed again.
  bool get isClosed => isDone || isCancelled;
  bool get isStopped => outcome != null && !isClosed;

  /// Whether an agent writes the task up for the backlog, or stopped part
  /// way (see [outcome]).
  bool get isRefining => state == 'refining';

  /// Whether the user paused the task: it waits in the queue, whatever the
  /// free slots, until it is resumed.
  bool get isPaused => hold?.kind == 'paused';

  /// Whether the task's session stopped on the word of an agent that the
  /// board already has this task (`duplicate`), and waits for the user.
  bool get isDuplicate => isRefining && outcome == 'duplicate';

  /// The name of the project the task is for: a git worktree of the harness
  /// is named for its project.
  String get projectName {
    final source = worktreeOwner(project ?? cwd) ?? project ?? cwd;
    if (source == null) return '';
    final parts = source.split('/').where((part) => part.isNotEmpty).toList();
    return parts.isEmpty ? source : parts.last;
  }

  String get priorityLabel => switch (priority) {
    'high' => 'High',
    'low' => 'Low',
    _ => 'Medium',
  };

  /// This task, with [priority] for the one it has: what the board shows
  /// while the harness is told to change it.
  HarnessTask withPriority(String priority) => HarnessTask(
    id: id,
    name: name,
    prompt: prompt,
    state: state,
    column: column,
    priority: priority,
    project: project,
    cwd: cwd,
    sessionId: sessionId,
    branch: branch,
    worktree: worktree,
    createdAt: createdAt,
    finishedAt: finishedAt,
    updatedAt: updatedAt,
    queuedAt: queuedAt,
    verifiedAt: verifiedAt,
    outcome: outcome,
    error: error,
    report: report,
    feedback: feedback,
    mergeStatus: mergeStatus,
    conflicts: conflicts,
    verified: verified,
    archived: archived,
    backlog: backlog,
    plan: plan,
    mainTree: mainTree,
    noMerge: noMerge,
    cannotContinue: cannotContinue,
    queueSuspended: queueSuspended,
    autoQueue: autoQueue,
    returned: returned,
    returnReason: returnReason,
    hold: hold,
    merged: merged,
    worktreeRemoved: worktreeRemoved,
    model: model,
    thinking: thinking,
    attachments: attachments,
    extra: extra,
  );

  HarnessTask merge(HarnessTask newer) {
    if (newer.id != id) return this;
    return HarnessTask(
      id: id,
      name: newer.name ?? name,
      prompt: newer.prompt.isNotEmpty ? newer.prompt : prompt,
      state: newer.state ?? state,
      column: newer.column ?? column,
      priority: newer.priority ?? priority,
      project: newer.project ?? project,
      cwd: newer.cwd ?? cwd,
      sessionId: newer.sessionId ?? sessionId,
      branch: newer.branch ?? branch,
      worktree: newer.worktree ?? worktree,
      createdAt: newer.createdAt ?? createdAt,
      finishedAt: newer.finishedAt ?? finishedAt,
      updatedAt: newer.updatedAt ?? updatedAt,
      queuedAt: newer.queuedAt ?? queuedAt,
      verifiedAt: newer.verifiedAt ?? verifiedAt,
      // An event carries the whole task, so what it leaves out is gone: a
      // task that is retried no longer stopped with an error, one that is
      // restored is not archived any more, one that starts again is no
      // longer returned to the queue or held there.
      outcome: newer.outcome,
      error: newer.error,
      report: newer.report ?? report,
      feedback: newer.feedback.isNotEmpty ? newer.feedback : feedback,
      mergeStatus: newer.mergeStatus,
      conflicts: newer.conflicts,
      verified: newer.verified || verified,
      archived: newer.archived,
      backlog: newer.backlog,
      plan: newer.plan || plan,
      mainTree: newer.mainTree || mainTree,
      noMerge: newer.noMerge || noMerge,
      cannotContinue: newer.cannotContinue || cannotContinue,
      queueSuspended: newer.queueSuspended,
      autoQueue: newer.autoQueue,
      returned: newer.returned,
      returnReason: newer.returnReason,
      hold: newer.hold,
      merged: newer.merged || merged,
      worktreeRemoved: newer.worktreeRemoved || worktreeRemoved,
      model: newer.model ?? model,
      thinking: newer.thinking ?? thinking,
      attachments: newer.attachments.isNotEmpty
          ? newer.attachments
          : attachments,
      extra: {...extra, ...newer.extra},
    );
  }
}

/// What holds a task back in the pending queue (the view's `hold`): the user
/// paused it, or every model it could run on is out of quota or money.
class TaskHold {
  const TaskHold({
    required this.kind,
    this.reason,
    this.until,
    this.guess = false,
  });

  factory TaskHold.fromWire(JsonMap wire) => TaskHold(
    kind: enumName(wire['kind']),
    reason: asString(wire['reason']),
    until: parseTime(wire['until']),
    guess: asBool(wire['guess']),
  );

  /// `paused`, `quota` or `budget`.
  final String kind;
  final String? reason;

  /// When the hold ends, where the harness knows (a quota resets).
  final DateTime? until;

  /// Whether [until] is a guess.
  final bool guess;
}

class TaskFeedback {
  const TaskFeedback({required this.text, this.at});
  final String text;
  final DateTime? at;
}

class TaskSlots {
  const TaskSlots({
    this.project,
    this.limit,
    this.suspended = false,
    this.holders = const [],
    this.queue = const [],
    this.waits = const [],
  });

  factory TaskSlots.fromWire(JsonMap wire) => TaskSlots(
    project: asString(wire['project']),
    limit: asInt(wire['limit']),
    suspended: asBool(wire['suspended']),
    holders: asMapList(wire['holders']),
    queue: asMapList(wire['queue']),
    waits: asMapList(wire['waits']),
  );

  final String? project;
  final int? limit;
  final bool suspended;
  final List<JsonMap> holders;
  final List<JsonMap> queue;
  final List<JsonMap> waits;
}

class TaskSettingsInfo {
  const TaskSettingsInfo({
    this.maxRunning,
    this.queueSuspended = false,
    this.backlogMode = 'manual',
    this.requireVerification = true,
    this.model,
    this.thinking,
    this.permissionMode,
    this.nonInteractive = false,
    this.refineModel,
    this.planModel,
    this.inlineAttachments = const [],
  });

  factory TaskSettingsInfo.fromWire(JsonMap wire) => TaskSettingsInfo(
    maxRunning: asInt(wire['maxRunning'] ?? wire['max-running']),
    queueSuspended: asBool(wire['queueSuspended'] ?? wire['queue-suspended']),
    backlogMode: asStringOr(
      wire['backlogMode'] ?? wire['backlog-mode'],
      'manual',
    ),
    requireVerification: asBool(
      wire['requireVerification'] ?? wire['require-verification'],
      fallback: true,
    ),
    model: asString(wire['model']),
    thinking: asString(wire['thinking']),
    permissionMode: asString(wire['permissionMode'] ?? wire['permission-mode']),
    nonInteractive: asBool(wire['nonInteractive'] ?? wire['non-interactive']),
    refineModel: asString(wire['refineModel'] ?? wire['refine-model']),
    planModel: asString(wire['planModel'] ?? wire['plan-model']),
    inlineAttachments: [
      for (final type in asList(
        wire['inlineAttachments'] ?? wire['inline-attachments'],
      ))
        if (asString(type) case final mime?) mime,
    ],
  );

  final int? maxRunning;
  final bool queueSuspended;
  final String backlogMode;
  final bool requireVerification;
  final String? model;
  final String? thinking;
  final String? permissionMode;
  final bool nonInteractive;
  final String? refineModel;
  final String? planModel;

  /// The media types of the files a task takes sent as data: a client that
  /// cannot name a file of the harness's machine, a phone, attaches pictures
  /// that way.  Empty for a harness that does not say, which takes none.
  final List<String> inlineAttachments;

  bool get takesImages =>
      inlineAttachments.any((type) => type.startsWith('image/'));
}

/// What a task's attachment is called: its name, else its file's.
String? _attachmentName(Object? attachment) {
  final wire = asMap(attachment);
  final name = asString(wire['name']);
  if (name != null && name.isNotEmpty) return name;
  final path = asString(wire['path']);
  if (path == null || path.isEmpty) return null;
  return path.split('/').last;
}

String? _blankToNull(String? value) =>
    value == null || value.trim().isEmpty ? null : value;

String _truncate(String value, int max) =>
    value.length <= max ? value : '${value.substring(0, max - 1)}…';

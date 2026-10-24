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
    this.model,
    this.thinking,
    this.attachments = const [],
    this.extra = const {},
  });

  factory HarnessTask.fromWire(JsonMap wire) {
    final report = asMap(wire['report']);
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
      report: report.isEmpty ? null : TaskReport.fromWire(report),
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
  final TaskReport? report;
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
    _ => 6,
  };

  bool get needsInput => columnName == 'needs-input';
  bool get isReview => columnName == 'review';
  bool get isActive => columnName == 'active';
  bool get isPending => columnName == 'pending';
  bool get isBacklog => columnName == 'backlog';
  bool get isMerging => columnName == 'merging';
  bool get isDone => columnName == 'done';
  bool get isStopped => outcome != null && !isDone;

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
      outcome: newer.outcome ?? outcome,
      error: newer.error ?? error,
      report: newer.report ?? report,
      feedback: newer.feedback.isNotEmpty ? newer.feedback : feedback,
      mergeStatus: newer.mergeStatus ?? mergeStatus,
      conflicts: newer.conflicts.isNotEmpty ? newer.conflicts : conflicts,
      verified: newer.verified || verified,
      archived: newer.archived || archived,
      backlog: newer.backlog,
      plan: newer.plan || plan,
      mainTree: newer.mainTree || mainTree,
      noMerge: newer.noMerge || noMerge,
      cannotContinue: newer.cannotContinue || cannotContinue,
      queueSuspended: newer.queueSuspended,
      autoQueue: newer.autoQueue,
      model: newer.model ?? model,
      thinking: newer.thinking ?? thinking,
      attachments: newer.attachments.isNotEmpty
          ? newer.attachments
          : attachments,
      extra: {...extra, ...newer.extra},
    );
  }
}

class TaskReport {
  const TaskReport({
    this.summary = '',
    this.problem = '',
    this.evidence = const [],
    this.reproduction,
    this.noMerge = false,
    this.cannotContinue = false,
    this.missing = false,
    this.at,
  });

  static TaskReport fromWire(JsonMap wire) => TaskReport(
    summary: asStringOr(wire['summary'], ''),
    problem: asStringOr(wire['problem'], ''),
    evidence: asMapList(wire['evidence']),
    reproduction: asString(wire['reproduction']),
    noMerge: asBool(wire['noMerge'] ?? wire['no-merge']),
    cannotContinue: asBool(wire['cannotContinue'] ?? wire['cannot-continue']),
    missing: asBool(wire['missing']),
    at: parseTime(wire['at']),
  );

  /// What the summary says, Markdown as the session wrote it.  For a report
  /// that is [missing] it is the last message the session wrote.
  final String summary;

  /// What must be fixed and how to see it, Markdown: the review shows it at
  /// the top, where the name of the task alone would not say what the work
  /// was for.  A report from before the field has none.
  final String problem;
  final List<JsonMap> evidence;
  final String? reproduction;
  final bool noMerge;
  final bool cannotContinue;
  final bool missing;
  final DateTime? at;

  /// The words of the report as the card of the `hand_in` call in the task's
  /// session draws them (`HandInReportView`), so that a report reads the same
  /// on the board and in the session.  The flags are left out: the sheet of
  /// the task says them itself.
  HandInReport get handIn => HandInReport(
    problem: problem.trim(),
    summary: summary.trim(),
    reproduction: reproduction?.trim(),
    evidence: [
      for (final wire in evidence)
        if (EvidenceItem.fromWire(wire) case final EvidenceItem item) item,
    ],
  );

  /// Evidence items as one short line of text each, for a place with room for
  /// no more (the sheet of a task draws them as they are in the session, from
  /// [handIn]).  The harness writes each with a `kind` (what it resolved the
  /// call's item to); a report from before that, or a call's own input, has
  /// the one of `image`, `video`, `file`, `code`, `note`, `tool_call` it was
  /// asked for: both read the same (`EvidenceItem`).
  List<String> get evidenceLines => [
    for (final wire in evidence)
      if (EvidenceItem.fromWire(wire) case final EvidenceItem item)
        switch (item.kind) {
          'image' => 'Screenshot: ${item.label}',
          'video' => 'Video: ${item.label}',
          'file' => 'File: ${item.label}',
          'code' =>
            'Code: ${(item.caption ?? '').trim().isEmpty ? 'snippet' : item.caption!.trim()}',
          'tool-call' => 'Tool call: ${item.label}',
          _ => (item.text ?? '').trim(),
        },
  ]..removeWhere((line) => line.trim().isEmpty);
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

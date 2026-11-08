import 'dart:async';

import 'package:flutter/foundation.dart';

import '../acp/acp_client.dart';
import '../acp/acp_message.dart';
import '../models/review.dart';
import '../models/task.dart';
import '../services/harness_api.dart';
import 'app_controller.dart';

/// One thing the reviewer wrote and has not sent yet.
///
/// A draft is bound to what it is about: a thread, a place in the diff, the
/// revision that place was read at, or the change as a whole.  It outlives
/// the screen it was written on ([ReviewController] lives with the app) and,
/// once saved ([ReviewController.saveDraft]), the app: the harness keeps it
/// as a comment with no `sent` time, as Emacs keeps the drafts written
/// there.
class ReviewDraft {
  ReviewDraft({
    required this.key,
    this.threadId,
    this.replyTo,
    this.location,
    this.revision,
    this.text = '',
    this.clientId,
    this.commentId,
  });

  /// What the draft is about: `feedback` for the box that sends a task back,
  /// `thread:<id>` for a reply, `new:<file>:<side>:<line>` for a thread on
  /// lines, and `whole` for one on the change as a whole.
  final String key;

  /// The thread a reply is in; null until a new thread is saved.
  String? threadId;

  /// The comment a reply answers.
  String? replyTo;

  /// Where a thread on lines is; null for a reply or the whole change.
  ReviewLocation? location;

  /// The revision the place was read at.  A draft written against one
  /// revision is not moved to another, and the composer says so.
  String? revision;

  String text;

  /// The id the comment is made with.  It is made once: the same id sent
  /// again is the same comment, so a retry after a lost answer adds nothing.
  String? clientId;

  /// The id of the comment the harness keeps, once it is saved there.
  String? commentId;

  bool saving = false;
  String? error;

  bool get isFeedback => key == 'feedback';
  bool get isReply => threadId != null && location == null;

  bool get isBlank => text.trim().isEmpty;

  /// A draft saved on the harness can be edited or taken back there.
  bool get isSaved => commentId != null;
}

/// What the review says last: a thing done, or why it could not be.
class ReviewNotice {
  const ReviewNotice(this.text, {this.error = false});

  final String text;
  final bool error;
}

/// The review moved on while a file's diff was being read.  The answer is
/// for lines no longer shown, and must not enter the cache or a comment.
class ReviewStale implements Exception {
  const ReviewStale();

  @override
  String toString() => 'The review changed while it was being read';
}

/// A task's review, as its reviewer works through it on a phone.
///
/// It holds what the harness keeps (`patch-review/get`, the files at
/// `patch-review/changes`, the marks at `patch-review/viewed`) and one
/// file's diff at a time (`patch-review/diff`).  Everything the reviewer
/// does is an operation of the harness's own review:
///
///  * a comment, a reply or a new thread is `add-comment`, a draft until the
///    feedback sends it (`patch-review/apply`);
///  * closing or opening a thread is `set-status`, and saying a close was
///    looked at is `mark-reviewed`;
///  * viewed and approved files are `patch-review/set-viewed`, kept by path
///    and blob, and a file newly commented on loses its approval as it does
///    in Emacs;
///  * sending feedback is `task/reject` (the harness adds the drafts), and
///    sending replies to a task at work is `patch-review/send-replies`.
///
/// Nothing is a phone-only store: what is written here is read by Emacs, by
/// another device, and by the agent.
class ReviewController extends ChangeNotifier {
  ReviewController({
    required this.api,
    required this.taskId,
    this.task,
    this.app,
    String Function()? newId,
    Map<String, ReviewDraft>? drafts,
  }) : _newId = newId ?? _defaultNewId,
       _drafts = drafts ?? <String, ReviewDraft>{};

  final HarnessApi api;
  final String taskId;
  final AppController? app;
  final String Function() _newId;

  HarnessTask? task;

  ReviewSet? set;
  ReviewChanges? changes;
  ReviewViewed viewed = const ReviewViewed();
  ReviewLastClose? lastClose;

  bool loading = false;
  bool refreshing = false;
  String? error;
  ReviewNotice? notice;
  bool sending = false;

  /// The revision the shown changes are read at.  A newer revision the
  /// harness reports is not shown under the old one: [stale] says there is
  /// one, and the reviewer reloads when they choose to.
  bool stale = false;
  String? staleRevision;

  /// The version the reviewer chose to read, by its id; nil is the newest
  /// -- the task's branch before its first hand-in.  Changing it reads that
  /// version's files and diff and leaves the drafts where they were written:
  /// a draft names its own revision, not this one.
  String? selectedVersion;

  /// The revision of the newest version read last, whether it is the one
  /// shown or not.
  String? newestRevision;

  /// The file the diff shows, and the files the reviewer closed in the tree.
  String? selectedPath;
  final Set<String> collapsedDirectories = <String>{};

  /// How the threads are filtered, in the list and in the diff.
  ReviewThreadFilter threadFilter = ReviewThreadFilter.all;

  /// Deliberate controls for code that is wider than the phone: wrapping,
  /// and a split view on a screen wide enough for two columns.  They are
  /// kept for the review, as the file and hunk the reviewer is at are.
  bool wrapLines = false;
  bool splitView = false;
  bool skipApproved = true;
  bool treeView = true;

  /// Where the reviewer was in each file, and which hunk they were at.
  final Map<String, double> scrollOffsets = <String, double>{};
  final Map<String, int> hunkIndices = <String, int>{};
  final Set<String> _viewBusy = <String>{};

  /// The drafts of this review.  They are the app's, not this controller's:
  /// a connection that drops and comes back reads the review again, and what
  /// was typed but not sent is still there, bound to the task, thread and
  /// revision it was written against.
  final Map<String, ReviewDraft> _drafts;
  String? _activeDraft;

  final Map<String, ReviewFileDiff> _diffs = <String, ReviewFileDiff>{};
  final Map<String, Future<ReviewFileDiff>> _diffRequests =
      <String, Future<ReviewFileDiff>>{};
  final Set<String> diffLoading = <String>{};
  final Map<String, String> diffErrors = <String, String>{};

  StreamSubscription<AcpNotification>? _events;
  Timer? _refreshTimer;
  Timer? _reloadTimer;
  bool _attached = false;
  bool _disposed = false;
  bool _wasConnected = false;
  int _generation = 0;
  int _diffGeneration = 0;
  int _refreshToken = 0;
  int _threadsToken = 0;

  /// Every diff request and answer belongs to the review that asked for it.
  /// A key is a revision and a path together: the same path at two revisions
  /// is two different files, and an answer for one is never another's.
  String _diffKey(String? revision, String path) =>
      '${revision ?? ''}\u0000$path';

  /// Forget every diff answer on its way: the selection moved, the
  /// connection came back, or the page is gone.  The callbacks of those
  /// requests see a different generation and leave the new state alone.
  void _invalidateDiffs({bool clearCache = false}) {
    _diffGeneration++;
    _diffRequests.clear();
    diffLoading.clear();
    diffErrors.clear();
    if (clearCache) _diffs.clear();
  }

  /// Whether this controller has been let go; a read that comes back then
  /// has nowhere to put its answer.
  bool get isDisposed => _disposed;

  /// The files in the order a reviewer goes through them: the tree, top to
  /// bottom, else the diff's order.
  List<ChangedFile> navigationFiles = const [];

  static String _defaultNewId() {
    _phoneCounter++;
    final now = DateTime.now().microsecondsSinceEpoch;
    return 'c-phone-$now-${_phoneCounter.toRadixString(36)}';
  }

  static int _phoneCounter = 0;

  // ---- What the page says ------------------------------------------------

  bool get isReview => task?.isReview ?? false;
  bool get isWorking => task != null && !isReview && !task!.isClosed;
  bool get canReview => changes != null && set != null;

  int get fileCount => changes?.files.length ?? 0;
  int get threadCount => set?.threads.length ?? 0;
  List<ReviewVersion> get versions => set?.versions ?? const <ReviewVersion>[];
  ReviewVersion? get latestVersion => set?.latestVersion;

  /// More than one version to read: the newest and the ones handed in
  /// before it.
  bool get hasVersions => versions.length > 1;

  /// Whether the version shown is one of the earlier hand-ins.  It is read,
  /// not reviewed: no file of it is marked seen or approved, as in Emacs.
  bool get readOnlyVersion => selectedVersion != null;
  int get openThreadCount => set?.openThreads ?? 0;
  int get toReviewCount => set?.toReview ?? 0;
  int get reviewedFileCount => changes?.files.where(viewed.isSeen).length ?? 0;
  int get approvedFileCount =>
      changes?.files.where(viewed.isApproved).length ?? 0;
  int get sendableDraftCount => set?.sendableDrafts.length ?? 0;

  /// The drafts on the device, saved or not, with words.
  List<ReviewDraft> get localDrafts => [
    for (final draft in _drafts.values)
      if (!draft.isBlank) draft,
  ];

  /// How many drafts there are, counted once: one saved on this phone is a
  /// local draft and a comment of the harness's set both, and is one reply.
  int get draftCount {
    final local = localDrafts;
    final saved = <String>{
      for (final draft in local)
        if (draft.commentId != null) draft.commentId!,
    };
    var count = local.length;
    for (final comment in set?.sendableDrafts ?? const <ReviewComment>[]) {
      if (!saved.contains(comment.id)) count++;
    }
    return count;
  }

  bool get hasSomethingToSend =>
      draftCount > 0 || lastClose != null || feedbackText.trim().isNotEmpty;

  /// The message box of the feedback sheet, which is not a comment until it
  /// is sent with the drafts.
  String feedbackText = '';

  ChangedFile? get selectedFile {
    final path = selectedPath;
    if (path == null) return null;
    return changes?.file(path);
  }

  ReviewThread? thread(String id) => set?.thread(id);

  List<ReviewThread> get threads {
    final all = set?.threads ?? const <ReviewThread>[];
    return [
      for (final thread in all)
        if (threadFilter.matches(
          thread,
          hasDraft:
              thread.drafted > 0 || _localDraftForThread(thread.id) != null,
        ))
          thread,
    ];
  }

  /// The threads a file's diff shows: those placed on it at the revision
  /// shown.  One written against an earlier revision stays in the threads
  /// list with its own place and revision, not under a line it never saw.
  /// The threads on [path] at [revision], the shown one by default.  A diff
  /// still on screen while the selection moves reads its own revision, not
  /// the one the controller has already chosen.
  List<ReviewThread> threadsForFile(
    String path, {
    String? revision,
    String? oldPath,
  }) {
    if (set == null) return const [];
    final file = changes?.file(path);
    final atRevision = revision ?? changes?.revision;
    return [
      for (final thread in set!.threadsForFile(
        path,
        oldPath: oldPath ?? file?.oldPath,
      ))
        if (_sameRevision(thread.revision, atRevision)) thread,
    ]..sort((a, b) {
      final lineA = a.location?.line ?? 0;
      final lineB = b.location?.line ?? 0;
      if (lineA != lineB) return lineA.compareTo(lineB);
      return a.id.compareTo(b.id);
    });
  }

  List<ReviewThread> threadsForHunk(
    DiffHunk hunk,
    String path, {
    String? revision,
    String? oldPath,
  }) => [
    for (final thread in threadsForFile(
      path,
      revision: revision,
      oldPath: oldPath,
    ))
      if (_threadInHunk(thread, hunk)) thread,
  ];

  bool _threadInHunk(ReviewThread thread, DiffHunk hunk) {
    final location = thread.location;
    final line = location?.line;
    if (location == null || line == null) return false;
    final start = location.endLine ?? line;
    return hunk.contains(location.side, start) ||
        hunk.contains(location.side, line);
  }

  bool _sameRevision(String? threadRevision, String? shown) =>
      shown == null || threadRevision == null || threadRevision == shown;

  /// A thread written against the revision shown.
  bool onShownRevision(ReviewThread thread) {
    final shown = changes?.revision;
    return shown == null || thread.revision == null || thread.revision == shown;
  }

  bool draftIsEarlier(ReviewDraft draft) {
    final shown = changes?.revision;
    return draft.revision != null && shown != null && draft.revision != shown;
  }

  ReviewDraft? _localDraftForThread(String threadId) {
    for (final draft in _drafts.values) {
      if (draft.threadId == threadId && !draft.isBlank) return draft;
    }
    return null;
  }

  /// The draft for [key], made at [threadId], [location] and [revision] when
  /// there is none yet.  A draft already written is not moved to another
  /// thread or place: the wrong-thread reply cannot happen by opening
  /// another composer.
  ReviewDraft draftFor(
    String key, {
    String? threadId,
    String? replyTo,
    ReviewLocation? location,
    String? revision,
  }) {
    final existing = _drafts[key];
    if (existing != null) return existing;
    final draft = ReviewDraft(
      key: key,
      threadId: threadId,
      replyTo: replyTo,
      location: location,
      revision: revision ?? changes?.revision,
      clientId: _newId(),
    );
    _drafts[key] = draft;
    return draft;
  }

  ReviewDraft feedbackDraft() => draftFor('feedback');

  void setActiveDraft(String? key) {
    _activeDraft = key;
    notifyListeners();
  }

  String? get activeDraftKey => _activeDraft;

  void updateDraft(ReviewDraft draft, String text) {
    draft.text = text;
    draft.error = null;
    notifyListeners();
  }

  void setFeedbackText(String text) {
    feedbackText = text;
    notifyListeners();
  }

  // ---- Loading -----------------------------------------------------------

  void attach() {
    if (_attached) return;
    _attached = true;
    _events = api.notifications.listen(_onNotification);
    app?.addListener(_onAppChanged);
    _wasConnected = app?.isConnected ?? true;
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _refreshToken++;
    _threadsToken++;
    _invalidateDiffs(clearCache: true);
    // The page is gone; nothing that was in flight may leave it saying it
    // still is.
    loading = false;
    refreshing = false;
    sending = false;
    _events?.cancel();
    _refreshTimer?.cancel();
    _reloadTimer?.cancel();
    app?.removeListener(_onAppChanged);
    super.dispose();
  }

  /// A read that comes back after the connection that asked for it is gone
  /// has nothing to say: the page it was for is gone too.
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  /// Read the review, its files and its marks.  A load that finds a newer
  /// revision keeps the diff the reviewer is reading and says so ([stale]);
  /// [force] takes the newer one.
  Future<void> load({bool force = true, bool quiet = false}) async {
    if (_disposed) return;
    if (!quiet) loading = set == null;
    error = null;
    final mine = ++_generation;
    // A diff read on its way is for the files the reviewer saw before this
    // read; the new answer is the only one that may be kept.
    _invalidateDiffs();
    bool mineStill() => !_disposed && mine == _generation;
    notifyListeners();
    try {
      final closeFuture = api.can('patch-review/last-close')
          ? api.reviewLastClose(taskId).catchError((_) => null)
          : Future<ReviewLastClose?>.value(null);
      final taskFuture = api.can('task/get')
          ? api
                .task(taskId)
                .then<HarnessTask?>((loaded) => loaded)
                .catchError((_) => null)
          : Future<HarnessTask?>.value(null);
      final chosen = selectedVersion;
      final newestFuture = api.reviewChanges(taskId);
      final selectedFuture = chosen == null
          ? Future<ReviewChanges?>.value(null)
          : api
                .reviewChanges(taskId, version: chosen)
                .then<ReviewChanges?>((loaded) => loaded);
      final results = await Future.wait<Object?>([
        api.review(taskId),
        newestFuture,
        selectedFuture,
        api.reviewViewed(taskId),
        closeFuture,
        taskFuture,
      ]);
      if (!mineStill()) return;
      final loadedSet = results[0] as ReviewSet;
      final newest = results[1] as ReviewChanges;
      final selected = chosen == null ? newest : results[2] as ReviewChanges;
      final loadedViewed = results[3] as ReviewViewed;
      final loadedClose = results[4] as ReviewLastClose?;
      if (results[5] is HarnessTask) task = results[5] as HarnessTask;
      set = loadedSet;
      viewed = loadedViewed;
      lastClose = loadedClose;
      newestRevision = newest.revision;
      final previous = changes;
      final newer =
          previous != null &&
          previous.revision.isNotEmpty &&
          newest.revision.isNotEmpty &&
          previous.revision != newest.revision;
      if (chosen == null && newer && !force) {
        // A newer hand-in waits behind the banner: what is on screen is
        // still the revision the comments on it were written at.
        stale = true;
        staleRevision = newest.revision;
      } else {
        changes = selected;
        stale = false;
        staleRevision = null;
        if (previous == null || previous.revision != selected.revision) {
          _invalidateDiffs(clearCache: true);
        }
        navigationFiles = _navigationOrder(selected);
        if (selectedPath == null || selected.file(selectedPath!) == null) {
          selectedPath = navigationFiles.isEmpty
              ? null
              : navigationFiles.first.path;
        }
      }
    } on AcpException catch (failure) {
      if (mineStill()) {
        error = failure.message;
        if (failure.isMethodNotFound) {
          error = 'Review unavailable';
        }
      }
    } catch (failure) {
      if (mineStill()) error = '$failure';
    } finally {
      if (mineStill()) {
        loading = false;
        notifyListeners();
      }
    }
  }

  /// Read the version [id] (nil for the newest).  Drafts keep the revision
  /// they were written at; only the files and the diff change.
  Future<bool> selectVersion(String? id) async {
    if (_disposed) return false;
    if (id != null && id.isEmpty) id = null;
    final latest = set?.latestVersion;
    final normalize =
        latest != null &&
            (id == latest.id || (latest.tip != null && id == latest.tip))
        ? null
        : id;
    final previous = selectedVersion;
    if (normalize == previous) return true;
    selectedVersion = normalize;
    await load(force: true, quiet: true);
    // A later selection owns the page now: its notice and its error are its
    // own, and this one must neither report nor roll it back.
    if (_disposed || selectedVersion != normalize) return false;
    if (error != null) {
      // The version did not read: keep the one whose files are still shown,
      // and keep every draft where it was written.
      selectedVersion = previous;
      notifyListeners();
      return false;
    }
    notice = ReviewNotice(
      normalize == null
          ? 'Newest version'
          : 'Version ${revisionLabel(normalize)}',
    );
    notifyListeners();
    return true;
  }

  /// The version [revision] was handed in as, or nil when the set knows no
  /// such revision.
  ReviewVersion? versionForRevision(String? revision) {
    if (revision == null || revision.isEmpty) return null;
    for (final version in versions) {
      if (version.id == revision || version.tip == revision) return version;
    }
    return null;
  }

  /// Read the version a comment was written at, so that its lines are the
  /// lines it names.  False when the review no longer has that revision.
  Future<bool> showRevision(String? revision) async {
    if (revision == null || revision.isEmpty) return true;
    if (changes?.revision == revision) return true;
    final version = versionForRevision(revision);
    if (version == null) {
      notice = const ReviewNotice('Revision unavailable', error: true);
      notifyListeners();
      return false;
    }
    return selectVersion(version.id);
  }

  Future<void> reload({bool force = true}) => load(force: force, quiet: true);

  void _onAppChanged() {
    final connected = app?.isConnected ?? true;
    if (connected && !_wasConnected) {
      // The connection came back: read what the harness has now.  The
      // reviewer's drafts stay on the phone, bound to their revision.
      unawaited(load(force: false, quiet: true));
    }
    _wasConnected = connected;
  }

  void _onNotification(AcpNotification notification) {
    if (notification.method != '_harness/event') return;
    final event = asStringOr(notification.params['event'], '');
    final args = asList(notification.params['args']);
    switch (event) {
      case 'patch-review/changed':
        if (args.isEmpty || asString(args.first) != taskId) return;
        _scheduleRefresh();
      case 'patch-review/last-close':
        if (args.isEmpty || asString(args.first) != taskId) return;
        final wire = asMap(args.length > 1 ? args[1] : null);
        lastClose = wire.isEmpty ? null : ReviewLastClose.fromWire(wire);
        notifyListeners();
      case 'task/changed':
      case 'task/review':
      case 'task/done':
        final wire = asMap(args.isEmpty ? null : args.first);
        final id = asString(wire['id']);
        if (id != taskId) return;
        task = HarnessTask.fromWire(wire);
        _scheduleRefresh();
      case 'harness/reloaded':
        _scheduleRefresh();
    }
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(_refreshQuietly());
    });
  }

  Future<void> _refreshQuietly() async {
    if (_disposed) return;
    final token = ++_refreshToken;
    final mine = _generation;
    final chosen = selectedVersion;
    bool current() =>
        !_disposed &&
        token == _refreshToken &&
        mine == _generation &&
        chosen == selectedVersion;
    refreshing = true;
    notifyListeners();
    try {
      final loadedSet = await api.review(taskId);
      if (!current()) return;
      final loadedViewed = await api.reviewViewed(taskId);
      if (!current()) return;
      final loadedChanges = chosen == null
          ? await api.reviewChanges(taskId)
          : await api.reviewChanges(taskId, version: chosen);
      if (!current()) return;
      final newest = chosen == null
          ? loadedChanges
          : await api.reviewChanges(taskId);
      if (!current()) return;
      ReviewLastClose? loadedClose;
      final closes = api.can('patch-review/last-close');
      if (closes) {
        loadedClose = await api.reviewLastClose(taskId).catchError((_) => null);
        if (!current()) return;
      }
      // The whole answer is applied at once, only if the selection that
      // asked for it is still the one on screen.  A version chosen while
      // these reads were out is not overwritten by the old one.
      set = loadedSet;
      viewed = loadedViewed;
      newestRevision = newest.revision;
      if (closes) lastClose = loadedClose;
      final previous = changes;
      if (chosen == null &&
          previous != null &&
          previous.revision.isNotEmpty &&
          newest.revision.isNotEmpty &&
          previous.revision != newest.revision) {
        stale = true;
        staleRevision = newest.revision;
      } else {
        if (previous == null || previous.revision != loadedChanges.revision) {
          _invalidateDiffs(clearCache: true);
        }
        changes = loadedChanges;
        stale = false;
        staleRevision = null;
        navigationFiles = _navigationOrder(loadedChanges);
        if (selectedPath == null || loadedChanges.file(selectedPath!) == null) {
          selectedPath = navigationFiles.isEmpty
              ? null
              : navigationFiles.first.path;
        }
      }
    } catch (_) {
      // A quiet refresh that fails leaves what the reviewer is reading; the
      // connection banner and the next read say the rest.
    } finally {
      if (!_disposed && token == _refreshToken) {
        refreshing = false;
        notifyListeners();
      }
    }
  }

  /// Take the newer revision the harness reported.
  Future<void> takeNewRevision() async {
    if (_disposed) return;
    final previous = selectedVersion;
    selectedVersion = null;
    await load(force: true, quiet: true);
    if (_disposed || selectedVersion != null) return;
    if (error != null) {
      selectedVersion = previous;
      notifyListeners();
      return;
    }
    notice = const ReviewNotice('Revision loaded');
    notifyListeners();
  }

  // ---- Files and navigation ---------------------------------------------

  List<ChangedFile> _navigationOrder(ReviewChanges loaded) {
    final rows = flattenReviewTree(
      buildReviewTree(loaded.files),
      collapsed: collapsedDirectories,
    );
    final ordered = [
      for (final row in rows)
        if (row.file != null) row.file!,
    ];
    // A file the tree leaves out (it has no path) stays reachable.
    for (final file in loaded.files) {
      if (!ordered.any((seen) => seen.path == file.path)) ordered.add(file);
    }
    return ordered;
  }

  void selectFile(String path) {
    if (changes?.file(path) == null) return;
    selectedPath = path;
    notifyListeners();
  }

  void toggleDirectory(String path) {
    if (!collapsedDirectories.remove(path)) collapsedDirectories.add(path);
    if (changes != null) navigationFiles = _navigationOrder(changes!);
    notifyListeners();
  }

  bool directoryExpanded(String path) => !collapsedDirectories.contains(path);

  /// The next file a reviewer goes to, stepping over the files already
  /// approved when [skipApproved] is on -- unless every file is approved,
  /// when there is nowhere else to go.
  String? nextFile() => _stepFile(1);

  String? previousFile() => _stepFile(-1);

  String? _stepFile(int direction) {
    final files = navigationFiles;
    if (files.isEmpty) return null;
    final current = selectedPath == null
        ? -1
        : files.indexWhere((file) => file.path == selectedPath);
    var candidates = files;
    if (skipApproved) {
      final unapproved = [
        for (final file in files)
          if (!viewed.isApproved(file)) file,
      ];
      if (unapproved.isNotEmpty) candidates = unapproved;
    }
    if (candidates.isEmpty) return null;
    if (current < 0) {
      final first = direction > 0 ? candidates.first : candidates.last;
      selectFile(first.path);
      return first.path;
    }
    final here = files[current];
    final at = candidates.indexWhere((file) => file.path == here.path);
    final target = at < 0
        ? (direction > 0 ? candidates.first : candidates.last)
        : candidates[(at + direction) % candidates.length];
    selectFile(target.path);
    return target.path;
  }

  void setWrapLines(bool wrap) {
    wrapLines = wrap;
    notifyListeners();
  }

  void setSplitView(bool split) {
    splitView = split;
    notifyListeners();
  }

  void setSkipApproved(bool skip) {
    skipApproved = skip;
    notifyListeners();
  }

  void setTreeView(bool tree) {
    treeView = tree;
    notifyListeners();
  }

  void setThreadFilter(ReviewThreadFilter filter) {
    threadFilter = filter;
    notifyListeners();
  }

  void saveScrollOffset(String path, double offset) {
    scrollOffsets[path] = offset;
  }

  void saveHunkIndex(String path, int index) {
    hunkIndices[path] = index;
  }

  int hunkIndexFor(String path) => hunkIndices[path] ?? 0;

  /// The next or previous thread of the list, or of one file's threads.
  ReviewThread? stepThread(int direction, {String? fromId, String? file}) {
    final all = file == null
        ? threads
        : [
            for (final thread in threads)
              if (thread.file == file) thread,
          ];
    if (all.isEmpty) return null;
    final from = fromId == null
        ? -1
        : all.indexWhere((thread) => thread.id == fromId);
    final at = from < 0
        ? (direction > 0 ? 0 : all.length - 1)
        : (from + direction) % all.length;
    return all[at];
  }

  // ---- Diffs -------------------------------------------------------------

  /// One file's diff at the revision shown.  It is read once and kept for
  /// that revision and path together; a newer revision ([load]) invalidates
  /// every answer on its way and its cache.
  Future<ReviewFileDiff> diffFor(String path) {
    if (_disposed) return Future.error(const ReviewStale());
    final source = changes;
    final revision = source?.revision;
    final key = _diffKey(revision, path);
    final cached = _diffs[key];
    if (cached != null) return Future.value(cached);
    final pending = _diffRequests[key];
    if (pending != null) return pending;
    diffLoading.add(key);
    diffErrors.remove(key);
    notifyListeners();
    final mine = _diffGeneration;
    final completer = Completer<ReviewFileDiff>();
    final request = completer.future;
    _diffRequests[key] = request;
    bool stale() =>
        _disposed ||
        mine != _diffGeneration ||
        !identical(_diffRequests[key], request);
    unawaited(
      Future<ReviewFileDiff>.sync(
        () => api.reviewDiff(taskId, path, version: source?.versionId),
      ).then(
        (diff) {
          if (stale()) {
            if (!completer.isCompleted) {
              completer.completeError(const ReviewStale());
            }
            return;
          }
          _diffRequests.remove(key);
          diffLoading.remove(key);
          diffErrors.remove(key);
          _diffs[key] = diff;
          // A revision from the harness is the one the lines are at, even
          // if a caller named the version by another name.
          final actual = diff.revision;
          if (actual != null && actual.isNotEmpty) {
            _diffs[_diffKey(actual, path)] = diff;
          }
          notifyListeners();
          if (!completer.isCompleted) completer.complete(diff);
        },
        onError: (Object failure, StackTrace stack) {
          if (stale()) {
            if (!completer.isCompleted) {
              completer.completeError(const ReviewStale());
            }
            return;
          }
          _diffRequests.remove(key);
          diffLoading.remove(key);
          diffErrors[key] = failure is AcpException
              ? failure.message
              : '$failure';
          notifyListeners();
          if (!completer.isCompleted) {
            completer.completeError(failure, stack);
          }
        },
      ),
    );
    return request;
  }

  /// The diff of [path] at the revision shown, if it has been read.
  ReviewFileDiff? cachedDiff(String path) =>
      _diffs[_diffKey(changes?.revision, path)];

  /// The diff of [path] at [revision], if it has been read.
  ReviewFileDiff? cachedDiffAt(String path, String? revision) =>
      _diffs[_diffKey(revision, path)];

  /// Whether the diff of [path] at the shown revision (or [revision]) is
  /// being read.  Its key is the revision and the path together.
  bool diffIsLoading(String path, {String? revision}) =>
      diffLoading.contains(_diffKey(revision ?? changes?.revision, path));

  /// Why the diff of [path] at the shown revision (or [revision]) failed,
  /// if it did.
  String? diffError(String path, {String? revision}) =>
      diffErrors[_diffKey(revision ?? changes?.revision, path)];

  // ---- Comments and threads ---------------------------------------------

  /// Save one draft on the harness.  A draft with no words and no saved
  /// comment is dropped; a saved comment is edited, or first added with the
  /// id it will keep, so a retry after a lost answer adds nothing twice.
  Future<bool> saveDraft(String key) async {
    final draft = _drafts[key];
    if (draft == null) return false;
    if (draft.saving) return false;
    if (draft.isBlank && draft.commentId == null) {
      _drafts.remove(key);
      notifyListeners();
      return true;
    }
    if (draft.isBlank && draft.commentId != null) return false;
    draft.saving = true;
    draft.error = null;
    notifyListeners();
    try {
      if (draft.commentId != null) {
        await api.reviewApply(taskId, {
          'op': 'edit-comment',
          'comment': draft.commentId,
          'body': draft.text.trim(),
        });
      } else {
        final threadId = draft.threadId;
        final comment = <String, Object?>{
          'id': draft.clientId,
          'body': draft.text.trim(),
          if (threadId != null && threadId.isNotEmpty) 'thread': threadId,
          if (draft.replyTo != null) 'reply-to': draft.replyTo,
          if (draft.revision != null) 'revision': draft.revision,
          if (draft.location != null) 'location': draft.location!.toWire(),
        };
        await api.reviewApply(taskId, {
          'op': 'add-comment',
          'comment': comment,
          if (threadId != null && threadId.isNotEmpty) 'thread': threadId,
        });
        draft.commentId = draft.clientId;
        // The thread of a new comment is the harness's to make: read it
        // back, so the draft and the page know where the comment is.  If a
        // version was chosen while this was out, that read owns the page;
        // its answer is the one to keep.
        ReviewSet? loadedSet;
        if (draft.threadId == null || draft.threadId!.isEmpty) {
          final mine = _generation;
          final chosen = selectedVersion;
          final loaded = await api.review(taskId);
          loadedSet = loaded;
          final found = _threadOfComment(loaded, draft.commentId!);
          if (found != null) draft.threadId = found;
          if (!_disposed && mine == _generation && chosen == selectedVersion) {
            set = loaded;
          }
        }
        // A reply in a closed thread opens it again: the person has more
        // to say, so the point is not done (the harness's UI does the same).
        final thread = draft.threadId == null
            ? null
            : (loadedSet ?? set)?.thread(draft.threadId!);
        if (thread != null && !thread.isOpen) {
          await api.reviewApply(taskId, {
            'op': 'set-status',
            'thread': thread.id,
            'status': 'open',
          });
        }
        // A comment on a file of the newest revision takes its approval
        // off.  One written at an earlier revision does not: that revision
        // has no marks, and the newest file is not the one it names.
        final anchor = draft.revision;
        final shown = changes?.revision;
        if (!readOnlyVersion &&
            (anchor == null || anchor.isEmpty || anchor == shown)) {
          final file = draft.location == null
              ? null
              : changes?.file(draft.location!.file);
          if (file != null) await _withdrawApproval(file);
        }
      }
      draft.saving = false;
      await _refreshThreadsQuietly();
      notifyListeners();
      return true;
    } catch (failure) {
      draft.saving = false;
      draft.error = failure is AcpException ? failure.message : '$failure';
      notice = ReviewNotice(draft.error!, error: true);
      notifyListeners();
      return false;
    }
  }

  /// What to call [revision]: its version's name, else it shortened.
  String revisionLabel(String? revision) {
    if (revision == null || revision.isEmpty) return '';
    for (final version in set?.versions ?? const <ReviewVersion>[]) {
      if (version.id == revision) {
        return '${version.name} · ${shortRevisionOf(revision)}';
      }
    }
    return shortRevisionOf(revision);
  }

  /// What [revision] is against the diff shown: an earlier or a later
  /// version, or one the set does not know.  Null when it is the same.
  String? revisionNote(String? revision) {
    if (revision == null || revision.isEmpty) return null;
    final shown = changes?.revision;
    if (shown == null || shown.isEmpty || revision == shown) return null;
    final at = versions.indexWhere(
      (version) => version.id == revision || version.tip == revision,
    );
    final here = versions.indexWhere(
      (version) => version.id == shown || version.tip == shown,
    );
    if (at < 0 || here < 0) return 'Another revision';
    return at < here ? 'Earlier revision' : 'Later revision';
  }

  /// Whether [revision] is an earlier one than the diff shown.
  bool earlierRevision(String? revision) =>
      revisionNote(revision) == 'Earlier revision';

  String? _threadOfComment(ReviewSet loaded, String commentId) {
    for (final thread in loaded.threads) {
      if (thread.comment(commentId) != null) return thread.id;
    }
    return null;
  }

  /// Take a draft back: from the harness when it is saved there, from the
  /// device either way.
  Future<bool> discardDraft(String key) async {
    final draft = _drafts.remove(key);
    if (draft == null) return true;
    notifyListeners();
    if (draft.commentId == null) return true;
    try {
      await api.reviewApply(taskId, {
        'op': 'delete-comment',
        'comment': draft.commentId,
      });
      await _refreshThreadsQuietly();
      return true;
    } catch (failure) {
      draft.commentId = null;
      draft.error = failure is AcpException ? failure.message : '$failure';
      _drafts[key] = draft;
      notice = ReviewNotice(draft.error!, error: true);
      notifyListeners();
      return false;
    }
  }

  Future<void> _refreshThreadsQuietly() async {
    if (_disposed) return;
    final mine = _generation;
    final chosen = selectedVersion;
    final token = ++_threadsToken;
    try {
      final loaded = await api.review(taskId);
      // A version chosen while the threads were out owns the review now;
      // its own read is the one whose set may be shown.
      if (_disposed ||
          token != _threadsToken ||
          mine != _generation ||
          chosen != selectedVersion) {
        return;
      }
      set = loaded;
    } catch (_) {
      // The operation itself succeeded; the next read catches up.
    }
  }

  /// A reply in [thread]: a draft until the reviewer sends the feedback or
  /// the replies.  Reply-to is the comment answered, else the thread's last.
  ReviewDraft replyDraft(ReviewThread thread, {ReviewComment? to}) {
    final key = 'thread:${thread.id}';
    final parent = to ?? thread.last;
    final draft = draftFor(
      key,
      threadId: thread.id,
      replyTo: parent?.id,
      revision: thread.revision ?? changes?.revision,
    );
    if (to != null && draft.text.trim().isEmpty && draft.commentId == null) {
      draft.replyTo = to.id;
      draft.text = '${to.quoteMarkdown}\n\n';
    }
    return draft;
  }

  /// A draft that edits the saved draft [comment] of [thread].
  ReviewDraft editCommentDraft(ReviewThread thread, ReviewComment comment) {
    final key = 'edit:${comment.id}';
    final draft = draftFor(
      key,
      threadId: thread.id,
      replyTo: comment.replyTo,
      revision: comment.revision,
    );
    draft.commentId = comment.id;
    draft.text = comment.body;
    return draft;
  }

  /// Delete a saved draft comment by its id.
  Future<bool> deleteComment(String commentId) async {
    try {
      await api.reviewApply(taskId, {
        'op': 'delete-comment',
        'comment': commentId,
      });
      _drafts.removeWhere((_, draft) => draft.commentId == commentId);
      await _refreshThreadsQuietly();
      notice = const ReviewNotice('Draft deleted');
      notifyListeners();
      return true;
    } catch (failure) {
      notice = ReviewNotice(
        failure is AcpException ? failure.message : '$failure',
        error: true,
      );
      notifyListeners();
      return false;
    }
  }

  /// A thread on the change as a whole, on [file], or at [location].
  ///
  /// A thread on a file and one on the change are two drafts, as a thread on
  /// one file is not the thread on another; a thread at a line shares the
  /// draft of a comment on that line, since it is the same comment.
  ReviewDraft newThreadDraft({
    ReviewLocation? location,
    ChangedFile? file,
    String? revision,
  }) {
    final place =
        location ??
        (file == null
            ? null
            : ReviewLocation(file: file.path, oldFile: file.oldPath));
    final shown = revision ?? changes?.revision;
    final key = place == null || place.file.isEmpty
        ? _newCommentKey(shown, null)
        : place.line == null
        ? _newCommentKey(shown, '${place.file}:file')
        : _newCommentKey(shown, '${place.file}:${place.side}:${place.line}');
    return draftFor(key, location: place, revision: shown);
  }

  /// The draft of a new comment is the comment on those lines of that
  /// revision: the same line of another revision is another comment, and
  /// the words typed for one are not sent against lines of the other.
  String _newCommentKey(String? revision, String? place) =>
      'new:${revision ?? ''}:${place ?? 'whole'}';

  /// The draft of a comment on [start]..[end] of [side] of [file], at the
  /// revision of [diff] -- the diff whose lines the reviewer selected -- or
  /// of [revision].  The draft keeps that revision and that excerpt, so a
  /// version chosen while the composer is open cannot move it to lines its
  /// author never saw.
  ReviewDraft lineDraft({
    required ChangedFile file,
    required String side,
    required int start,
    int? end,
    String? revision,
    ReviewFileDiff? diff,
  }) {
    final shown = revision ?? diff?.revision ?? changes?.revision;
    final path = diff?.path ?? file.path;
    final key = _newCommentKey(
      shown,
      '$path:$side:$start${end == null || end == start ? '' : '-$end'}',
    );
    // The excerpt comes from the lines of that revision only: a cached
    // diff of another revision is not a fallback for it.
    final displayed =
        diff ??
        cachedDiffAt(path, shown) ??
        (shown == changes?.revision ? cachedDiff(path) : null);
    final excerpt = displayed == null
        ? null
        : excerptFor(displayed, side: side, start: start, end: end);
    final place = ReviewLocation(
      file: path,
      oldFile: diff?.oldPath ?? file.oldPath,
      side: side,
      line: start,
      endLine: end == start ? null : end,
      excerpt: excerpt,
    );
    return draftFor(key, location: place, revision: shown);
  }

  /// Close or open [thread].  A close by the user of the last open thread of
  /// a task at work leaves the harness's last-close message, which comes as
  /// an event (`patch-review/last-close`).
  Future<bool> setThreadStatus(ReviewThread thread, bool open) async {
    try {
      final changed = await api.reviewApply(taskId, {
        'op': 'set-status',
        'thread': thread.id,
        'status': open ? 'open' : 'closed',
      });
      if (changed) {
        await _refreshThreadsQuietly();
        notice = ReviewNotice(open ? 'Thread reopened' : 'Thread resolved');
      }
      return changed;
    } catch (failure) {
      notice = ReviewNotice(
        failure is AcpException ? failure.message : '$failure',
        error: true,
      );
      notifyListeners();
      return false;
    }
  }

  /// Say the close of [thread] was looked at, or that it waits again.
  Future<bool> markReviewed(ReviewThread thread, bool reviewed) async {
    final closing = thread.closing;
    if (closing == null) return false;
    try {
      final changed = await api.reviewApply(taskId, {
        'op': reviewed ? 'mark-reviewed' : 'unmark-reviewed',
        'thread': thread.id,
        if (closing.id != null) 'status-id': closing.id,
      });
      if (changed) {
        await _refreshThreadsQuietly();
        notice = ReviewNotice(reviewed ? 'Marked reviewed' : 'To review');
      }
      return changed;
    } catch (failure) {
      notice = ReviewNotice(
        failure is AcpException ? failure.message : '$failure',
        error: true,
      );
      notifyListeners();
      return false;
    }
  }

  // ---- Viewed and approved ----------------------------------------------

  Future<bool> setViewed(ChangedFile file, bool on) async {
    if (readOnlyVersion) {
      notice = const ReviewNotice('Earlier version · no marks', error: true);
      notifyListeners();
      return false;
    }
    if (_viewBusy.contains(file.path)) return false;
    _viewBusy.add(file.path);
    notifyListeners();
    final mine = _generation;
    try {
      await api.reviewSetViewed(
        taskId,
        kind: 'seen',
        files: [file.viewedEntry],
        on: on,
      );
      // The mark is kept by the harness either way; the local page only
      // takes it if it is still the review that asked.
      if (_disposed || mine != _generation) return true;
      viewed = on
          ? viewed.withFile(file, seen: true)
          : viewed.withFile(file, seen: false, approved: false);
      notice = ReviewNotice(
        on ? 'Viewed ${file.name}' : 'Not viewed ${file.name}',
      );
      notifyListeners();
      return true;
    } catch (failure) {
      notice = ReviewNotice(
        failure is AcpException ? failure.message : '$failure',
        error: true,
      );
      notifyListeners();
      return false;
    } finally {
      _viewBusy.remove(file.path);
    }
  }

  Future<bool> setApproved(ChangedFile file, bool on) async {
    if (readOnlyVersion) {
      notice = const ReviewNotice('Earlier version · no marks', error: true);
      notifyListeners();
      return false;
    }
    if (_viewBusy.contains(file.path)) return false;
    _viewBusy.add(file.path);
    notifyListeners();
    final mine = _generation;
    try {
      await api.reviewSetViewed(
        taskId,
        kind: 'approved',
        files: [file.viewedEntry],
        on: on,
      );
      if (_disposed || mine != _generation) return true;
      viewed = on
          ? viewed.withFile(file, seen: true, approved: true)
          : viewed.withFile(file, approved: false);
      notice = ReviewNotice(
        on ? 'Approved ${file.name}' : 'Not approved ${file.name}',
      );
      notifyListeners();
      return true;
    } catch (failure) {
      notice = ReviewNotice(
        failure is AcpException ? failure.message : '$failure',
        error: true,
      );
      notifyListeners();
      return false;
    } finally {
      _viewBusy.remove(file.path);
    }
  }

  bool isViewBusy(ChangedFile file) => _viewBusy.contains(file.path);

  Future<void> _withdrawApproval(ChangedFile file) async {
    if (!viewed.isApproved(file)) return;
    final mine = _generation;
    try {
      await api.reviewSetViewed(
        taskId,
        kind: 'approved',
        files: [file.viewedEntry],
        on: false,
      );
      // A newer review read owns the marks now; this answer is about the
      // tree the reviewer had before it.
      if (_disposed || mine != _generation) return;
      viewed = viewed.withFile(file, approved: false, seen: true);
      notice = const ReviewNotice('Approval off · new comment');
      notifyListeners();
    } catch (_) {
      // The comment is kept; the approval stays until the harness answers.
    }
  }

  // ---- Sending feedback or replies --------------------------------------

  bool get sendingFeedback => sending;

  /// Save every draft with words, then send them.
  ///
  /// A task in review is sent back with [task/reject]: what the reviewer
  /// typed is the feedback, and the harness adds the drafts to it.  A task
  /// at work gets its replies with `patch-review/send-replies`; words typed
  /// in the feedback box become a thread on the change as a whole.  With no
  /// words and no draft there is nothing to send, and nothing goes.
  Future<bool> send() async {
    if (sending) return false;
    if (task == null) {
      notice = const ReviewNotice('Task unavailable', error: true);
      notifyListeners();
      return false;
    }
    final words = feedbackText.trim();
    final keys = [
      for (final entry in _drafts.entries)
        if (!entry.value.isBlank && !entry.value.saving) entry.key,
    ];
    if (isReview) {
      if (words.isEmpty && sendableDraftCount == 0 && keys.isEmpty) {
        notice = const ReviewNotice('Nothing to send', error: true);
        notifyListeners();
        return false;
      }
    } else {
      if (words.isEmpty &&
          sendableDraftCount == 0 &&
          keys.isEmpty &&
          lastClose == null) {
        notice = const ReviewNotice('Nothing to send', error: true);
        notifyListeners();
        return false;
      }
      if (words.isNotEmpty && !_drafts.containsKey('feedback-thread')) {
        // The words of a task at work are a thread of their own: send-replies
        // carries comments, not a message beside them.
        final draft = draftFor('feedback-thread', revision: changes?.revision);
        draft.text = words;
        keys.add('feedback-thread');
      }
    }
    sending = true;
    notice = null;
    notifyListeners();
    try {
      for (final key in keys.toSet()) {
        final saved = await saveDraft(key);
        if (!saved && (_drafts[key]?.commentId == null)) {
          sending = false;
          notifyListeners();
          return false;
        }
      }
      if (isReview) {
        final updated = await api.rejectTask(taskId, words);
        task = updated;
        feedbackText = '';
        _drafts.remove('feedback');
        notice = const ReviewNotice('Feedback sent');
      } else {
        final result = await api.reviewSendReplies(taskId);
        lastClose = null;
        feedbackText = '';
        _drafts.clear();
        notice = ReviewNotice(
          result.sent == 1 ? '1 reply sent' : '${result.sent} replies sent',
        );
        if (result.lastClose) {
          notice = const ReviewNotice('Replies sent · last close');
        }
      }
      selectedVersion = null;
      await load(force: true, quiet: true);
      app?.tasks?.reload(showSpinner: false);
      sending = false;
      notifyListeners();
      return true;
    } catch (failure) {
      sending = false;
      notice = ReviewNotice(
        failure is AcpException ? failure.message : '$failure',
        error: true,
      );
      notifyListeners();
      return false;
    }
  }

  /// Send the replies, including the harness's last-close message.
  Future<bool> sendLastClose() async {
    if (sending) return false;
    sending = true;
    notifyListeners();
    try {
      final result = await api.reviewSendReplies(taskId);
      lastClose = null;
      notice = ReviewNotice(
        result.sent == 0
            ? 'Last close · sent'
            : result.sent == 1
            ? '1 reply sent'
            : '${result.sent} replies sent',
      );
      selectedVersion = null;
      await load(force: true, quiet: true);
      sending = false;
      notifyListeners();
      return true;
    } catch (failure) {
      sending = false;
      notice = ReviewNotice(
        failure is AcpException ? failure.message : '$failure',
        error: true,
      );
      notifyListeners();
      return false;
    }
  }

  Future<bool> discardLastClose() async {
    try {
      await api.reviewDiscardLastClose(taskId);
      lastClose = null;
      notice = const ReviewNotice('Last close dropped');
      notifyListeners();
      return true;
    } catch (failure) {
      notice = ReviewNotice(
        failure is AcpException ? failure.message : '$failure',
        error: true,
      );
      notifyListeners();
      return false;
    }
  }

  void clearNotice() {
    notice = null;
    notifyListeners();
  }
}

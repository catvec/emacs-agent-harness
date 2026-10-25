import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/quick_search.dart';
import '../../state/app_controller.dart';
import '../../state/quick_search_catalogue.dart';
import '../../state/quick_search_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../adaptive/platform_style.dart';
import '../format.dart';
import '../theme/harness_theme.dart';
import '../widgets/markdown_view.dart';

/// The quick search: one box to say what you want in words ("how do I attach
/// an image?", "where did I debug the merge queue?", "the task about the
/// docs") and reach an action, a session or a task, or read the answer.
///
/// It is the harness's own search, the one in its Emacs (see
/// [QuickSearchController]): the line goes to the harness, a cheap model there
/// reads the app's actions, the sessions and the tasks and answers, and this
/// draws what it said.  Choosing something closes the page and hands what
/// was chosen to the home shell as the page's result, a [QuickSearchChoice],
/// which does it with the screens in hand.
class QuickSearchScreen extends StatefulWidget {
  const QuickSearchScreen({
    super.key,
    required this.app,
    required this.place,
    this.initialQuery,
  });

  final AppController app;

  /// The screen it was opened from, which sets what it favours.
  final QuickSearchPlace place;

  /// A line to search at once, as it opens.
  final String? initialQuery;

  @override
  State<QuickSearchScreen> createState() => _QuickSearchScreenState();
}

class _QuickSearchScreenState extends State<QuickSearchScreen> {
  late final QuickSearchController _search = QuickSearchController(
    app: widget.app,
    place: widget.place,
  );
  final _field = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // The model's process starts as the box opens, so that it is up by the
    // time the line is typed.
    _search.warm();
    final first = widget.initialQuery?.trim();
    if (first != null && first.isNotEmpty) {
      _field.text = first;
      _search.search(first);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _canAsk =>
      _search.availability == QuickSearchAvailability.ready &&
      _field.text.trim().isNotEmpty;

  void _submit([String? line]) {
    final text = (line ?? _field.text).trim();
    if (text.isEmpty) return;
    if (_search.availability != QuickSearchAvailability.ready) return;
    _field.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    // The keyboard gives way to what was found; the line stays in the box,
    // to be refined.
    _focus.unfocus();
    _search.search(text);
  }

  /// Whether something was chosen already: the page is on its way out, and a
  /// second tap in the same moment must not close what is under it.
  bool _chosen = false;

  void _choose(QuickSearchChoice choice) {
    if (_chosen) return;
    _chosen = true;
    Navigator.of(context).pop<QuickSearchChoice>(choice);
  }

  Future<void> _pickProject() async {
    final projects = widget.app.projects;
    final picked = await showHarnessMenu<String>(
      context: context,
      title: 'Search in a project',
      items: [
        for (final project in projects)
          HarnessMenuItem(
            value: project,
            label: projectName(project),
            icon: project == _search.project ? Icons.check_rounded : null,
          ),
      ],
    );
    if (picked != null && mounted) _search.setProject(picked);
  }

  @override
  Widget build(BuildContext context) {
    final cupertino = HarnessStyle.isCupertino(context);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The box follows what is typed in it, and nothing under it does:
        // a key does not draw the page again.
        AnimatedBuilder(
          animation: Listenable.merge([_search, widget.app, _field]),
          builder: (context, _) => _Header(
            field: _field,
            focus: _focus,
            canAsk: _canAsk,
            onSubmit: _submit,
            onClose: () => Navigator.of(context).maybePop(),
            onClear: () {
              _field.clear();
              _focus.requestFocus();
            },
          ),
        ),
        Expanded(
          child: AnimatedBuilder(
            animation: Listenable.merge([_search, widget.app]),
            builder: (context, _) {
              final availability = _search.availability;
              return Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Place(
                        controller: _search,
                        app: widget.app,
                        onPickProject: _pickProject,
                      ),
                      if (availability != QuickSearchAvailability.ready)
                        _Unavailable(availability: availability),
                      Expanded(
                        child: _Body(
                          controller: _search,
                          app: widget.app,
                          onSubmit: _submit,
                          onChoose: _choose,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
    if (cupertino) {
      return CupertinoPageScaffold(
        child: Material(
          type: MaterialType.transparency,
          child: SafeArea(child: content),
        ),
      );
    }
    return Scaffold(body: SafeArea(child: content));
  }
}

/// The top of the page: the way out, and the box to say it in.
class _Header extends StatelessWidget {
  const _Header({
    required this.field,
    required this.focus,
    required this.canAsk,
    required this.onSubmit,
    required this.onClose,
    required this.onClear,
  });

  final TextEditingController field;
  final FocusNode focus;
  final bool canAsk;
  final void Function([String? line]) onSubmit;
  final VoidCallback onClose;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final empty = field.text.isEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HarnessSpace.xs,
        HarnessSpace.sm,
        HarnessSpace.sm,
        HarnessSpace.xs,
      ),
      child: Row(
        children: [
          HarnessIconButton(
            key: const Key('quick-search-close'),
            icon: adaptiveIcon(
              context,
              Icons.arrow_back_rounded,
              CupertinoIcons.chevron_back,
            ),
            label: 'Close search',
            onPressed: onClose,
          ),
          Expanded(
            // A keyboard that has keys, as a computer's does, searches with
            // Return (Shift-Return breaks the line) and leaves with Escape;
            // a phone's sends the search key instead, as the field says.
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: (node, event) {
                if (event is! KeyDownEvent) return KeyEventResult.ignored;
                final key = event.logicalKey;
                if (key == LogicalKeyboardKey.escape) {
                  onClose();
                  return KeyEventResult.handled;
                }
                if ((key == LogicalKeyboardKey.enter ||
                        key == LogicalKeyboardKey.numpadEnter) &&
                    !HardwareKeyboard.instance.isShiftPressed) {
                  if (canAsk) onSubmit();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: HarnessTextField(
                key: const Key('quick-search-field'),
                controller: field,
                focusNode: focus,
                hint: 'Say what you want…',
                autofocus: true,
                // A question is a sentence: it wraps, from one line to three,
                // and the keyboard's key still searches rather than breaking
                // the line.
                minLines: 1,
                maxLines: 3,
                textInputAction: TextInputAction.search,
                keyboardType: TextInputType.text,
                onSubmitted: (value) => onSubmit(value),
                prefix: Icon(
                  adaptiveIcon(
                    context,
                    Icons.auto_awesome_rounded,
                    CupertinoIcons.sparkles,
                  ),
                  size: 19,
                  color: theme.colorScheme.primary,
                ),
                suffix: empty
                    ? null
                    : HarnessIconButton(
                        key: const Key('quick-search-clear'),
                        icon: adaptiveIcon(
                          context,
                          Icons.close_rounded,
                          CupertinoIcons.xmark_circle_fill,
                        ),
                        label: 'Clear',
                        size: 18,
                        onPressed: onClear,
                      ),
              ),
            ),
          ),
          const SizedBox(width: HarnessSpace.xs),
          HarnessIconButton(
            key: const Key('quick-search-submit'),
            icon: adaptiveIcon(
              context,
              Icons.arrow_upward_rounded,
              CupertinoIcons.arrow_up_circle_fill,
            ),
            label: 'Search',
            color: canAsk ? theme.colorScheme.primary : null,
            onPressed: canAsk ? () => onSubmit() : null,
          ),
        ],
      ),
    );
  }
}

/// Where the search was opened and what it is about: the project (a choice,
/// when the harness has more than one), and the line the harness's Emacs
/// opens its popout with, "From ... · favours ...".
class _Place extends StatelessWidget {
  const _Place({
    required this.controller,
    required this.app,
    required this.onPickProject,
  });

  final QuickSearchController controller;
  final AppController app;
  final VoidCallback onPickProject;

  String get _from {
    final place = controller.place;
    final title = place.sessionTitle;
    return switch (place.origin) {
      SearchOrigin.chat =>
        title == null
            ? 'From a conversation'
            : 'From the conversation “$title”',
      SearchOrigin.tasks => 'From the task board',
      SearchOrigin.sessions => 'From the list of sessions',
      SearchOrigin.usage => 'From usage',
      SearchOrigin.server => 'From the server page',
      SearchOrigin.settings => 'From settings',
    };
  }

  @override
  Widget build(BuildContext context) {
    final choosable = app.projects.length > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HarnessScopeBar(
          key: const Key('quick-search-project'),
          label: projectName(controller.project),
          onTap: choosable ? onPickProject : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HarnessSpace.gutter,
            0,
            HarnessSpace.gutter,
            HarnessSpace.xs,
          ),
          child: Text(
            '$_from · favours ${controller.bias.favours}',
            key: const Key('quick-search-from'),
            style: HarnessText.caption(context),
          ),
        ),
      ],
    );
  }
}

/// Why a search cannot be asked now, where the answer would be.
class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.availability});

  final QuickSearchAvailability availability;

  @override
  Widget build(BuildContext context) {
    return switch (availability) {
      QuickSearchAvailability.reconnecting => const HarnessNotice(
        key: Key('quick-search-reconnecting'),
        leading: HarnessActivity(radius: 8),
        message: 'Reconnecting to the harness…',
        detail:
            'A search needs the harness. It works again as soon as the app '
            'is back in.',
        detailLines: 3,
      ),
      QuickSearchAvailability.unsupported => const HarnessNotice(
        key: Key('quick-search-unsupported'),
        icon: Icons.search_off_rounded,
        message: 'This harness cannot search',
        detail:
            'The quick search is the harness’s own, and this one does not '
            'offer it: its search module (tasks-search) is off, or the '
            'harness is older. The rest of the app works as ever.',
        detailLines: 4,
      ),
      QuickSearchAvailability.disconnected => const HarnessNotice(
        key: Key('quick-search-disconnected'),
        icon: Icons.link_off_rounded,
        message: 'Not connected to a harness',
        detail: 'Connect to one to search it.',
      ),
      QuickSearchAvailability.ready => const SizedBox.shrink(),
    };
  }
}

/// What is under the box: the hint, the wait, what went wrong, or what was
/// found.
class _Body extends StatelessWidget {
  const _Body({
    required this.controller,
    required this.app,
    required this.onSubmit,
    required this.onChoose,
  });

  final QuickSearchController controller;
  final AppController app;
  final void Function([String? line]) onSubmit;
  final ValueChanged<QuickSearchChoice> onChoose;

  @override
  Widget build(BuildContext context) {
    final children = switch (controller.status) {
      // Lines to try only where one can be tried: the notice above says why
      // not, and an example that does nothing when tapped is no help.
      QuickSearchStatus.idle => [
        if (controller.availability == QuickSearchAvailability.ready)
          _Hint(controller: controller, onSubmit: onSubmit),
      ],
      QuickSearchStatus.searching => [_Waiting(controller: controller)],
      QuickSearchStatus.failed => [
        HarnessErrorBanner(
          key: const Key('quick-search-error'),
          message: 'The search failed: ${controller.error}',
          actionLabel: 'Retry',
          onAction: controller.retry,
          margin: EdgeInsets.zero,
        ),
        _Footer(controller: controller),
      ],
      QuickSearchStatus.done => [
        _Found(controller: controller, app: app, onChoose: onChoose),
        _Footer(controller: controller),
      ],
    };
    return ListView(
      key: const Key('quick-search-body'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(
        HarnessSpace.gutter,
        HarnessSpace.sm,
        HarnessSpace.gutter,
        HarnessSpace.xl,
      ),
      children: children,
    );
  }
}

/// What the empty search says: lines to try, one for each kind of thing it
/// finds, and the lines searched before.
class _Hint extends StatelessWidget {
  const _Hint({required this.controller, required this.onSubmit});

  final QuickSearchController controller;
  final void Function([String? line]) onSubmit;

  static const examples = <(SearchKind, String)>[
    (SearchKind.commands, 'how do I attach an image to a task?'),
    (SearchKind.sessions, 'where did I debug the merge queue?'),
    (SearchKind.tasks, 'the task about the docs'),
  ];

  static IconData iconOf(SearchKind kind) => switch (kind) {
    SearchKind.commands => Icons.bolt_rounded,
    SearchKind.sessions => Icons.forum_outlined,
    SearchKind.tasks => Icons.checklist_rtl_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final bias = controller.bias;
    final ordered = [
      for (final kind in bias.order)
        examples.firstWhere((example) => example.$1 == kind),
    ];
    final history = controller.history;
    return Column(
      key: const Key('quick-search-hint'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: HarnessSpace.sm),
        Text(
          'Say what you want, in words, for instance:',
          style: HarnessText.subtitle(context),
        ),
        const SizedBox(height: HarnessSpace.sm),
        HarnessCardList(
          children: [
            for (final example in ordered)
              _Line(
                icon: iconOf(example.$1),
                text: example.$2,
                onTap: () => onSubmit(example.$2),
              ),
          ],
        ),
        if (history.isNotEmpty) ...[
          const HarnessSectionHeader(label: 'Recent'),
          HarnessCardList(
            children: [
              for (final line in history.take(6))
                _Line(
                  icon: Icons.history_rounded,
                  text: line,
                  onTap: () => onSubmit(line),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// A line that can be searched with a tap.
class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.text, required this.onTap});

  final IconData icon;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return HarnessTap(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: HarnessSpace.lg,
          vertical: 13,
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: HarnessText.body(context))),
          ],
        ),
      ),
    );
  }
}

/// The wait for the answer: the line, the model it is asked of, and the way
/// to stop waiting.
class _Waiting extends StatelessWidget {
  const _Waiting({required this.controller});

  final QuickSearchController controller;

  @override
  Widget build(BuildContext context) {
    final model = controller.model;
    return Padding(
      key: const Key('quick-search-waiting'),
      padding: const EdgeInsets.symmetric(vertical: HarnessSpace.md),
      child: Row(
        children: [
          const HarnessActivity(radius: 9),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '“${controller.query}”',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: HarnessText.rowTitle(context),
                ),
                const SizedBox(height: 2),
                Text(
                  'asking ${model == null ? 'the model' : modelName(model)}…',
                  style: HarnessText.caption(context),
                ),
              ],
            ),
          ),
          HarnessTextButton(
            key: const Key('quick-search-stop'),
            label: 'Stop',
            onPressed: controller.cancel,
          ),
        ],
      ),
    );
  }
}

/// The buttons that ask the line again, favouring something else
/// ([Search sessions] and [Search commands] in the harness's Emacs).
class _Footer extends StatelessWidget {
  const _Footer({required this.controller});

  final QuickSearchController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.query.isEmpty) return const SizedBox.shrink();
    return Padding(
      key: const Key('quick-search-footer'),
      padding: const EdgeInsets.only(top: HarnessSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Search again, favouring', style: HarnessText.caption(context)),
          const SizedBox(height: HarnessSpace.sm),
          Row(
            children: [
              Expanded(
                child: HarnessSecondaryButton(
                  key: const Key('quick-search-reask-sessions'),
                  label: 'Sessions',
                  icon: Icons.forum_outlined,
                  onPressed: () => controller.reask(SearchBias.sessions),
                ),
              ),
              const SizedBox(width: HarnessSpace.sm),
              Expanded(
                child: HarnessSecondaryButton(
                  key: const Key('quick-search-reask-actions'),
                  label: 'Actions',
                  icon: Icons.bolt_rounded,
                  onPressed: () => controller.reask(SearchBias.commands),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// What a search that is done found: what it says in words, then each kind of
/// thing, as the place favours them, and what it proposes to do.
class _Found extends StatelessWidget {
  const _Found({
    required this.controller,
    required this.app,
    required this.onChoose,
  });

  final QuickSearchController controller;
  final AppController app;
  final ValueChanged<QuickSearchChoice> onChoose;

  String _counts(QuickSearchPlan plan) {
    final parts = <String>[];
    for (final kind in controller.bias.order) {
      final n = plan.countOf(kind);
      if (n == 0) continue;
      final word = switch (kind) {
        SearchKind.commands => n == 1 ? 'action' : 'actions',
        SearchKind.sessions => n == 1 ? 'session' : 'sessions',
        SearchKind.tasks => n == 1 ? 'task' : 'tasks',
      };
      parts.add('$n $word');
    }
    return parts.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final plan = controller.plan;
    if (plan == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final counts = _counts(plan);
    return Column(
      key: const Key('quick-search-found'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // What was asked, how much it found, what the model looked at beyond
        // what it was given.
        HarnessMetaLine(
          key: const Key('quick-search-head'),
          maxLines: 2,
          parts: ['“${controller.query}”', counts, plan.looked],
        ),
        if (plan.answer != null) ...[
          const SizedBox(height: HarnessSpace.md),
          _Answer(text: plan.answer!, model: plan.model ?? controller.model),
        ],
        // A search that found nothing says so below, and no more than that.
        if (plan.note != null && !plan.isEmpty) ...[
          const SizedBox(height: HarnessSpace.md),
          Row(
            key: const Key('quick-search-note'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                plan.widened
                    ? Icons.travel_explore_rounded
                    : Icons.info_outline_rounded,
                size: 16,
                color: plan.widened
                    ? HarnessColors.amber
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(plan.note!, style: HarnessText.subtitle(context)),
              ),
            ],
          ),
        ],
        if (plan.isEmpty)
          _Nothing(query: controller.query)
        else
          for (final kind in controller.bias.order)
            if (plan.countOf(kind) > 0) ...[
              HarnessSectionHeader(
                label: kind.heading,
                padding: const EdgeInsets.fromLTRB(
                  HarnessSpace.xs,
                  HarnessSpace.xl,
                  HarnessSpace.xs,
                  HarnessSpace.sm,
                ),
              ),
              HarnessCardList(
                key: Key('quick-search-${kind.name}'),
                children: switch (kind) {
                  SearchKind.commands => [
                    for (final found in plan.commands)
                      _CommandRow(
                        found: found,
                        command: controller.commandFor(found),
                        onChoose: onChoose,
                      ),
                  ],
                  SearchKind.sessions => [
                    for (final session in plan.sessions)
                      _SessionRow(session: session, onChoose: onChoose),
                  ],
                  SearchKind.tasks => [
                    for (final task in plan.tasks)
                      _TaskRow(task: task, app: app, onChoose: onChoose),
                  ],
                },
              ),
            ],
        _Proposal(controller: controller),
      ],
    );
  }
}

/// The answer in words: Markdown, whole.
class _Answer extends StatelessWidget {
  const _Answer({required this.text, this.model});

  final String text;
  final String? model;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return HarnessCard(
      key: const Key('quick-search-answer'),
      color: theme.colorScheme.primary.withValues(alpha: 0.06),
      borderColor: theme.colorScheme.primary.withValues(alpha: 0.22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.auto_awesome_rounded,
                size: 15,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  model == null ? 'ANSWER' : 'ANSWER · ${modelName(model)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HarnessText.label(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: HarnessSpace.sm),
          HarnessMarkdown(text: text, tight: true),
        ],
      ),
    );
  }
}

/// What the search says when it found nothing and had nothing to say.
class _Nothing extends StatelessWidget {
  const _Nothing({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: const Key('quick-search-nothing'),
      padding: const EdgeInsets.symmetric(vertical: HarnessSpace.xl),
      child: Column(
        children: [
          Icon(
            Icons.search_off_rounded,
            size: 34,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: HarnessSpace.md),
          Text('Nothing found', style: HarnessText.rowTitle(context)),
          const SizedBox(height: 4),
          Text(
            'No action, session or task for “$query”, even searching wider. '
            'Try other words.',
            textAlign: TextAlign.center,
            style: HarnessText.subtitle(context),
          ),
        ],
      ),
    );
  }
}

/// A result: what it is, what it says of itself, and what a tap does.  The
/// whole row is the tap.
class _ResultRow extends StatelessWidget {
  const _ResultRow({
    super.key,
    required this.leading,
    required this.title,
    required this.verb,
    required this.onTap,
    this.subtitle,
    this.detail,
    this.extra,
  });

  final Widget leading;
  final String title;
  final String? subtitle;

  /// More under the subtitle: a passage, the taps that reach an action.
  final Widget? detail;

  /// What a tap does, in a word.
  final String verb;
  final VoidCallback onTap;

  /// A second thing to do with the result, under it.
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return HarnessTap(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          HarnessSpace.lg,
          HarnessSpace.md,
          HarnessSpace.md,
          HarnessSpace.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: SizedBox(width: 30, child: Center(child: leading)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: HarnessText.rowTitle(context),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: HarnessText.subtitle(context),
                        ),
                      ],
                      if (detail != null) ...[
                        const SizedBox(height: 6),
                        detail!,
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(
                    verb,
                    style: HarnessText.meta(context).copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            if (extra != null)
              Padding(
                padding: const EdgeInsets.only(left: 40, top: 2),
                child: Align(alignment: Alignment.centerLeft, child: extra),
              ),
          ],
        ),
      ),
    );
  }
}

/// An action of the app the search named.
class _CommandRow extends StatelessWidget {
  const _CommandRow({
    required this.found,
    required this.command,
    required this.onChoose,
  });

  final FoundCommand found;

  /// The command as the app offered it, which is what a tap does; null for a
  /// name the app did not send (the harness only names those it was given).
  final QuickCommand? command;
  final ValueChanged<QuickSearchChoice> onChoose;

  static IconData iconOf(QuickCommandKind? kind) => switch (kind) {
    QuickCommandKind.action => Icons.bolt_rounded,
    QuickCommandKind.setting => Icons.tune_rounded,
    QuickCommandKind.project => Icons.folder_outlined,
    _ => Icons.north_east_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keys = found.keys;
    final run = command?.run;
    return _ResultRow(
      key: Key('quick-search-command-${found.command}'),
      leading: Icon(
        iconOf(command?.kind),
        size: 20,
        color: theme.colorScheme.primary,
      ),
      title: found.label ?? found.command,
      subtitle: found.doc,
      detail: keys == null
          ? null
          : Row(
              children: [
                Icon(
                  Icons.touch_app_outlined,
                  size: 13,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    keys,
                    style: HarnessText.meta(context).copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                    ),
                  ),
                ),
              ],
            ),
      verb: (command?.kind ?? QuickCommandKind.screen).verb,
      onTap: run == null ? () {} : () => onChoose(run),
    );
  }
}

/// A second thing to do with a result, under it: an icon and a few words that
/// wrap rather than run over, in the color of what can be tapped.
class _RowAction extends StatelessWidget {
  const _RowAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Semantics(
      button: true,
      label: label,
      child: HarnessTap(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 17, color: color),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    style: HarnessText.subtitle(context)
                        .copyWith(color: color, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A session the search found, by its name or by what was said in it.
class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.session, required this.onChoose});

  final FoundSession session;
  final ValueChanged<QuickSearchChoice> onChoose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = HarnessColors.status(session.status, theme.brightness);
    final what = session.task != null
        ? 'Task ${session.task}'
        : kindLabel(session.kind);
    final snippet = session.snippet;
    return _ResultRow(
      key: Key('quick-search-session-${session.id}'),
      leading: HarnessDot(color: color, size: 10),
      title: session.title,
      subtitle: [
        if (session.project != null) session.project!,
        what,
        if (session.updated != null) relativeTime(session.updated),
      ].join(HarnessMetaLine.separator),
      detail: snippet == null
          ? null
          : _Passage(text: snippet, ranges: session.ranges),
      verb: 'Open',
      onTap: () => onChoose((host) async => host.openSession(session.id)),
    );
  }
}

/// The passage of a session the words were found in, with the words marked.
class _Passage extends StatelessWidget {
  const _Passage({required this.text, required this.ranges});

  final String text;
  final List<(int, int)> ranges;

  @override
  Widget build(BuildContext context) {
    final base = HarnessText.caption(context);
    final marked = base.copyWith(
      color: Theme.of(context).colorScheme.onSurface,
      fontWeight: FontWeight.w700,
    );
    final spans = <TextSpan>[];
    var at = 0;
    final sorted = [...ranges]..sort((a, b) => a.$1.compareTo(b.$1));
    for (final (start, end) in sorted) {
      final from = start.clamp(at, text.length);
      final to = end.clamp(from, text.length);
      if (to <= from) continue;
      if (from > at) spans.add(TextSpan(text: text.substring(at, from)));
      spans.add(TextSpan(text: text.substring(from, to), style: marked));
      at = to;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// A task the search found.  Its conversation is where it is worked on, so a
/// tap opens that; the board shows it among the rest.
class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.task,
    required this.app,
    required this.onChoose,
  });

  final FoundTask task;
  final AppController app;
  final ValueChanged<QuickSearchChoice> onChoose;

  /// The color of the column a task's status line names.
  static Color colorOf(String? status, Brightness brightness) {
    final column = switch (status?.split(':').first.trim()) {
      'needs input' => 'needs-input',
      'in progress' => 'active',
      final other? => other,
      null => '',
    };
    return HarnessColors.column(column, brightness);
  }

  /// Show the task on the board: the board is narrowed to the project it is
  /// of when it is narrowed to another, as a new task of another project's
  /// is shown.
  QuickSearchChoice get _board => (host) async {
    final controller = app.tasks;
    if (controller != null) {
      final known = controller.tasks.where((item) => item.id == task.id);
      if (known.isNotEmpty && controller.project != null) {
        if (app.projectOfTask(known.first) != controller.project) {
          await controller.load();
        }
      }
    }
    host.openTab('tasks');
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = task.sessionId;
    return _ResultRow(
      key: Key('quick-search-task-${task.id}'),
      leading: HarnessDot(
        color: colorOf(task.status, theme.brightness),
        size: 10,
      ),
      title: task.title ?? '(untitled)',
      subtitle: task.status,
      detail: Text(
        task.id,
        style: HarnessText.mono(context)
            .copyWith(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
      ),
      verb: session == null ? 'Board' : 'Open',
      onTap: session == null
          ? () => onChoose(_board)
          : () => onChoose((host) async => host.openSession(session)),
      extra: session == null
          ? null
          : _RowAction(
              key: Key('quick-search-board-${task.id}'),
              icon: Icons.view_kanban_outlined,
              label: 'Show on the board',
              onTap: () => onChoose(_board),
            ),
    );
  }
}

/// What the search proposes to do to tasks ("stop the docs task"), waiting for
/// a yes; then how it went.  Nothing is done to a task unasked.
class _Proposal extends StatelessWidget {
  const _Proposal({required this.controller});

  final QuickSearchController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final proposed = controller.proposed;
    final running = controller.running;
    final results = controller.results;
    if (running.isNotEmpty) {
      return Padding(
        key: const Key('quick-search-running'),
        padding: const EdgeInsets.only(top: HarnessSpace.xl),
        child: Row(
          children: [
            const HarnessActivity(radius: 8),
            const SizedBox(width: 12),
            Text('Doing it…', style: HarnessText.subtitle(context)),
          ],
        ),
      );
    }
    if (results.isNotEmpty) {
      final ok = results.every((result) => result.ok);
      return Padding(
        key: const Key('quick-search-results'),
        padding: const EdgeInsets.only(top: HarnessSpace.xl),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              ok ? Icons.check_circle_outline_rounded : Icons.error_outline,
              size: 19,
              color: ok ? HarnessColors.moss : theme.colorScheme.error,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                results.map((result) => result.sentence).join('; '),
                style: HarnessText.body(context),
              ),
            ),
          ],
        ),
      );
    }
    if (proposed.isEmpty) return const SizedBox.shrink();
    final sentence = proposed.map((action) => action.sentence).join(', ');
    return Padding(
      padding: const EdgeInsets.only(top: HarnessSpace.xl),
      child: HarnessCard(
        key: const Key('quick-search-proposal'),
        color: HarnessColors.amber.withValues(alpha: 0.10),
        borderColor: HarnessColors.amber.withValues(alpha: 0.35),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.front_hand_outlined,
                  size: 19,
                  color: HarnessColors.amber,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${sentence[0].toUpperCase()}${sentence.substring(1)}?',
                    style: HarnessText.rowTitle(context),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 29),
              child: Text(
                'The search proposes it; nothing is done until you say so.',
                style: HarnessText.caption(context),
              ),
            ),
            const SizedBox(height: HarnessSpace.md),
            Row(
              children: [
                Expanded(
                  child: HarnessPrimaryButton(
                    key: const Key('quick-search-do-it'),
                    label: 'Do it',
                    onPressed: controller.canApply ? controller.doIt : null,
                  ),
                ),
                const SizedBox(width: HarnessSpace.sm),
                Expanded(
                  child: HarnessSecondaryButton(
                    key: const Key('quick-search-skip'),
                    label: 'Skip',
                    onPressed: controller.skip,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

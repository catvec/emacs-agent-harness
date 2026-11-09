import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../acp/acp_message.dart';
import '../../models/demo_session.dart';
import '../../models/tool_display.dart';
import '../../voice/voice_controller.dart';
import '../../vnc/rfb.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../app_scope.dart';
import '../navigation.dart';
import '../theme/harness_theme.dart';
import '../widgets/tool_body.dart';
import 'demo_screen.dart';
import 'session_screen.dart';

/// What a demo run's state reads on the report page: the words for each
/// state the harness names.  A state this page does not know reads as a
/// failure, which is the one that leaves nothing running.
String demoStateLabel(String state) => switch (state) {
  DemoState.running => 'Demo running',
  DemoState.starting => 'Starting demo',
  DemoState.stopped || DemoState.lost => 'Demo stopped',
  DemoState.missing => 'Demo not found',
  DemoState.notReady => 'Not ready',
  DemoState.denied => 'Access denied',
  _ => 'Demo failure',
};

/// A task's report on a page of its own, read to its end: the design it was
/// written against, the problem, the summary as it was written, how to see
/// it, and every piece of evidence, the calls it quotes opened to what they
/// said.
///
/// It is the one page a report is read on, whichever way it was come to: the
/// "Open full view" of the `hand_in` call in a session (`ToolDetailScreen`
/// is this page for that call) and the "View report" of a task on the task
/// board both open it, with the same [HandInReport], so a report looks the
/// same from both.  Nothing on it is about the way it was come to (the call
/// that carried it, the board it was listed on), only about the report.
///
/// A report that says how to present the work opens a walkthrough: a side
/// conversation of the task's session, in voice mode, whose first question
/// is the walkthrough itself.  The question is sent as the conversation is
/// opened; voice mode opens over the answer as it streams, so that the
/// answer is spoken there.
///
/// The screenshots among the evidence are drawn on it, under their lines.
/// They are files on the harness's machine, which only the harness can
/// read, and it gives them to the session whose work they show: so both ways
/// to the page hand it [sessionId], the session of the task.  Without one,
/// or with a harness that does not give pictures, they are named.
class HandInReportScreen extends StatefulWidget {
  const HandInReportScreen({
    super.key,
    required this.report,
    this.sessionId,
    this.startVoiceWalkthrough = true,
    this.voiceBackendFactory,
    this.vncTransportFactory,
  });

  final HandInReport report;

  /// The session that handed the work in, whose harness gives the pictures
  /// of the evidence.  Null when it is not known.
  final String? sessionId;

  /// Whether the walkthrough opens in voice mode.  The app leaves it true; a
  /// test takes the microphone out of the way.
  final bool startVoiceWalkthrough;

  /// What the walkthrough's voice screen opens its microphone and provider
  /// with.  The app leaves it null and builds the real ones; a test hands it
  /// a scripted backend.
  final VoiceBackendFactory? voiceBackendFactory;

  /// Where a demo screen's RFB bytes come from.  The app leaves it null and
  /// opens the endpoint's WebSocket; a test hands it a transport of its own.
  final RfbTransport Function(String url)? vncTransportFactory;

  /// Open the page of [report] over the one [context] is on.
  static Future<void> show(
    BuildContext context,
    HandInReport report, {
    String? sessionId,
  }) {
    return Navigator.of(context).push<void>(
      harnessRoute<void>(
        context,
        (_) => HandInReportScreen(report: report, sessionId: sessionId),
      ),
    );
  }

  /// "Oct 23, 2:15 PM": when the report was written, with the year when it
  /// was not this year.
  static String whenLabel(DateTime when, {DateTime? now}) {
    final sameYear = (now ?? DateTime.now()).year == when.year;
    final day = sameYear ? DateFormat.MMMd() : DateFormat.yMMMd();
    return day.add_jm().format(when);
  }

  @override
  State<HandInReportScreen> createState() => _HandInReportScreenState();
}

class _HandInReportScreenState extends State<HandInReportScreen> {
  /// A walkthrough is being started: its session is not made yet, and a
  /// second tap must not make another.
  bool _starting = false;

  /// A demo is being started: `demo/start` is on its way, and a second tap
  /// must not start it twice.
  bool _startingDemo = false;

  /// What the last start said of a demo that did not run, in the words of
  /// the page; null when there is nothing to say.  A start that runs opens
  /// the demo screen and leaves none.
  String? _demoState;

  HandInReport get report => widget.report;

  /// The demos of the report, which can be started here.
  List<EvidenceItem> get _demos => [
    for (final item in report.evidence)
      if (item.isDemo) item,
  ];

  /// Whether this page may offer to start one of the report's demos: the
  /// harness has `demo/start` and the report is of a session the harness can
  /// start it for.
  bool _canStartDemo(BuildContext context) =>
      _demos.isNotEmpty &&
      widget.sessionId != null &&
      HarnessScope.maybeAppOf(context)?.api?.can('demo/start') == true;

  Future<void> _startDemo(EvidenceItem demo) async {
    final session = widget.sessionId;
    final api = HarnessScope.maybeAppOf(context)?.api;
    if (_startingDemo || session == null || api == null) return;
    setState(() {
      _startingDemo = true;
      _demoState = 'Starting demo';
    });
    try {
      final started = await api.startDemo(
        session: session,
        demo: demo.id ?? 'demo-1',
      );
      if (!mounted) return;
      setState(() {
        _startingDemo = false;
        _demoState = null;
      });
      if (started.isRunning) {
        await DemoScreen.show(
          context,
          started,
          voiceBackendFactory: widget.voiceBackendFactory,
          vncTransportFactory: widget.vncTransportFactory,
        );
        return;
      }
      final label = demoStateLabel(started.state);
      if (!mounted) return;
      setState(() => _demoState = label);
      if (started.state == DemoState.error ||
          started.state == DemoState.denied) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(label)));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _startingDemo = false;
        _demoState = 'Demo failure';
      });
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('Demo failure')));
    }
  }

  /// The report has several demos: the one to start is chosen by its title.
  Future<void> _chooseDemo() async {
    final demos = _demos;
    if (demos.isEmpty) return;
    final chosen = await showHarnessMenu<String>(
      context: context,
      title: 'Demo',
      items: [
        for (final demo in demos)
          HarnessMenuItem(
            value: demo.id!,
            label: demo.label,
            icon: Icons.slideshow_rounded,
          ),
      ],
    );
    if (chosen == null || !mounted) return;
    await _startDemo(demos.firstWhere((demo) => demo.id == chosen));
  }

  Future<void> _startWalkthrough() async {
    final walkthrough = report.walkthrough;
    final session = widget.sessionId;
    if (_starting ||
        walkthrough == null ||
        walkthrough.isEmpty ||
        session == null) {
      return;
    }
    final app = HarnessScope.appOf(context);
    final client = app.client;
    if (client == null) {
      _failed(StateError('not connected'));
      return;
    }
    setState(() => _starting = true);
    try {
      // A BTW of the task's session: a conversation of its own, on the model
      // the session runs, named for the report it is about.
      final created = asMap(
        await client.request('_harness/session/btw', {
          'id': session,
          'name': 'review: ${truncateLine(report.problem, max: 40)}',
          if (app.summaryFor(session)?.model case final model?) 'model': model,
        }),
      );
      final btw = asString(created['id']);
      if (btw == null || btw.isEmpty) {
        throw StateError('no session in the answer');
      }
      // The turn takes as long as it takes; the page goes on to the
      // conversation it started, and voice mode opens there over the answer
      // as it streams, so that the answer is spoken.
      unawaited(
        client
            .request('session/prompt', {
              'sessionId': btw,
              'prompt': [
                {'type': 'text', 'text': walkthrough},
              ],
            })
            .catchError((Object error) {
              if (mounted) _failed(error);
              return null;
            }),
      );
      if (!mounted) return;
      setState(() => _starting = false);
      await Navigator.of(context).push<void>(
        harnessRoute<void>(
          context,
          (context) => SessionScreen(
            sessionId: btw,
            startVoice: widget.startVoiceWalkthrough,
            voiceBackendFactory: widget.voiceBackendFactory,
          ),
        ),
      );
    } catch (error) {
      _failed(error);
    }
  }

  /// The walkthrough could not be started: the page says so, and the button
  /// can be tried again.
  void _failed(Object error) {
    if (!mounted) return;
    setState(() => _starting = false);
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(const SnackBar(content: Text('Walkthrough failure')));
  }

  @override
  Widget build(BuildContext context) {
    final when = widget.report.at;
    final walkthrough = widget.report.walkthrough;
    return HarnessPage(
      title: 'Hand-in report',
      maxContentWidth: HarnessSpace.pageWidth,
      body: ListView(
        key: const ValueKey('hand-in-report'),
        padding: const EdgeInsets.fromLTRB(
          HarnessSpace.gutter,
          HarnessSpace.sm,
          HarnessSpace.gutter,
          HarnessSpace.xl,
        ),
        children: [
          // A round that handed nothing in says so in the report itself.
          if (when != null && !widget.report.missing)
            Padding(
              padding: const EdgeInsets.only(bottom: HarnessSpace.md),
              child: HarnessMetaLine(
                parts: ['Handed in ${HandInReportScreen.whenLabel(when)}'],
              ),
            ),
          if ((walkthrough != null &&
                  walkthrough.isNotEmpty &&
                  widget.sessionId != null) ||
              _canStartDemo(context))
            Padding(
              padding: const EdgeInsets.only(bottom: HarnessSpace.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 4,
                    children: [
                      if (walkthrough != null &&
                          walkthrough.isNotEmpty &&
                          widget.sessionId != null)
                        HarnessTextButton(
                          key: const Key('report-walkthrough'),
                          label: 'Walkthrough',
                          icon: Icons.record_voice_over_rounded,
                          onPressed: _starting ? null : _startWalkthrough,
                        ),
                      if (_canStartDemo(context))
                        _demos.length == 1
                            ? HarnessTextButton(
                                key: const Key('report-start-demo'),
                                label: 'Start demo',
                                icon: Icons.slideshow_rounded,
                                onPressed: _startingDemo
                                    ? null
                                    : () => _startDemo(_demos.single),
                              )
                            : HarnessTextButton(
                                key: const Key('report-start-demo-menu'),
                                label: 'Start demo',
                                icon: Icons.slideshow_rounded,
                                onPressed: _startingDemo ? null : _chooseDemo,
                              ),
                    ],
                  ),
                  // What the last start said of a demo that is not on the
                  // screen: a run that opened its page says nothing here.
                  if (_demoState != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        _demoState!,
                        key: const Key('report-demo-state'),
                        style: HarnessText.caption(context),
                      ),
                    ),
                ],
              ),
            ),
          HandInReportView(
            report: widget.report,
            sessionId: widget.sessionId,
            expanded: true,
          ),
        ],
      ),
    );
  }
}

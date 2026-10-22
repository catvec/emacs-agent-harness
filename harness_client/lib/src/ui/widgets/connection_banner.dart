import 'package:flutter/material.dart';

import '../../state/app_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../theme/harness_theme.dart';

/// Says, quietly, that the connection to the harness was lost and is being
/// got back.  Nothing else on the screen changes: what was typed is still
/// there, and the app connects again by itself.  It takes no room when the
/// connection is up.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({
    super.key,
    required this.app,
    this.padding = const EdgeInsets.fromLTRB(16, 6, 16, 0),
    this.safeTop = false,
  });

  final AppController app;

  /// The space around the banner, which a page puts it in and a sheet with
  /// margins of its own does not.
  final EdgeInsets padding;

  /// Keep clear of the status bar and the notch: for a banner that is the
  /// first thing on the screen.  Only while it shows, so that it takes no
  /// room otherwise.
  final bool safeTop;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        if (!app.isReconnecting) return const SizedBox.shrink();
        final color = HarnessColors.amber;
        // What the last attempt said, else why the connection went.
        final detail = app.reconnectError ?? app.lostReason;
        // Announced when it comes up, to somebody who cannot see it.
        final banner = Semantics(
          container: true,
          liveRegion: true,
          label: 'Connection lost. Reconnecting.',
          child: HarnessNotice(
            key: const Key('connection-banner'),
            leading: HarnessActivity(radius: 8, color: color),
            message: 'Connection lost. Reconnecting…',
            detail: detail,
            color: color,
            actionLabel: app.waitingToRetry ? 'Retry now' : null,
            actionKey: const Key('connection-retry'),
            onAction: app.retryNow,
            margin: padding,
          ),
        );
        return safeTop ? SafeArea(bottom: false, child: banner) : banner;
      },
    );
  }
}

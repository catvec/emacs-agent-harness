import 'package:flutter/material.dart';

import '../../state/app_controller.dart';
import '../adaptive/adaptive_widgets.dart';
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
        final theme = Theme.of(context);
        final color = HarnessColors.amber;
        // What the last attempt said, else why the connection went.
        final detail = app.reconnectError ?? app.lostReason;
        final banner = Padding(
          padding: padding,
          // Announced when it comes up, to somebody who cannot see it.
          child: Semantics(
            container: true,
            liveRegion: true,
            label: 'Connection lost. Reconnecting.',
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                key: const Key('connection-banner'),
                padding: const EdgeInsets.fromLTRB(14, 9, 6, 9),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: color.withValues(alpha: 0.4)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    HarnessActivity(radius: 8, color: color),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Connection lost. Reconnecting…',
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: theme.colorScheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (detail != null && detail.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                detail,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (app.waitingToRetry)
                      HarnessTextButton(
                        key: const Key('connection-retry'),
                        label: 'Retry now',
                        onPressed: app.retryNow,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        return safeTop ? SafeArea(bottom: false, child: banner) : banner;
      },
    );
  }
}

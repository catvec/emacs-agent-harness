import 'package:flutter/widgets.dart';

enum HarnessPlatformStyle { material, cupertino }

/// The visual language for this build.  It follows the real platform by
/// default (Material on Android, Cupertino on iOS and macOS) and can be
/// previewed in Settings, which is handy in the browser and for screenshots.
class HarnessStyle extends InheritedWidget {
  const HarnessStyle({super.key, required this.style, required super.child});

  final HarnessPlatformStyle style;

  static HarnessStyle of(BuildContext context) {
    final style = context.dependOnInheritedWidgetOfExactType<HarnessStyle>();
    assert(style != null, 'HarnessStyle is missing above this widget.');
    return style!;
  }

  static bool isCupertino(BuildContext context) =>
      of(context).style == HarnessPlatformStyle.cupertino;

  @override
  bool updateShouldNotify(HarnessStyle oldWidget) => oldWidget.style != style;
}

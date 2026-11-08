import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// The visual language for this build.
///
/// Each desktop operating system has a look of its own, and the client keeps
/// the same pages under all of them: the Apple look of iOS and macOS, the
/// Material 3 look of Android, Windows' Fluent and Linux's Adwaita.  The
/// platform chooses its own look by default (see [forTarget]); Settings can
/// preview any of them, which is handy in the browser and for screenshots.
enum HarnessPlatformStyle {
  /// Android, and any place with no look of its own: Material 3.
  material('Material 3'),

  /// iOS and macOS: Cupertino.
  cupertino('Cupertino'),

  /// Windows: Fluent 2.
  windows('Fluent'),

  /// Linux: libadwaita.
  linux('Adwaita');

  const HarnessPlatformStyle(this.label);

  /// What the look is called, as a noun: `Material 3`, `Cupertino`,
  /// `Fluent`, `Adwaita`.
  final String label;

  /// The look a platform shows when the person has not chosen one: Apple's
  /// on iOS and macOS, Fluent on Windows, Adwaita on Linux, Material 3
  /// everywhere else (Android, Fuchsia, the web's other systems).
  static HarnessPlatformStyle forTarget(TargetPlatform platform) =>
      switch (platform) {
        TargetPlatform.iOS || TargetPlatform.macOS => cupertino,
        TargetPlatform.windows => windows,
        TargetPlatform.linux => linux,
        _ => material,
      };

  /// The look this build has now, from the browser or the phone it runs on.
  static HarnessPlatformStyle get current => forTarget(defaultTargetPlatform);

  /// Whether the look draws its pages with Cupertino's widgets.
  bool get isCupertino => this == HarnessPlatformStyle.cupertino;

  /// Whether the look draws its pages with Material 3's widgets.
  bool get isMaterial => !isCupertino;

  /// Whether the look belongs to a desktop operating system: Windows'
  /// Fluent or Linux's Adwaita.  (Apple's look is shared with iOS, and is
  /// not desktop-only.)
  bool get isDesktop =>
      this == HarnessPlatformStyle.windows ||
      this == HarnessPlatformStyle.linux;
}

/// The look of this build, for the widgets below it.
class HarnessStyle extends InheritedWidget {
  const HarnessStyle({super.key, required this.style, required super.child});

  final HarnessPlatformStyle style;

  static HarnessStyle of(BuildContext context) {
    final style = context.dependOnInheritedWidgetOfExactType<HarnessStyle>();
    assert(style != null, 'HarnessStyle is missing above this widget.');
    return style!;
  }

  /// The look above this widget, or null where a widget is drawn on its own
  /// (a test of one card, a preview of one row).
  static HarnessStyle? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HarnessStyle>();

  static HarnessPlatformStyle lookOf(BuildContext context) => of(context).style;

  static bool isCupertino(BuildContext context) =>
      of(context).style.isCupertino;

  static bool isWindows(BuildContext context) =>
      of(context).style == HarnessPlatformStyle.windows;

  static bool isLinux(BuildContext context) =>
      of(context).style == HarnessPlatformStyle.linux;

  @override
  bool updateShouldNotify(HarnessStyle oldWidget) => oldWidget.style != style;
}

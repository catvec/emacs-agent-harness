import 'package:flutter/widgets.dart';

import '../state/app_controller.dart';
import '../state/settings_controller.dart';

class HarnessScope extends InheritedWidget {
  const HarnessScope({
    super.key,
    required this.app,
    required this.settings,
    required super.child,
  });

  final AppController app;
  final SettingsController settings;

  static HarnessScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<HarnessScope>();
    assert(scope != null, 'HarnessScope is missing above this widget.');
    return scope!;
  }

  static AppController appOf(BuildContext context) => of(context).app;
  static AppController? maybeAppOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HarnessScope>()?.app;
  static SettingsController settingsOf(BuildContext context) =>
      of(context).settings;

  /// The settings, for a widget that also works outside the app's scope (a
  /// test of the widget alone), where there are none.
  static SettingsController? maybeSettingsOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HarnessScope>()?.settings;

  @override
  bool updateShouldNotify(HarnessScope oldWidget) =>
      oldWidget.app != app || oldWidget.settings != settings;
}

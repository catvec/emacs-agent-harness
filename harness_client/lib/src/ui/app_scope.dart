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
  static SettingsController settingsOf(BuildContext context) =>
      of(context).settings;

  @override
  bool updateShouldNotify(HarnessScope oldWidget) =>
      oldWidget.app != app || oldWidget.settings != settings;
}

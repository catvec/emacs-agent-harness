import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'app.dart';
import 'src/state/settings_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The screenshot run drives the browser through the semantics tree.
  if (const bool.fromEnvironment('E2E')) {
    SemanticsBinding.instance.ensureSemantics();
  }
  final settings = SettingsController();
  runApp(HarnessApp(settings: settings));
}

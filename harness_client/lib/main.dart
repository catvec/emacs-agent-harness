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
  // What the device remembers of its harness is read before the first frame,
  // so that a device that is signed in opens on its harness and not on a
  // form for an address and a secret it already holds.  A preference store
  // that does not answer must not keep the app from starting: after a moment
  // the form shows, and what is remembered arrives when the store does.
  await settings.load().timeout(const Duration(seconds: 1), onTimeout: () {});
  runApp(HarnessApp(settings: settings));
}

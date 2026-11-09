import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/desktop/plasma_window_rules.dart';

void main() {
  test('the KWin script touches only this app\'s buddy window', () {
    final script = PlasmaWindowRules.scriptFor(pid: 4242, caption: 'Buddy');
    expect(script, contains('var harnessPid = 4242;'));
    expect(script, contains('var harnessCaption = "Buddy";'));
    expect(script, contains('w.pid !== harnessPid'));
    expect(script, contains('w.caption !== harnessCaption'));
    expect(script, contains('w.keepAbove = true;'));
    expect(script, contains('w.skipTaskbar = true;'));
    expect(script, contains('w.noBorder = true;'));
    expect(script, contains('workspace.windowAdded.connect(harnessBuddy);'));
  });

  test('a caption goes into the script as a JavaScript string', () {
    final script = PlasmaWindowRules.scriptFor(
      pid: 7,
      caption: 'Buddy "x"\ny',
    );
    expect(script, contains(r'var harnessCaption = "Buddy \"x\"\ny";'));
  });
}

// The platform's look: which one a platform shows, what each is called, and
// which of them draw their pages with Cupertino's widgets.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('each platform shows its own look', () {
    expect(
      HarnessPlatformStyle.forTarget(TargetPlatform.android),
      HarnessPlatformStyle.material,
      reason: 'Android is Material 3',
    );
    expect(
      HarnessPlatformStyle.forTarget(TargetPlatform.fuchsia),
      HarnessPlatformStyle.material,
      reason: 'a platform with no look of its own gets Material 3',
    );
    expect(
      HarnessPlatformStyle.forTarget(TargetPlatform.iOS),
      HarnessPlatformStyle.cupertino,
    );
    expect(
      HarnessPlatformStyle.forTarget(TargetPlatform.macOS),
      HarnessPlatformStyle.cupertino,
    );
    expect(
      HarnessPlatformStyle.forTarget(TargetPlatform.windows),
      HarnessPlatformStyle.windows,
      reason: 'Windows is Fluent',
    );
    expect(
      HarnessPlatformStyle.forTarget(TargetPlatform.linux),
      HarnessPlatformStyle.linux,
      reason: 'Linux is Adwaita',
    );
  });

  test('the look this build has follows the platform it runs on', () {
    expect(HarnessPlatformStyle.current, HarnessPlatformStyle.material);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(HarnessPlatformStyle.current, HarnessPlatformStyle.windows);
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(HarnessPlatformStyle.current, HarnessPlatformStyle.linux);
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(HarnessPlatformStyle.current, HarnessPlatformStyle.cupertino);
    debugDefaultTargetPlatformOverride = null;
    expect(HarnessPlatformStyle.current, HarnessPlatformStyle.material);
  });

  test('each look is named by a noun', () {
    expect(HarnessPlatformStyle.material.label, 'Material 3');
    expect(HarnessPlatformStyle.cupertino.label, 'Cupertino');
    expect(HarnessPlatformStyle.windows.label, 'Fluent');
    expect(HarnessPlatformStyle.linux.label, 'Adwaita');
    for (final look in HarnessPlatformStyle.values) {
      expect(
        look.label,
        isNot(matches(RegExp(r'[.!?]$'))),
        reason: 'a label is a name, not a sentence: ${look.name}',
      );
    }
  });

  test('only the Apple look draws Cupertino pages', () {
    expect(HarnessPlatformStyle.cupertino.isCupertino, isTrue);
    for (final look in HarnessPlatformStyle.values) {
      if (look == HarnessPlatformStyle.cupertino) continue;
      expect(look.isCupertino, isFalse, reason: look.name);
      expect(
        look.isMaterial,
        isTrue,
        reason: '${look.name} draws Material pages',
      );
    }
  });

  test('the desktop looks are Windows and Linux', () {
    expect(HarnessPlatformStyle.windows.isDesktop, isTrue);
    expect(HarnessPlatformStyle.linux.isDesktop, isTrue);
    expect(HarnessPlatformStyle.material.isDesktop, isFalse);
    expect(
      HarnessPlatformStyle.cupertino.isDesktop,
      isFalse,
      reason: 'Apple is shared with iOS',
    );
  });
}

// What makes one desktop look that desktop's: its palette, its type, the
// corners of its controls and the shape of its bars.  These are the systems'
// own values -- Fluent 2 and libadwaita -- not the app's Nous-blue identity.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';

double? _radius(Object? shape) {
  if (shape is BorderRadius) return shape.topLeft.x;
  if (shape is! RoundedRectangleBorder) return null;
  final radius = shape.borderRadius;
  return radius is BorderRadius ? radius.topLeft.x : null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Windows Fluent', () {
    test('light: Segoe UI on a Mica canvas with accent-blue controls', () {
      final theme = HarnessTheme.windows(Brightness.light);
      final scheme = theme.colorScheme;
      expect(theme.brightness, Brightness.light);
      expect(theme.scaffoldBackgroundColor, const Color(0xFFF3F3F3));
      expect(scheme.primary, const Color(0xFF0067C0));
      expect(scheme.onPrimary, const Color(0xFFFFFFFF));
      expect(scheme.surface, const Color(0xFFF3F3F3));
      expect(scheme.surfaceContainerLow, const Color(0xFFFFFFFF));
      expect(scheme.surfaceContainerLowest, const Color(0xFFEBEBEB));
      expect(scheme.outlineVariant, const Color(0xFFE5E5E5));
      expect(theme.textTheme.bodyMedium?.fontFamily, 'Segoe UI Variable Text');
      expect(theme.textTheme.bodyMedium?.fontFamilyFallback, [
        'Segoe UI',
        'Roboto',
      ]);
      expect(theme.appBarTheme.centerTitle, isFalse);
      expect(theme.appBarTheme.toolbarHeight, 48);
      expect(theme.appBarTheme.titleTextStyle?.fontSize, 20);
      expect(theme.appBarTheme.titleTextStyle?.fontWeight, FontWeight.w600);
      expect(_radius(theme.cardTheme.shape), 8);
      expect(_radius(theme.filledButtonTheme.style?.shape?.resolve({})), 4);
      expect(
        _radius(
          (theme.inputDecorationTheme.border as OutlineInputBorder)
              .borderRadius,
        ),
        4,
      );
      expect(theme.navigationBarTheme.height, 64);
      expect(_radius(theme.navigationBarTheme.indicatorShape), 4);
      expect(
        theme.navigationBarTheme.labelTextStyle?.resolve({})?.fontFamily,
        'Segoe UI Variable Text',
      );
      expect(
        theme.switchTheme.trackColor?.resolve({WidgetState.selected}),
        const Color(0xFF0067C0),
      );
    });

    test('dark: the same roles on a dark Mica canvas', () {
      final theme = HarnessTheme.windows(Brightness.dark);
      final scheme = theme.colorScheme;
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, const Color(0xFF202020));
      expect(scheme.primary, const Color(0xFF60CDFF));
      expect(scheme.onPrimary, const Color(0xFF003E6B));
      expect(scheme.surfaceContainerLow, const Color(0xFF2B2B2B));
      expect(scheme.surfaceContainerLowest, const Color(0xFF272727));
      expect(scheme.outlineVariant, const Color(0xFF3A3A3A));
      expect(theme.textTheme.bodyMedium?.color, const Color(0xFFFFFFFF));
    });
  });

  group('Linux Adwaita', () {
    test('light: Cantarell, off-white cards, a centred header bar', () {
      final theme = HarnessTheme.linux(Brightness.light);
      final scheme = theme.colorScheme;
      expect(theme.brightness, Brightness.light);
      expect(theme.scaffoldBackgroundColor, const Color(0xFFF6F5F4));
      expect(scheme.primary, const Color(0xFF3584E4));
      expect(scheme.onPrimary, const Color(0xFFFFFFFF));
      expect(scheme.surface, const Color(0xFFF6F5F4));
      expect(scheme.surfaceContainerLow, const Color(0xFFFFFFFF));
      expect(
        scheme.surfaceContainerLowest,
        const Color(0xFFF6F5F4),
        reason: "GNOME's sidebar is the window",
      );
      expect(scheme.outlineVariant, const Color(0xFFE0DEDB));
      expect(theme.textTheme.bodyMedium?.fontFamily, 'Cantarell');
      expect(theme.textTheme.bodyMedium?.fontFamilyFallback, [
        'Ubuntu',
        'Noto Sans',
        'Roboto',
      ]);
      expect(theme.appBarTheme.centerTitle, isTrue);
      expect(theme.appBarTheme.toolbarHeight, 48);
      expect(theme.appBarTheme.titleTextStyle?.fontSize, 15);
      expect(theme.appBarTheme.titleTextStyle?.fontWeight, FontWeight.w700);
      expect(_radius(theme.cardTheme.shape), 12);
      expect(_radius(theme.filledButtonTheme.style?.shape?.resolve({})), 6);
      expect(
        _radius(
          (theme.inputDecorationTheme.border as OutlineInputBorder)
              .borderRadius,
        ),
        8,
      );
      expect(theme.navigationBarTheme.height, 72);
      expect(
        _radius(theme.navigationBarTheme.indicatorShape),
        999,
        reason: "GNOME's pill",
      );
    });

    test('dark: the same roles on a dark canvas', () {
      final theme = HarnessTheme.linux(Brightness.dark);
      final scheme = theme.colorScheme;
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, const Color(0xFF242424));
      expect(scheme.primary, const Color(0xFF78AEED));
      expect(scheme.onPrimary, const Color(0xFF002D5C));
      expect(scheme.surfaceContainerLow, const Color(0xFF303030));
      expect(scheme.surfaceContainerLowest, const Color(0xFF242424));
      expect(scheme.outlineVariant, const Color(0xFF3A3A3A));
    });
  });

  test('the platform picks the look its pages are drawn with', () {
    final material = HarnessTheme.platform(
      HarnessPlatformStyle.material,
      Brightness.light,
    );
    expect(
      material.colorScheme.primary,
      HarnessTheme.material(Brightness.light).colorScheme.primary,
      reason: 'Android keeps the app identity',
    );
    final apple = HarnessTheme.platform(
      HarnessPlatformStyle.cupertino,
      Brightness.light,
    );
    expect(
      apple.colorScheme.primary,
      HarnessTheme.material(Brightness.light).colorScheme.primary,
      reason: 'Cupertino draws Material pages under a CupertinoTheme',
    );
    expect(
      HarnessTheme.platform(
        HarnessPlatformStyle.windows,
        Brightness.light,
      ).colorScheme.primary,
      const Color(0xFF0067C0),
    );
    expect(
      HarnessTheme.platform(
        HarnessPlatformStyle.linux,
        Brightness.light,
      ).colorScheme.primary,
      const Color(0xFF3584E4),
    );
  });

  test('a desktop page changes as the desktop does, never as a slide', () {
    for (final theme in [
      HarnessTheme.windows(Brightness.light),
      HarnessTheme.windows(Brightness.dark),
      HarnessTheme.linux(Brightness.light),
      HarnessTheme.linux(Brightness.dark),
    ]) {
      for (final platform in TargetPlatform.values) {
        expect(
          theme.pageTransitionsTheme.builders[platform],
          isA<FadeForwardsPageTransitionsBuilder>(),
          reason: '$platform on ${theme.brightness.name}',
        );
      }
    }
  });
}

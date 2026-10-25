import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// The app's visual identity: warm paper, ink, and a single oxide accent.
/// Android and desktop get Material 3; Apple platforms get Cupertino
/// typography, controls and page transitions in the same palette.
class HarnessColors {
  static const oxide = Color(0xFFD65A36);
  static const oxideDark = Color(0xFFFF8A65);
  static const ink = Color(0xFF151517);
  static const paper = Color(0xFFF8F6F2);
  static const paperRaised = Color(0xFFFFFFFF);
  static const night = Color(0xFF101012);
  static const nightRaised = Color(0xFF1A1A1D);
  static const moss = Color(0xFF2F7D5B);
  static const amber = Color(0xFFC2871B);
  static const slate = Color(0xFF6B6B73);

  static Color status(String? status, Brightness brightness) =>
      switch (status) {
        'running' => const Color(0xFF2E9E6B),
        'blocked' =>
          brightness == Brightness.dark
              ? const Color(0xFFFFC14D)
              : const Color(0xFFB87500),
        'idle' =>
          brightness == Brightness.dark
              ? const Color(0xFF8E8E96)
              : const Color(0xFF8A8A90),
        'inactive' =>
          brightness == Brightness.dark
              ? const Color(0xFF55555B)
              : const Color(0xFFB5B5BA),
        _ =>
          brightness == Brightness.dark
              ? const Color(0xFF8E8E96)
              : const Color(0xFF8A8A90),
      };

  static Color column(String column, Brightness brightness) => switch (column) {
    'needs-input' =>
      brightness == Brightness.dark
          ? const Color(0xFFFFC14D)
          : const Color(0xFFB87500),
    'active' => const Color(0xFF2E9E6B),
    'review' => const Color(0xFF6B7FD1),
    'pending' =>
      brightness == Brightness.dark
          ? const Color(0xFF8E8E96)
          : const Color(0xFF7C7C84),
    'merging' => const Color(0xFF9A6BC9),
    'backlog' => const Color(0xFFB08956),
    'done' || 'cancelled' =>
      brightness == Brightness.dark
          ? const Color(0xFF55555B)
          : const Color(0xFF9B9BA0),
    _ => oxide,
  };
}

/// Spacing, on a 4-point grid.  Everything that sits at the edge of a page
/// uses [gutter], so that titles, rows, cards and labels share a left edge;
/// sheets are a little roomier ([sheetGutter]).
class HarnessSpace {
  const HarnessSpace._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double gutter = 16;
  static const double sheetGutter = 20;

  /// The widest a page of text and cards is made.
  static const double pageWidth = 840;
}

/// The type scale: every piece of text in the app is one of these roles,
/// rather than a size picked on the spot.  Nothing is set below 11 px.
///
///  * [pageTitle]  the title of a page or a sheet header
///  * [rowTitle]   the first line of a row or a card
///  * [body]       running text
///  * [subtitle]   the second line of a row, and the line under a title
///  * [meta]       small facts that sit at a row's edge: times, costs, counts
///  * [label]      an upper-case section or field label
///  * [caption]    helper text under a control
///  * [mono]       paths, commands, identifiers
class HarnessText {
  const HarnessText._();

  static Color _muted(BuildContext context) =>
      Theme.of(context).colorScheme.onSurfaceVariant;

  static TextStyle pageTitle(BuildContext context) => TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
    height: 1.2,
    color: Theme.of(context).colorScheme.onSurface,
  );

  static TextStyle sheetTitle(BuildContext context) => TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
    height: 1.25,
    color: Theme.of(context).colorScheme.onSurface,
  );

  static TextStyle rowTitle(BuildContext context) => TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    height: 1.3,
    color: Theme.of(context).colorScheme.onSurface,
  );

  static TextStyle body(BuildContext context) => TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    height: 1.45,
    color: Theme.of(context).colorScheme.onSurface,
  );

  static TextStyle subtitle(BuildContext context) => TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    height: 1.3,
    color: _muted(context),
  );

  static TextStyle meta(BuildContext context) => TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.3,
    color: _muted(context),
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  static TextStyle label(BuildContext context) => TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.0,
    height: 1.3,
    color: _muted(context).withValues(alpha: 0.85),
  );

  static TextStyle caption(BuildContext context) => TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    height: 1.4,
    color: _muted(context),
  );

  static TextStyle mono(BuildContext context) => TextStyle(
    fontFamily: 'monospace',
    fontSize: 12,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    height: 1.4,
    color: Theme.of(context).colorScheme.onSurface,
  );
}

class HarnessTheme {
  static ThemeData material(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: HarnessColors.oxide,
          brightness: brightness,
          dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
        ).copyWith(
          surface: dark ? HarnessColors.night : HarnessColors.paper,
          onSurface: dark ? const Color(0xFFF2F0EC) : HarnessColors.ink,
          surfaceContainerLowest: dark
              ? HarnessColors.night
              : HarnessColors.paperRaised,
          surfaceContainerLow: dark
              ? HarnessColors.nightRaised
              : HarnessColors.paperRaised,
          surfaceContainer: dark
              ? const Color(0xFF1F1F23)
              : const Color(0xFFF1EEE8),
          surfaceContainerHigh: dark
              ? const Color(0xFF26262B)
              : const Color(0xFFEAE6DF),
          outline: dark ? const Color(0xFF3B3B40) : const Color(0xFFD9D4CC),
          outlineVariant: dark
              ? const Color(0xFF2A2A2F)
              : const Color(0xFFE8E3DB),
        );
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
    );
    return base.copyWith(
      textTheme: _textTheme(base.textTheme, dark),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
          color: scheme.onSurface,
        ),
        // The title of a page that has a back button starts one standard
        // step from it; on a root page it starts at the page gutter.
        titleSpacing: HarnessSpace.gutter,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 70,
        elevation: 0,
        backgroundColor: dark
            ? const Color(0xFF151518)
            : HarnessColors.paperRaised,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStatePropertyAll(
          base.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        iconTheme: WidgetStatePropertyAll(
          IconThemeData(color: scheme.onSurfaceVariant),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF1D1D21) : HarnessColors.paperRaised,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        hintStyle: TextStyle(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 50),
          padding: const EdgeInsets.symmetric(horizontal: 22),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          side: BorderSide(color: scheme.outline),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          side: WidgetStatePropertyAll(BorderSide(color: scheme.outline)),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? scheme.primary.withValues(alpha: dark ? 0.24 : 0.12)
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurface,
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        side: BorderSide(color: scheme.outlineVariant),
        labelStyle: base.textTheme.labelMedium,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        },
      ),
    );
  }

  static TextTheme _textTheme(TextTheme base, bool dark) {
    final color = dark ? const Color(0xFFF2F0EC) : HarnessColors.ink;
    return base.copyWith(
      displaySmall: base.displaySmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -1.2,
        color: color,
      ),
      headlineMedium: base.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.8,
        color: color,
      ),
      headlineSmall: base.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
        color: color,
      ),
      titleLarge: base.titleLarge?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: -0.3,
        color: color,
      ),
      titleMedium: base.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
        color: color,
      ),
      bodyLarge: base.bodyLarge?.copyWith(height: 1.45, color: color),
      bodyMedium: base.bodyMedium?.copyWith(height: 1.45, color: color),
      labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    );
  }

  static CupertinoThemeData cupertino(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final text = dark ? CupertinoColors.white : const Color(0xFF161618);
    return CupertinoThemeData(
      brightness: brightness,
      primaryColor: dark ? HarnessColors.oxideDark : HarnessColors.oxide,
      primaryContrastingColor: CupertinoColors.white,
      barBackgroundColor: dark
          ? const Color(0xF2151518)
          : const Color(0xF7FFFFFF),
      scaffoldBackgroundColor: dark ? HarnessColors.night : HarnessColors.paper,
      textTheme: CupertinoTextThemeData(
        textStyle: TextStyle(
          fontFamily: '.SF Pro Text',
          fontSize: 16,
          color: text,
          letterSpacing: -0.2,
        ),
        navTitleTextStyle: TextStyle(
          fontFamily: '.SF Pro Display',
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: text,
          letterSpacing: -0.3,
        ),
        navLargeTitleTextStyle: TextStyle(
          fontFamily: '.SF Pro Display',
          fontSize: 34,
          fontWeight: FontWeight.w700,
          color: text,
          letterSpacing: -1.0,
        ),
        navActionTextStyle: TextStyle(
          fontFamily: '.SF Pro Text',
          fontSize: 16,
          color: dark ? HarnessColors.oxideDark : HarnessColors.oxide,
        ),
        actionTextStyle: TextStyle(
          fontFamily: '.SF Pro Text',
          fontSize: 16,
          color: dark ? HarnessColors.oxideDark : HarnessColors.oxide,
        ),
        tabLabelTextStyle: TextStyle(
          fontFamily: '.SF Pro Text',
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: text,
        ),
        pickerTextStyle: TextStyle(
          fontFamily: '.SF Pro Text',
          fontSize: 16,
          color: text,
        ),
        dateTimePickerTextStyle: TextStyle(
          fontFamily: '.SF Pro Text',
          fontSize: 16,
          color: text,
        ),
      ),
    );
  }
}

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../adaptive/platform_style.dart';

/// The app's visual identity after Hermes Desktop: a deep Nous-blue canvas,
/// warm cream text, blue and cream accents, flat panels with square corners,
/// thin rules, and a halftone/dither field rather than gradients and shadows.
/// Android and desktop get Material 3; Apple platforms get Cupertino
/// typography and controls in the same palette.
class HarnessColors {
  static const oxide = Color(0xFF4D5CFF); // electric blue, the accent
  static const oxideDark = Color(0xFF8D97FF);
  static const ink = Color(0xFFF4ECDD); // warm cream, the text
  static const paper = Color(0xFF0A0B2E); // deep Nous blue
  static const paperRaised = Color(0xFF10123A);
  static const night = Color(0xFF0A0B2E);
  static const nightRaised = Color(0xFF141743);
  static const moss = Color(0xFF58C79B);
  static const amber = Color(0xFFC2871B);
  static const slate = Color(0xFFA9A4B8);
  static const line = Color(0xFF2C3170);

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
    fontSize: 24,
    fontWeight: FontWeight.w900,
    letterSpacing: -0.9,
    height: 1.12,
    color: Theme.of(context).colorScheme.onSurface,
  );

  static TextStyle sheetTitle(BuildContext context) => TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w900,
    letterSpacing: -0.8,
    height: 1.15,
    color: Theme.of(context).colorScheme.onSurface,
  );

  static TextStyle rowTitle(BuildContext context) => TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
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
    letterSpacing: 1.3,
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
          brightness: Brightness.dark,
          dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
        ).copyWith(
          surface: HarnessColors.paper,
          onSurface: HarnessColors.ink,
          primary: HarnessColors.oxide,
          onPrimary: const Color(0xFFFFFFFF),
          primaryContainer: const Color(0xFF232A7A),
          onPrimaryContainer: const Color(0xFFF4ECDD),
          secondary: const Color(0xFFE8D9B5),
          onSecondary: const Color(0xFF0A0B2E),
          surfaceContainerLowest: const Color(0xFF07081F),
          surfaceContainerLow: HarnessColors.paperRaised,
          surfaceContainer: const Color(0xFF141743),
          surfaceContainerHigh: const Color(0xFF1A1E52),
          surfaceContainerHighest: const Color(0xFF1E2258),
          surfaceDim: const Color(0xFF07081F),
          surfaceBright: const Color(0xFF242A6E),
          outline: HarnessColors.line,
          outlineVariant: const Color(0xFF222756),
          error: const Color(0xFFFF8A80),
        );
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
    );
    // Material's label for a destination of the bottom bar: its size and
    // line, which the platform's text theme above leaves to the locale.
    final barLabel = Typography.englishLike2021.labelSmall;
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
          borderRadius: BorderRadius.circular(2),
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
          // The platform text theme names only a family and a colour here:
          // the size and the line of Material's label belong to the locale,
          // and a theme is built before the app knows one.  Given only the
          // body's 14 points, a name on the bar takes two lines on a narrow
          // phone.
          base.textTheme.labelSmall?.copyWith(
            fontSize: barLabel?.fontSize,
            height: barLabel?.height,
            letterSpacing: barLabel?.letterSpacing,
            fontWeight: FontWeight.w600,
          ),
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
          borderRadius: BorderRadius.circular(2),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(2),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(2),
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
          textStyle: base.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            fontSize: 15,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
          side: BorderSide(color: scheme.outline),
          textStyle: base.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            fontSize: 15,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          // The family too: a style that names none is drawn in the test
          // engine's font, as squares, in every picture of a button.
          textStyle: base.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
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

  /// The theme a look draws its pages with, for the brightness in use: the
  /// Apple look is [cupertino], Android's is [material], and the two desktop
  /// looks have their own ([windows], [linux]).
  ///
  /// [material] is also the base of a Cupertino build, under the
  /// `CupertinoTheme` the app puts over it.
  static ThemeData platform(
    HarnessPlatformStyle style,
    Brightness brightness,
  ) => switch (style) {
    HarnessPlatformStyle.cupertino ||
    HarnessPlatformStyle.material => material(brightness),
    HarnessPlatformStyle.windows => windows(brightness),
    HarnessPlatformStyle.linux => linux(brightness),
  };

  /// Windows' Fluent 2: Segoe UI, a light Mica-like canvas, white cards with
  /// 8-point corners, an accent-blue control and a 48-point header.
  static ThemeData windows(Brightness brightness) =>
      _desktop(_DesktopLook.windows(brightness));

  /// Linux's libadwaita: Cantarell, an off-white canvas, 12-point cards, a
  /// centred header bar and Adwaita blue.
  static ThemeData linux(Brightness brightness) =>
      _desktop(_DesktopLook.linux(brightness));

  /// One Material theme for a desktop look, light or dark as [look] says.
  ///
  /// The pages are Android's pages, with Android's widgets: what makes them
  /// read as Windows or as GNOME is the theme under them, the way the same
  /// cards read as iOS under Cupertino and as Android under Material 3.
  static ThemeData _desktop(_DesktopLook look) {
    final dark = look.brightness == Brightness.dark;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: look.accent,
          brightness: look.brightness,
          dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
        ).copyWith(
          primary: look.accent,
          onPrimary: look.onAccent,
          primaryContainer: look.accentContainer,
          onPrimaryContainer: look.onAccentContainer,
          surface: look.background,
          onSurface: look.text,
          onSurfaceVariant: look.muted,
          surfaceContainerLowest: look.sidebar,
          surfaceContainerLow: look.card,
          surfaceContainer: look.surface,
          surfaceContainerHigh: look.raised,
          surfaceContainerHighest: look.surfaceHigh,
          surfaceTint: Colors.transparent,
          outline: look.line,
          outlineVariant: look.lineSubtle,
          error: look.error,
          onError: look.onError,
        );
    final base = ThemeData(
      useMaterial3: true,
      brightness: look.brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      fontFamily: look.fontFamily,
      fontFamilyFallback: look.fontFallback,
      splashFactory: InkRipple.splashFactory,
    );
    final text = base.textTheme.apply(
      fontFamily: look.fontFamily,
      fontFamilyFallback: look.fontFallback,
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    );
    TextStyle styled({
      required double size,
      FontWeight weight = FontWeight.w400,
      Color? color,
      double spacing = 0,
    }) => TextStyle(
      fontFamily: look.fontFamily,
      fontFamilyFallback: look.fontFallback,
      fontSize: size,
      fontWeight: weight,
      letterSpacing: spacing,
      color: color ?? scheme.onSurface,
    );
    final label = styled(size: 14, weight: FontWeight.w600);
    final barLabel = Typography.englishLike2021.labelSmall;
    return base.copyWith(
      textTheme: text,
      iconTheme: IconThemeData(color: scheme.onSurface),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: look.centerTitle,
        toolbarHeight: 48,
        titleSpacing: HarnessSpace.gutter,
        titleTextStyle: styled(
          size: look.headerSize,
          weight: look.headerWeight,
          spacing: look.centerTitle ? 0 : -0.2,
        ),
        // A header of GNOME and of a modern Windows app is a panel, not a
        // floating bar: a rule under it says where the page starts.
        shape: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(look.cardRadius),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: dark ? 0.5 : 0.18),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(look.cardRadius),
        ),
        titleTextStyle: styled(size: 18, weight: FontWeight.w600),
        contentTextStyle: styled(size: 14, color: scheme.onSurfaceVariant),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(look.cardRadius),
          ),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: look.barHeight,
        elevation: 0,
        backgroundColor: look.bar,
        indicatorColor: scheme.primary.withValues(alpha: dark ? 0.28 : 0.16),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(look.barIndicatorRadius),
        ),
        labelTextStyle: WidgetStatePropertyAll(
          text.labelSmall?.copyWith(
            fontFamily: look.fontFamily,
            fontFamilyFallback: look.fontFallback,
            fontSize: barLabel?.fontSize,
            height: barLabel?.height,
            letterSpacing: barLabel?.letterSpacing,
            fontWeight: FontWeight.w600,
          ),
        ),
        iconTheme: WidgetStatePropertyAll(
          IconThemeData(color: scheme.onSurfaceVariant),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(look.fieldRadius),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(look.fieldRadius),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(look.fieldRadius),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        hintStyle: TextStyle(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(look.controlRadius),
          ),
          textStyle: label,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(look.controlRadius),
          ),
          side: BorderSide(color: scheme.outline),
          textStyle: label,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(look.controlRadius),
          ),
          textStyle: label,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          side: WidgetStatePropertyAll(
            BorderSide(color: scheme.outlineVariant),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(look.controlRadius),
            ),
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? scheme.primary.withValues(alpha: dark ? 0.28 : 0.12)
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurface,
          ),
          textStyle: WidgetStatePropertyAll(label),
        ),
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.outlineVariant,
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.onPrimary
              : (dark ? const Color(0xFFDADADA) : const Color(0xFF5F5F5F)),
        ),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : Colors.transparent,
        ),
        checkColor: WidgetStatePropertyAll(scheme.onPrimary),
        side: BorderSide(color: scheme.outline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        side: BorderSide(color: scheme.outlineVariant),
        backgroundColor: scheme.surfaceContainerLow,
        labelStyle: text.labelMedium?.copyWith(
          fontFamily: look.fontFamily,
          fontFamilyFallback: look.fontFallback,
          color: scheme.onSurface,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: scheme.primary,
        selectionColor: scheme.primary.withValues(alpha: 0.24),
        selectionHandleColor: scheme.primary,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(8),
        radius: const Radius.circular(4),
        thumbColor: WidgetStatePropertyAll(
          scheme.onSurfaceVariant.withValues(alpha: 0.35),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 500),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(look.controlRadius),
          border: Border.all(color: scheme.outlineVariant),
        ),
        textStyle: styled(size: 12, color: scheme.onSurface),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.fuchsia: FadeForwardsPageTransitionsBuilder(),
        },
      ),
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

/// What one desktop look is made of: its palette, its type and the corner
/// each kind of control has.
///
/// The two looks are Fluent 2, as Windows 11 draws its own apps, and
/// libadwaita, as GNOME draws its own.  Their values are the systems' own,
/// not the brand's: a person who asks an app to look native expects the
/// window, the cards and the controls to move as the rest of the desktop
/// does.
class _DesktopLook {
  const _DesktopLook({
    required this.brightness,
    required this.fontFamily,
    required this.fontFallback,
    required this.background,
    required this.sidebar,
    required this.card,
    required this.surface,
    required this.raised,
    required this.surfaceHigh,
    required this.text,
    required this.muted,
    required this.line,
    required this.lineSubtle,
    required this.accent,
    required this.onAccent,
    required this.accentContainer,
    required this.onAccentContainer,
    required this.error,
    required this.onError,
    required this.bar,
    required this.cardRadius,
    required this.controlRadius,
    required this.fieldRadius,
    required this.barHeight,
    required this.barIndicatorRadius,
    required this.headerSize,
    required this.headerWeight,
    required this.centerTitle,
  });

  factory _DesktopLook.windows(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return _DesktopLook(
      brightness: brightness,
      fontFamily: 'Segoe UI Variable Text',
      fontFallback: const ['Segoe UI', 'Roboto'],
      background: dark ? const Color(0xFF202020) : const Color(0xFFF3F3F3),
      sidebar: dark ? const Color(0xFF272727) : const Color(0xFFEBEBEB),
      card: dark ? const Color(0xFF2B2B2B) : const Color(0xFFFFFFFF),
      surface: dark ? const Color(0xFF242424) : const Color(0xFFF9F9F9),
      raised: dark ? const Color(0xFF2F2F2F) : const Color(0xFFFFFFFF),
      surfaceHigh: dark ? const Color(0xFF333333) : const Color(0xFFF0F0F0),
      text: dark ? const Color(0xFFFFFFFF) : const Color(0xFF1A1A1A),
      muted: dark ? const Color(0xFFC5C5C5) : const Color(0xFF5F5F5F),
      line: dark ? const Color(0xFF4A4A4A) : const Color(0xFFC8C8C8),
      lineSubtle: dark ? const Color(0xFF3A3A3A) : const Color(0xFFE5E5E5),
      accent: dark ? const Color(0xFF60CDFF) : const Color(0xFF0067C0),
      onAccent: dark ? const Color(0xFF003E6B) : const Color(0xFFFFFFFF),
      accentContainer: dark ? const Color(0xFF0F3550) : const Color(0xFFE5F1FB),
      onAccentContainer: dark
          ? const Color(0xFFCDE8FF)
          : const Color(0xFF003E73),
      error: dark ? const Color(0xFFFF99A4) : const Color(0xFFC42B1C),
      onError: dark ? const Color(0xFF3B0000) : const Color(0xFFFFFFFF),
      bar: dark ? const Color(0xFF272727) : const Color(0xFFF3F3F3),
      cardRadius: 8,
      controlRadius: 4,
      fieldRadius: 4,
      barHeight: 64,
      barIndicatorRadius: 4,
      headerSize: 20,
      headerWeight: FontWeight.w600,
      centerTitle: false,
    );
  }

  factory _DesktopLook.linux(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return _DesktopLook(
      brightness: brightness,
      fontFamily: 'Cantarell',
      fontFallback: const ['Ubuntu', 'Noto Sans', 'Roboto'],
      background: dark ? const Color(0xFF242424) : const Color(0xFFF6F5F4),
      // GNOME's navigation pane is the window, not a panel of it: the rule
      // between the two is the divider, as in Nautilus and Settings.
      sidebar: dark ? const Color(0xFF242424) : const Color(0xFFF6F5F4),
      card: dark ? const Color(0xFF303030) : const Color(0xFFFFFFFF),
      surface: dark ? const Color(0xFF2A2A2A) : const Color(0xFFF9F9F8),
      raised: dark ? const Color(0xFF383838) : const Color(0xFFFFFFFF),
      surfaceHigh: dark ? const Color(0xFF3A3A3A) : const Color(0xFFEDEBE9),
      text: dark ? const Color(0xFFFFFFFF) : const Color(0xFF1E1E1E),
      muted: dark ? const Color(0xFFC0C0C0) : const Color(0xFF5E5E5E),
      line: dark ? const Color(0xFF4A4A4A) : const Color(0xFFC8C4BE),
      lineSubtle: dark ? const Color(0xFF3A3A3A) : const Color(0xFFE0DEDB),
      accent: dark ? const Color(0xFF78AEED) : const Color(0xFF3584E4),
      onAccent: dark ? const Color(0xFF002D5C) : const Color(0xFFFFFFFF),
      accentContainer: dark ? const Color(0xFF1C3B5C) : const Color(0xFFD7E8FF),
      onAccentContainer: dark
          ? const Color(0xFFCDE8FF)
          : const Color(0xFF003E73),
      error: dark ? const Color(0xFFFF7B63) : const Color(0xFFC01C28),
      onError: dark ? const Color(0xFF3B0000) : const Color(0xFFFFFFFF),
      bar: dark ? const Color(0xFF303030) : const Color(0xFFFFFFFF),
      cardRadius: 12,
      controlRadius: 6,
      fieldRadius: 8,
      barHeight: 72,
      barIndicatorRadius: 999,
      headerSize: 15,
      headerWeight: FontWeight.w700,
      centerTitle: true,
    );
  }

  final Brightness brightness;
  final String fontFamily;
  final List<String> fontFallback;

  /// The window behind every page.
  final Color background;

  /// The navigation pane, at the start of a wide window.
  final Color sidebar;

  /// A card, a row of a list: what sits on the window.
  final Color card;

  /// A panel between the window and a card.
  final Color surface;
  final Color raised;
  final Color surfaceHigh;
  final Color text;
  final Color muted;
  final Color line;
  final Color lineSubtle;

  final Color accent;
  final Color onAccent;
  final Color accentContainer;
  final Color onAccentContainer;
  final Color error;
  final Color onError;

  /// The bar at the bottom of a narrow window.
  final Color bar;
  final double cardRadius;
  final double controlRadius;
  final double fieldRadius;
  final double barHeight;
  final double barIndicatorRadius;
  final double headerSize;
  final FontWeight headerWeight;
  final bool centerTitle;
}

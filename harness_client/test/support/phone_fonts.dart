// The theme of the app with a font named wherever the app names none.
//
// The app leaves the font of a button label to the phone (a style that names
// no family is drawn in the system font there).  The test engine has no such
// font: it draws a style without a family in Ahem, as squares, whatever
// fonts a test loads.  A test that makes a picture of the app names Roboto,
// which `loadRealFonts` has loaded, in the theme it gives `HarnessApp`:
//
//   HarnessApp(settings: settings, appController: app, themeBuilder: phoneFonts)
import 'package:flutter/material.dart';

/// [theme] with Roboto wherever it names no family: the text theme and the
/// labels of the Material buttons.
ThemeData phoneFonts(ThemeData theme) {
  ButtonStyle? button(ButtonStyle? style) => style?.copyWith(
    textStyle: const WidgetStatePropertyAll(
      TextStyle(
        fontFamily: 'Roboto',
        fontWeight: FontWeight.w600,
        fontSize: 15,
      ),
    ),
  );
  return theme.copyWith(
    textTheme: theme.textTheme.apply(fontFamily: 'Roboto'),
    filledButtonTheme: FilledButtonThemeData(
      style: button(theme.filledButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: button(theme.outlinedButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: button(theme.textButtonTheme.style),
    ),
  );
}

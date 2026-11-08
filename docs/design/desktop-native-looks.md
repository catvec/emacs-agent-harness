# Desktop native looks

## The problem

The client had two looks: Material 3 on Android and Cupertino on Apple.
A Windows or Linux desktop got Material 3 with the app's warm paper palette:
correct controls, but a window that reads as an Android app on a desktop. The
user asked for Mac OS, Windows and Linux native UI looks, just as iOS and
Android already have their own.

There is one more thing the platform does not decide: a person may want to
see another platform's look, or a screenshot of it, on any device. Settings
already let a phone preview Android or Apple; the desktop looks have to join
that choice, and the default has to remain the real platform.

## The decision

Four looks, one per visual language, carried by the same pages:

| Value | Label | Platform | Theme |
|---|---|---|---|
| `material` | Material 3 | Android, and anything with no look of its own | `HarnessTheme.material` (the app's identity) |
| `cupertino` | Cupertino | iOS, macOS | `HarnessTheme.material` under a `CupertinoTheme` |
| `windows` | Fluent | Windows | `HarnessTheme.windows` |
| `linux` | Adwaita | Linux | `HarnessTheme.linux` |

`HarnessPlatformStyle.forTarget` maps a `TargetPlatform` to the look, and
`HarnessPlatformStyle.current` reads `defaultTargetPlatform`. `Settings ›
Look` stores a `PreviewPlatform` (`system`, `material`, `cupertino`,
`windows`, `linux`); `system` resolves through `forTarget`, and every other
value names a look directly.

The Windows and Linux themes are Material themes underneath — the pages are
Android's widgets — with the desktop's own palette, type, corner radii, bars
and transitions over them. This is the same trick the Apple look already
uses: the same cards read as iOS under Cupertino and as Android under
Material 3, and they read as Fluent or Adwaita under these. A native widget
toolkit per desktop (WinUI, GTK) would mean forking every screen; the client
is one Flutter app and stays one.

### Fluent 2 (Windows)

* **Palette**: Mica-like canvas `#F3F3F3` light / `#202020` dark, white cards
  (`#2B2B2B` dark), sidebar `#EBEBEB` / `#272727`, accent blue `#0067C0`
  light / `#60CDFF` dark, error `#C42B1C` / `#FF99A4`.
* **Type**: Segoe UI Variable Text, with Segoe UI and Roboto as fallbacks; a
  20-point semibold header, 14-point semibold control labels.
* **Shape**: 4-point controls and fields, 8-point cards, a 64-point bottom
  bar with a 4-point indicator. The page in use is a filled row with a
  3-point accent bar at its leading edge.
* **Header**: left-aligned in a 48-point bar, a rule under it. Pages change
  with a fade, never a slide.

### Adwaita (Linux)

* **Palette**: off-white `#F6F5F4` light / `#242424` dark, white cards
  (`#303030` dark), a sidebar that is the window itself (the same colour, with
  the divider as its rule, as GNOME's own navigation panes are), Adwaita blue
  `#3584E4` light / `#78AEED` dark, error `#C01C28` / `#FF7B63`.
* **Type**: Cantarell, with Ubuntu, Noto Sans and Roboto as fallbacks; a
  15-point bold centred header, 14-point semibold control labels.
* **Shape**: 6-point controls, 8-point fields, 12-point cards, a 72-point
  bottom bar with a pill indicator. The page in use is a tinted pill.
* **Header**: centred, in a 48-point bar with a rule under it, as GNOME's
  own header bars are.

Both desktop looks name their font family in the `ThemeData` and in the
`TextTheme` so that a platform without the font falls back in order rather
than to an arbitrary face. Both use `FadeForwardsPageTransitionsBuilder` for
every target platform: a desktop page does not slide in from the side.

The app's cards (`HarnessCard`, `HarnessCardList`) take the look's corner
radius (8 on Windows, 12 on Linux), because they are not Material `Card`s and
would otherwise keep the client's 16 points; they keep 16 on Android and
Apple, and an explicit `radius` still wins.  A Fluent card is lifted by a
hairline shadow; an Adwaita card is flat.

### Chrome, not just colours

A palette alone made the two desktop looks read as the same app tinted two
ways.  The differences a person sees without comparing swatches are in the
chrome around the page:

* **Section headers.** Android's are the brand's: 11-point, tracked, upper
  case.  A desktop names a group of settings as its own settings app does, in
  sentence case: Fluent 14-point semibold, GNOME 15-point bold.  The sessions
  list groups (`Needs you`, `Active now`, `Recent`) follow the same rule, so
  they stop reading as Android's labels on a light background.
* **Sidebar.** Fluent's pane is wider (300/256 points against the client's
  264/228), its rows 13-point with 8-point vertical padding and 4-point
  corners, and its search box a compact 4-point field.  GNOME's pane is
  slightly wider than Android's, its rows 15-point with 10-point padding and
  a 10-point pill, its search entry an 8-point field, and the pane shares the
  window's colour.  The selected row is Fluent's accent bar in a filled panel
  or GNOME's tinted pill.
* **Header.** Windows keeps the app's left-aligned header at 20-point
  semibold; GNOME centres a 15-point bold title in its bar.  The embedded
  session list uses the same title style, so a split window shows the look in
  both panes.
* **Bottom bar.** A narrow Fluent window has a rule above its 64-point bar
  and a 4-point indicator; a narrow GNOME window has no rule, a 72-point bar
  and a pill.
* **Cards.** Fluent's are 8-point, bordered and lightly lifted; GNOME's are
  12-point, bordered and flat.

## Alternatives

* **A theme per desktop in a separate widget tree** (WinUI-style rows, GTK
  header bars): the honest native look, but every screen would need a second
  implementation, and the board, transcript and settings would drift. The
  look is a theme, not a second app.
* **One "desktop" look** with Fluent/Adwaita only through the accent colour:
  cheap, but it does not answer the request — a Windows user would still see
  the same window as a GNOME user.
* **Detecting the desktop from the browser's user agent on web**: the web
  build already has `?platform=`; `system` on web reads the browser's
  platform as Flutter reports it. No extra detection was added.
* **Persisting `Look` as a full `HarnessPlatformStyle` name**: the existing
  preference was a `PreviewPlatform` with a `system` member. Extending that
  enum keeps old stored values (`material`, `cupertino`, missing) working and
  keeps `system` meaningful. A damaged or unknown value falls back to
  `system`, as before.

## The shape of the change

* `lib/src/ui/adaptive/platform_style.dart` — the four-value enum, its labels
  (`Material 3`, `Cupertino`, `Fluent`, `Adwaita`), `forTarget`, `current`,
  `isCupertino`, `isMaterial`, `isDesktop`, and `HarnessStyle.lookOf`,
  `isWindows`, `isLinux`.
* `lib/src/ui/theme/harness_theme.dart` — `HarnessTheme.platform` (look +
  brightness to `ThemeData`), `windows` and `linux`, one `_DesktopLook`
  palette/type/radius record per look, and the Material theme built over it:
  app bar, cards, dialogs, sheets, dividers, bottom bar, fields, buttons,
  segmented buttons, switches, check boxes, chips, selection, scrollbars,
  tooltips, page transitions.
* `lib/src/state/settings_controller.dart` — `PreviewPlatform` gains
  `windows` and `linux`; they are read, written and defaulted like the other
  values, and `useCupertino` is false for them.
* `lib/app.dart` — resolves the stored preview to a look (`system` through
  `HarnessPlatformStyle.current`), passes it to `HarnessStyle`, and gives
  `MaterialApp` `HarnessTheme.platform(style, …)` for both brightnesses. The
  web `?platform=` accepts `windows`/`fluent` and `linux`/`adwaita`.
* `lib/src/ui/screens/settings_screen.dart` — the Appearance row is **Look**
  (a select, because five choices do not fit a phone's segment), with the
  choices System, Android, Apple, Windows, Linux and the active look's label
  under it. The old "Platform feel" segment and its two-sentence caption are
  gone.
* `lib/src/ui/screens/home_shell.dart` — a desktop sidebar is a panel with a
  rule at its edge; the row in use is marked as its system marks it (a
  Fluent accent bar, an Adwaita pill), and each row has a stable
  `sidebar-item-<id>` key for tests and screenshots.
* `lib/src/ui/adaptive/adaptive_widgets.dart` — a page header is centred
  under the Linux look, at the start elsewhere.
* `lib/src/ui/adaptive/layout_widgets.dart` — cards take the look's corner.
* Runners: macOS `MainFlutterWindow` opens at 1280×820 with a 760×560 minimum;
  Linux `my_application.cc` sets the same default size and a `GDK_HINT_MIN_SIZE`;
  a new `windows/` runner (Flutter's template, title **Harness**, product name
  **Harness**) opens at the same size and handles `WM_GETMINMAXINFO` for the
  same minimum, scaled for the monitor's DPI.

## Copy

The row is nouns and noun phrases, no sentence:

* **Look** — the setting
* **System, or a platform's controls** — its description
* **System**, **Android**, **Apple**, **Windows**, **Linux** — the choices
* **Material 3**, **Cupertino**, **Fluent**, **Adwaita** — the active look

The old caption's prose ("Cupertino navigation, sheets and typography are
active.") is removed rather than reworded.

## Tests

The fonts are part of what makes a look: the screenshots load **Selawik**
(Microsoft's metric-compatible, open Segoe UI) for `Segoe UI Variable Text`
and **Cantarell** for GNOME from `test/fonts/`, with their licences, so the
two looks do not both draw in Roboto; the Cupertino icons are loaded from the
`cupertino_icons` package so the Apple look draws icons rather than squares.

* `test/platform_style_test.dart` — every `TargetPlatform` maps to its look;
  `current` follows the platform; the labels are the four nouns; only Apple
  draws Cupertino pages; Windows and Linux are the desktop looks.
* `test/desktop_looks_theme_test.dart` — the tokens of both looks in light
  and dark: canvas, cards, sidebar, accent, muted text, font family and
  fallbacks, header size/weight/centring, card/control/field radii, bottom
  bar height and indicator, and the fade transition.
* `test/settings_controller_test.dart` — a desktop look is written under its
  name, is read back by the next run, is not Cupertino, and a damaged value
  keeps `system`.
* `test/desktop_looks_test.dart` — each look draws the same page with its own
  primary colour and corner marks; a narrow window keeps its bottom bar; the
  Settings › Look row names every choice and the active look, switches the
  live theme, reads `System` as the platform it runs on, asserts the desktop
  section headers are sentence case (and the upper-case label is gone), and
  checks the sidebar rows' sizes and weights.
* `test/desktop_looks_screenshots_test.dart` — pictures of the four looks at
  1280×900, the two desktop looks in dark mode, narrow windows, Settings, and
  the open Look menu (`HARNESS_SHOTS=…` writes them).
* `test/desktop_runners_test.dart` — the three runners still open at
  1280×820 and refuse to go below 760×560; the Windows runner is complete.

## Known limits

* The screenshots load Selawik and Cantarell for the desktop families,
  because the machine that runs them has neither Segoe UI nor Cantarell.  The
  app itself names the system families; the test faces are only how the test
  renders them.
* A desktop look is a Material theme, so hover and ink effects remain
  Material's; Fluent's reveal and GNOME's hover are not reproduced.
* The Windows runner is generated from Flutter's template and cannot be built
  on Linux; `test/desktop_runners_test.dart` checks its files and the size
  contract statically.

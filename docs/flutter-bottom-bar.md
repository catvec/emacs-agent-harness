# The names on the bottom bar

The bar at the bottom of the app names every destination: `Sessions`,
`Workspace`, `Tasks`, `Usage`, `Server`, `Settings`. On a phone six of them
share the width, and a name that does not fit its share was broken where it
stood: `Workspa` above `ce`, `Session` above `s`. This document says why that
happened, what the bar does instead, and what it gives up.

## Why a name was two lines

Two things met.

- **The bar was given the width of the body text.** The theme asked for
  Material's `labelSmall` (11 points) with a heavier weight, but it asked the
  *platform* text theme, which carries only a family and a colour: the size
  and the line of a Material label belong to the locale, and a theme is built
  before the app knows one. A style without a size inherits the one around
  it — the body's 14 points — so each name was drawn a third wider than the
  design says.
- **Six destinations do not fit a small phone.** `NavigationBar` gives each
  destination `screenWidth / destinations` and hands the label a `Text` of
  its own. At 320 points each destination has 53 points; `Workspace` at 11
  points is about 60. `Text` wraps at any character when a word is too wide,
  so the extra width became a second line in the middle of the name. At 390
  and one and a half times the text it is the same story with more room
  needed.

The same is true of `CupertinoTabBar`, which also draws a bare `Text` for
each label.

## What the bar does instead

- **A name is one line, at one size for all of them.** When the shell draws
  the bar it measures its labels with the style the bar will use, takes the
  widest, and works out the scale at which that label fits a destination
  (less a small margin). If the text size in use is larger than that scale,
  the bar is drawn under a `MediaQuery` that clamps its text to it
  (`lib/src/ui/screens/home_shell.dart`, `_fittedLabelScale` and
  `_withFittedLabels`). Every name shrinks by the same factor, so none looks
  more important than another, and the bar's height and icons do not change.
- **Nothing changes where there is room.** When the widest name already fits
  the size the reader set, no clamp is applied: three destinations on a
  phone, or the bar on a tablet, grow their names with the text as before
  (Material still caps a destination label at 1.3×, as it always has).
- **The theme names the label's size.** `harness_theme.dart` now takes the
  size, line and spacing of Material 3's `labelSmall` from
  `Typography.englishLike2021` and keeps the platform family and colour.
  A bar label is 11 points, as the theme intended, not the body's 14.

## What it gives up

On a phone narrow enough for six destinations, a reader who sets large text
gets the largest size that fits — at 320 points and 1.3× that is about 9
points, not 14 — because a name cannot both be one line and be as large as
the text setting. The alternative was hiding labels (`onlyShowSelected`),
which makes five destinations harder to find; a `More` destination, which
changes what the phone's navigation is; an ellipsis, which turns `Workspace`
into `Works…`; or a bar that scrolls sideways, which puts destinations off
the screen. Shrinking keeps every destination named, visible and one line,
which is what the bar is for. The full name remains the destination's
semantic label and its tooltip, so a screen reader and a long press both say
it in full.

## What is checked

`test/bottom_bar_test.dart` draws the app with the fonts of a phone and
asserts that every name is one line, no wider than its destination and
inside the bar, at:

| Width | Text | Bar |
|---|---|---|
| 320, 360 | 1.0× | Material, six destinations |
| 320 | 1.3× | Material, six destinations |
| 390 | 1.5× | Material, six destinations |
| 320 | 1.3× | Cupertino, six destinations |
| 900 | 1.5× | Material, five destinations: nothing shrunk, 1.3× kept |

With `HARNESS_SHOTS=DIR` it also writes `bottom-bar-WIDTH-SCALE.png` for each
of those cases. The pictures in `harness_client/screenshots/`
(`bottom-bar-320.png`, `bottom-bar-320-text13.png`,
`bottom-bar-390-text15.png`) come from that run.

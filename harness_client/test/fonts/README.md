# The fonts of the tests that draw a desktop

`flutter test` draws a style whose family is not loaded as the test font, as
squares.  The desktop looks name the fonts their systems use -- Segoe UI
Variable Text on Windows, Cantarell on GNOME -- which the machine that runs the
tests has neither of.  These files stand in for them, under those family names
(see `../support/real_fonts.dart`), so that a screenshot shows the typeface the
look is made of rather than squares:

| File | Stands for | Licence |
|---|---|---|
| `Selawik-Regular.ttf`, `Selawik-Semibold.ttf` | Segoe UI Variable Text, Segoe UI | MIT, Microsoft (`LICENSE-Selawik.txt`) |
| `Cantarell-Regular.ttf`, `Cantarell-Bold.ttf` | Cantarell | OFL 1.1 (`LICENSE-Cantarell.txt`) |

Selawik is Microsoft's metric-compatible, open replacement for Segoe UI.  The
app itself does not bundle them: on Windows and GNOME the system font is
used, and the theme's fallback chain covers a machine that lacks it.

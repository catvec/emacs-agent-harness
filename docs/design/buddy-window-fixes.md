# The buddy window: frame, size and when it exists

Design note for the fix to the desktop buddy's own window, November 2026.
It is a change to the away card described in
[workspace-voice-buddy.md](workspace-voice-buddy.md), not a new surface:
one call, the same `WorkspaceBuddyController`, and the same card widget.
This note records the four failures reported against the first native
window and the decisions that answer them, so a later change does not
undo one of them by accident.

## The report

The buddy card's native window was reported to

1. be drawn behind other windows -- it had to be clicked to come forward;
2. appear when the workspace had opted in but no voice call was running;
3. carry the window manager's title bar above the card;
4. overflow: the card's content was taller than the window, so its lower
   rows were cut off.

The first three are one class of problem: the window was made through
Flutter's windowing API, which gives no frame, size or stacking policy,
and the extra properties were requests the Linux/Wayland stack did not
honour.  The fourth was a size chosen before the card had ever laid out.

## Decisions

### Keep the native window; fix what the platform actually accepts

The alternative considered was to give up the native window on a
compositor that will not float it and use the persistent in-app card.  It
was rejected: the in-app card cannot be drawn over another application at
all, which is the feature's reason to exist, and the report asks for the
floating card, not for its removal.  The fallback stays for a platform
that cannot make a window (`HARNESS_BUDDY_WINDOW=off`, the web, a failed
window), unchanged.

A `gtk-layer-shell` window would guarantee keep-above on Wayland, but it
needs a build dependency and a separate windowing path for a card that
must also work on X11, GNOME, macOS and Windows.  It remains the honest
long-term fix for non-Plasma Wayland compositors; this change does not
promise more than the compositor gives there.

### Frame: a zero-height client-side titlebar

GTK 3 draws client-side decorations when a window has a custom titlebar,
and a compositor does not add a server-side title bar to a
client-side-decorated window.  The Linux window therefore gets an empty
`GtkBox` as its titlebar, styled to zero height and no padding.  The card
then reaches every edge; the small shadow GTK draws around a client-side
frame stays, which is what a floating card wants.  This works on Wayland
and X11, and needs no compositor cooperation.

Rejected: `gtk_window_set_decorated(false)` after realize (GTK ignores it
on Wayland), and `nativeapi`'s `setFrameless` (a GTK 3 library called
against Flutter's GTK 4 embedder, so its requests are not the window's).

### Size: the card measures, the window follows

The window opens at the card's fixed width and a provisional height of
120 px.  `BuddyWindowContent` lays the card out under an unbounded height
inside a `SingleChildScrollView`, measures the card after the frame and
reports the size through `BuddyWindowService.reportContentSize`.  The
service clamps the height to 120–720 px and asks GTK for it, toggling
resizability because GTK ignores a width change on a non-resizable
window.  A running card (measured 208 px) and a failed card with its
problem and `Retry` (250 px) are both shown whole; content beyond 720 px
scrolls inside the card instead of overflowing.

Rejected: a fixed window size with an internal scroll view only (the
reported overflow, and a lot of empty window around short cards), and
Flutter's `sizedToContent` controller (it sized to the view, not the
card, and cannot shrink a mapped window on this embedder).

### Stacking: ask the compositor that has a way to be asked

- **X11:** `gtk_window_set_keep_above`, `gtk_window_set_skip_taskbar_hint`,
  `gtk_window_set_accept_focus(false)` and `gtk_window_set_focus_on_map(false)`
  are honoured by the window manager; `gtk_window_move` places the card at
  the bottom-right of the primary work area.
- **Plasma Wayland:** xdg-shell has no keep-above, so KWin's own scripting
  interface loads a small script over D-Bus.  It matches only this
  process's pid and the window caption `Buddy`, sets `keepAbove`,
  `skipTaskbar` and `noBorder`, and is unloaded when the card is disposed.
  Nothing else is touched; a session without KWin scripting logs the
  failure and keeps the card.
- **Other Wayland compositors:** the window is still frameless and
  non-activating, and the compositor places it.  It is above the windows
  at the moment it is shown, but not guaranteed to stay above a window the
  person raises later.  The design's existing limit says this; the change
  makes Plasma the exception rather than the rule.

Rejected: removing the non-activating hints so the window takes focus and
is raised.  That fixes visibility by stealing the keyboard from whatever
the person is doing, which the card exists to avoid; the report's "I had
to click on it" describes the symptom, not a request for a focus-taking
card.

### Existence: a call, not the opt-in

The card is gated on `WorkspaceBuddyController.inCall`, the same predicate
as the in-call bar (`starting || running || failed || ending`), not on
`enabled` and not only on `running`.  The reported false appearance was
the workspace opt-in drawing the card with no call; a failed start is a
call whose problem and `Retry` belong on the card, so it must keep it.
This applies to the native window, the away layer and the in-app fallback
alike, so a platform without a window behaves the same way.

## Shape of the change

| Area | Change |
| --- | --- |
| `lib/src/desktop/buddy_window_linux.dart` | GTK 3 FFI for the frame, window size, hints, placement, drag and bringing the app forward |
| `lib/src/desktop/buddy_window_native.dart` | fixed-size Linux controller, content-size resizing, Linux styling, Plasma rule lifecycle, and `inCall` awareness stays in the host |
| `lib/src/desktop/plasma_window_rules.dart` | the KWin script and its D-Bus load/unload |
| `lib/src/ui/widgets/buddy_window_host.dart` | the card measures itself and scrolls; the window is wanted only while `inCall` |
| `lib/src/ui/widgets/workspace_buddy.dart` | the in-app layer uses the same `inCall` gate |
| `test/workspace_buddy_widget_test.dart`, `test/workspace_shell_test.dart` | exact no-call, failed-card, own-window and content-size tests |
| `test/plasma_window_rules_test.dart` | the script's selection, properties and escaping |
| `tool/buddy_window_probe.dart`, `tool/buddy_window_probe.sh` | the real card in the real window, with `--failed` and `--capture=PATH`; the script runs it on the Linux desktop with the project's toolchain |

## Verification

- `flutter analyze` and the focused Flutter tests pass; the whole app
  build check (`harness_client/tool/check_build.sh`) passes for the
  committed tree.  The whole Flutter test run has 23 failures that exist
  at the branch's base too; the branch adds none.
- The probe was run under a nested `kwin_wayland --virtual` session as a
  Plasma client and as a GNOME client.  KWin reported `noBorder=true`,
  `keepAbove=true`, `skipTaskbar=true`, `active=false` and the card above
  the main window on Plasma, with `frame == client` and a 312x208 running
  or 312x250 failed window.  On GNOME it reported `frame == client` but no
  keep-above, as documented.  The card was captured from its own layer
  tree at those sizes: see [the evidence](../evidence/buddy-window/README.md).
- The X11 path is not observed here: Xwayland on this machine crashes in
  its NVIDIA EGL initialisation.  Its hints are the GTK documentation's,
  and the code path is the same one that gives the frame and size on
  Wayland.

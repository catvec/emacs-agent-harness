# The buddy window, as a compositor saw it

These pictures are the card as the probe
([`tool/buddy_window_probe.dart`](../../../harness_client/tool/buddy_window_probe.dart),
run with `harness_client/tool/buddy_window_probe.sh`)
rendered it in its real native window, captured from the window's own layer
tree (`--capture=`), not from a screen.  They were taken under a nested
`kwin_wayland --virtual` session (1280x900), with the probe started as a
Plasma Wayland client (`XDG_CURRENT_DESKTOP=KDE`, `GDK_BACKEND=wayland`).
KWin's scripting interface reported the window properties in the same run.

| Picture | State | Window |
| --- | --- | --- |
| `kde-running.png` | a running call, `Listening` | 312x208; `noBorder`, `keepAbove`, `skipTaskbar`; above the main window; client frame, no titlebar |
| `kde-failed.png` | a start that failed, with its problem and `Retry` | 312x250; the same properties; the whole taller card, no overflow |
| `gnome-running.png` | a running call, Plasma rules not loaded | 312x208; `frame == client` (the zero-height GTK titlebar is still frameless), but no keep-above on a compositor without the rules |

The probe prints `PROBE capture <path> <size>` when it writes a picture, and
the nesting script reads back `caption`, `noBorder`, `keepAbove`,
`skipTaskbar`, `frame`, `client` and stacking order from KWin.  The X11 path
is not pictured: Xwayland on the machine where this was run crashes in its
NVIDIA EGL initialisation, so the X11 hints are the GTK documentation's.

# The workspace computer

Design note, November 2026.  The workspace's computer is no longer a
drawn preview: it is a private X display and a real RFB server on this
machine, with its own home, browser profile and window manager.  A
command in it changes the pixels a screenshot returns, `present_demo`
can click and type on it, and the Flutter client draws the same RFB
stream a browser's noVNC page does.  When the tools are missing, the
computer says `Computer off` and names what is missing; it never draws
a desk that cannot be touched.

This page records what was decided, what is implemented, and what is
still the stronger container backend in
[workspace mode](workspace-mode.md#the-box).

## What was wrong

The first slice of workspace mode had the whole contract for a
computer -- `workspace/box/*`, the Resources page, the takeover
motion, the Flutter desk -- but no implementation behind it.  The
client drew `_ComputerPreview`: a static "Stone Co — Countertop
quote" window, labelled `Preview` / `Sandbox staged · preview`.  The
Resources page answered `unavailable · box-staged`.  The memory
contract was also missing `memory/get`, `memory/forget`,
`memory/pages`, `memory/page`, `memory/sync` and `memory/reindex`,
and `workspace/thread/merge` was declared but absent.  A user could
not start a computer, see a screen, run a command in it, take it over
or read a workspace's browser profile.

## The decision: a local desktop, stated as such

The harness runs the desktop on the host, in a private directory under
the harness state directory, on a display no other process uses.  The
backend is called `local` in every answer, and the status says
`local display and process`, not "sandbox" or "container".

The alternative -- a rootless container with Xvfb, x11vnc and a
browser baked into an image -- remains the design in
[workspace mode](workspace-mode.md#the-box).  It is not this change:
there is no container runtime in the test environment (Docker's daemon
is not running), building and publishing an image is a separate
artifact, and a box that claims isolation it does not have is worse
than one that names its boundary.  The `local` backend keeps the same
method seam, so a later `container` backend can replace the lifecycle
without changing a client.

The other alternative -- a stream of synthetic screenshots, or a
cartoon monitor -- was rejected by the task and by the existing
design: a screenshot is evidence only when it is the framebuffer the
server is sending now.

## Runtime shape

```
workspace state directory
└── workspace-box/
    └── w-<id>/
        ├── home/       HOME, XDG dirs, files the agent makes
        ├── tmp/        TMPDIR and XDG_RUNTIME_DIR
        ├── browser/    a Firefox profile per workspace
        ├── logs/       Xvfb, window manager and bridge logs
        ├── xauth       X authority, mode 600
        └── box.json    state, display, ports, token, pids

Xvfb          :N, TCP loopback, xauth, 1280x800x24
  └── window manager (openbox/fluxbox/xfwm4, when present)
x11vnc        loopback RFB, no password, bound to 127.0.0.1
python3       scripts/workspace-box/websockify.py
  ├── /vnc_lite.html + /core + /vendor   vendored noVNC
  └── /websockify?token=…                WebSocket ↔ RFB
```

* `workspace/box/start` allocates a free display (90–199), a free VNC
  port and a free web port, writes a random token into the record, and
  starts the processes through `make-process` (argv lists, no shell).
  It fails closed with `box-tools-missing` and the names of the
  missing programs.
* The record and the pids live in the state directory, so a harness
  restart adopts a running box; `stop` keeps the home and the browser
  profile, `reset` removes them.
* `workspace/box/status` answers `state`, `health`, `backend`,
  `isolation`, `display`, `width`, `height`, `vnc-port`, `web-port`,
  `url` (the noVNC page), `socket` (the WebSocket an RFB client
  speaks), `control`, `missing` and a `reason` with `code` and `text`.
  A stopped box answers `running: false` and a reason; it has no URL
  and no socket.
* `workspace/box/vnc` returns the same endpoint in its `available`,
  `url`, `socket`, `state` and `reason` fields.  The token is not
  echoed as a separate field; it is inside the URL the box minted, and
  the socket names its workspace as well.
* The WebSocket bridge validates the token on the upgrade, serves the
  noVNC static files from `scripts/workspace-box/novnc`, and refuses
  an unknown path or a bad token.  It is plain Python 3 with no
  third-party package.  The noVNC copy is 1.6.0 with its license.
* VNC itself is unauthenticated RFB bound to loopback: the loopback
  bind is the boundary, and the token protects the WebSocket the page
  and the app use.  The page is on `127.0.0.1` too.  Neither is
  published on another interface.

### The screen on another machine

The box's web port is loopback, so a phone cannot reach it.  The app
resolves a box socket (`ws://127.0.0.1:PORT/websockify?token=...&workspace=ID`)
to the harness the device signed in to:
`ws://HARNESS:PORT/workspace/vnc?workspace=ID`.  The harness's
existing listener carries the upgrade at that path only for a request
whose ACP session secret is live (the `bearer.SECRET` WebSocket
subprotocol; the app's `WebSocketTransport` offers it, and the secret
is not put in the URL).  The listener bridges the binary frames to the
box's own RFB port on `127.0.0.1`; a target that is not loopback is
refused, and the device names a workspace, never a port of this
machine.  The box's page token is not needed on the tunnel and is
dropped from the resolved URL.  Nothing new is bound: this rides the
same authenticated listener as ACP.  The bridge's WebSocket still
serves the local noVNC page unchanged.

A desktop on the harness machine may keep the loopback socket: the
app rewrites the host and port only when it has an address of the
harness to reach.

### Checking the tunnel

`harness_client/tool/vnc_probe.dart` is a Dart client that resolves the
box socket through `VncEndpoint`, opens it with `WebSocketTransport`
(offering the session secret in the `bearer.` subprotocol), and does
the RFB handshake with the app's `RfbClient`.  It prints the resolved
URL, the frame's size and a pixel digest, optionally types into the
box, then reconnects for a second frame.  Start a box, read its
`socket` from `workspace/box/vnc`, mint a session secret
(`acp/remote-create-token`), and run from `harness_client`:

```sh
dart run tool/vnc_probe.dart "ws://HARNESS:PORT/acp" "$TOKEN" "$SOCKET" --input
```

`--input` moves the pointer to 100,100 and types `echo VNC-PROBE-OK`
followed by Return; `VNC_PROBE_FRAME=/path/frame.ppm` also writes the
first frame as a binary PPM, which `ffmpeg -i frame.ppm frame.png`
turns into a picture of the stream itself.  A phone does the same with
a widget in front of it; the probe has no widget, so a failure is the
transport's or the protocol's.  `docs/media/workspace-computer-live-frame.png`
is a frame the probe received from a live box through the tunnel.

## The screen and the hands

| Method | Answer |
|---|---|
| `workspace/box/screenshot` | PNG of the framebuffer, via `ffmpeg -f x11grab` |
| `workspace/box/exec` | stdout, stderr and exit status from a command in the box's env; bounded; a background option |
| `workspace/box/windows` | the named windows `xwininfo` sees, with geometry |
| `workspace/box/click` / `type` / `key` / `scroll` / `drag` | `xdotool` input |
| `workspace/box/launch` | a URL in the box's Firefox, or a command in the box's home |
| `workspace/box/clipboard` | read or write through `xclip` when it is present |
| `workspace/box/browser` / `workspace/browser/open` | the profile's metadata, or a page opened in the box |
| `workspace/box/take-over` / `return-control` | the control lock |
| `workspace/box/logs` | the last lines of each box log |

`take-over` writes `control: "user"` before it answers.  `click`,
`type`, `key`, `scroll` and `drag` refuse with a `harness-error` while
the reviewer has control; the screenshot and window list stay
readable.  `return-control` gives it back.  The state is on disk, so a
restart does not silently take the screen from the reviewer.

The browser is Firefox with a profile of its own.  `workspace/box/browser`
reads `cookies.sqlite`, `permissions.sqlite`, `logins.json`, the
`storage/` and `cache2/` sizes, and returns sites, cookie counts,
saved-session origins, storage and cache bytes, plus a `totals`
object.  It never reads a cookie value, a password or an encrypted
username into the answer.  `workspace/browser/clear` takes `kinds`, a
list of `cookies`, `storage`, `cache` and `permissions` (omitted means
all of them; an unknown kind is refused before anything is touched).
A profile clear removes the kind from the whole profile.  A site clear
is origin-scoped: another origin keeps its storage and permissions,
including another scheme, a subdomain or another port of the same host.
Cookies belong to a host rather than an origin, so a site clear takes
the host's cookies and its domain cookie, while a subdomain's own
cookies stay.  `workspace/browser/login/forget` stops the browser, then
removes only that origin's cookies and its `storage/default`,
`storage/permanent` and `storage/temporary` directories.  Both stop
the box's browser first so the next page load sees the change and a
running Firefox never rewrites the profile under the deletion.  The
wallet methods still answer `wallet-unavailable`: there is no payment
broker in this slice.

## The two clients

**Flutter.** `WorkspaceComputerStatus` now carries `running`, `state`,
`socket`, `url`, `reason`, the screen size, and the box's `isolation`,
`display`, `home`, `profile`, `disk` and `missing` facts.  The desk and the
phone sheet show `Live`, `Starting` or `Off`, the real screen through
`VncView`/`RfbClient`, `Take over`/`Return control`, and a `Start`
button when the box is off.  The desk's `Hide computer` control folds it
into a narrow rail with `Show computer` and `Details`; the rail and the
phone sheet's `Details` open the computer's facts -- control, backend,
isolation, display, screen size, home, profile, disk, desktop, socket,
and the reason or missing tools when it is off -- instead of drawing the
screen a second time.  The folded state lives with the workspace screen.
`_ComputerPreview` and its quotation
mock-up are gone.  A test hands `VncView` a transport of its own, but
the real RFB client still decodes the frame, so the widget test is a
protocol test, not a picture substitute.

**Emacs.** `C-c w c` opens `*Workspace Computer*`: backend, isolation,
control, display, size, reason, missing tools, the noVNC URL, the
socket, a screenshot the box really took, and the buttons `Start`,
`Stop`, `Restart`, `Take over`, `Return control`, `Open VNC`,
`Screenshot` and `Refresh`.  The workspace header carries
`Computer · live`, `Computer · starting` or `Computer · off`.  Emacs
cannot draw RFB itself, so `Open VNC` opens the same noVNC page in
the desktop browser; the screenshot comes through ACP as a base64 PNG.

## Copy inventory

The strings this change adds or changes, in the two clients.  Every
one is a noun, a noun phrase, an adjective or a short action; the
reason and missing-tool text is the harness's own status data.

| String | Where |
|---|---|
| `Computer · live` / `Computer · starting` / `Computer · off` | Emacs header |
| `Computer` | Emacs header button, menu item and tooltip |
| `The workspace computer's screen` | Emacs `Computer` tooltip |
| `Workspace computer` / `State` / `Screen` / `Picture` | Emacs computer page |
| `Backend` / `Isolation` / `Control` / `Display` / `Reason` / `Missing` | Emacs computer page rows |
| `You` / `Agent` | Emacs control values |
| `Live` / `Starting` / `Unavailable` / `Off` | Emacs run states |
| `Start` / `Stop` / `Restart` / `Take over` / `Return control` / `Open VNC` / `Screenshot` / `Refresh` | Emacs buttons |
| `Start the workspace computer` / `Stop the workspace computer` / `Restart the workspace computer` | Emacs tooltips |
| `Reviewer control of the screen` / `Agent control of the screen` | Emacs tooltips |
| `The computer's noVNC page` / `A picture of the current screen` / `Read the computer again` | Emacs tooltips |
| `Reading` / `Starting` / `Stopping` / `Restarting` / `Taking over` / `Returning control` | Emacs busy states |
| `No VNC page · computer off` / `No workspace open` / `No screenshot` | Emacs echo area |
| `Live` / `Starting` / `Off` | Flutter desk and sheet |
| `Computer · Live` / `Computer · Starting` / `Computer · Off` | Flutter folded rail |
| `Hide computer` / `Show computer` | Flutter desk fold control and folded rail |
| `Details` / `Control` / `Backend` / `Isolation` / `Display` / `Screen` / `Home` / `Profile` / `Disk` / `Desktop` / `Socket` / `Reason` / `Missing` | Flutter details sheet |
| `Agent` / `You` | Flutter details control values |
| `Computer off` / `Start` | Flutter empty computer |
| `Box running` / `Box · local` | Flutter desk footer |
| `Screen lost` | Flutter lost connection |
| `Take over` / `Return control` / `Control · agent` / `Control · you` | Flutter takeover |
| `Computer tools` / `Box staged` | Resources reason labels (the second is the old harness's `box-staged`) |

## Other workspace gaps filled

* `memory/get`, `memory/forget`, `memory/pages`, `memory/page`,
  `memory/recall-test`, `memory/reindex` and `memory/sync` now exist
  on the workspace memory contract, with tests for read, page, recall,
  rebuild, sync, forget and a repeated forget.
* `workspace/thread/merge` parks the source thread, marks it `merged`,
  records `merged-into`, appends the source to the target's
  `merged-from`, and includes both threads' entries in the target's
  timeline.  Merging twice is idempotent and returns the target.
* `workspace/resources/status` reads the real box and browser profile
  when the box runs, reports the box's own reason when it does not,
  and keeps the credentials section from the secrets module.  The
  wallet remains an explicitly unavailable contract.

## Tools

The local backend needs `Xvfb`, `x11vnc`, `xdotool`, `xauth`,
`xdpyinfo`, `python3` and `ffmpeg`; a window manager (`openbox` is
tried first) is optional; a browser (`firefox`) is optional and only
needed for the browser methods.  On Arch:

```sh
sudo pacman -S --needed xorg-server-xvfb x11vnc xdotool openbox
```

`harness-workspace-box-tool-directories` points the module at an
unpacked tool tree (a directory of executables, with an adjacent
`../lib` for `LD_LIBRARY_PATH`), which is also how the live verification
ran without installing packages.  `harness-workspace-box-tools` names
what must be found before a start; `harness-workspace-box-backend`
`local` is the only working backend, and a name that is not `auto` or
`local` fails closed with `backend-unavailable`.

## Tests and the live proof

* `test/harness-workspace-box-test.el` holds the off state and its
  missing tools, a running record's VNC URL and socket, the control
  lock and input refusal, the window parser, the browser metadata
  (including that no cookie value or encrypted username is in the
  answer), and that every method the clients call exists.
* `test/harness-workspace-test.el` holds the resources status without a
  box, the merged timeline, and the memory read/forget/page/recall
  path.
* `test/harness-ui-workspace-test.el` holds the exact header copy,
  tooltips, the computer page's state lines, its button tooltips and
  the `Computer off` state with the missing tools named.
* The live run started a real Xvfb display with the extracted tools,
  opened Firefox on the box's own start page, and took the screenshot
  in `docs/media/workspace-computer-live.png` through
  `workspace/box/screenshot`.  The pixels are the framebuffer x11vnc
  was serving, not a drawing.

## What is still not here

A container backend, a per-workspace network policy, audio, clipboard
without `xclip`, a CDP/BiDi browser tool surface, login forms, and the
wallet broker.  The local backend is not a sandbox: a command in it
runs as the harness user and can read what that user can read.  The
status says so (`local display and process`), and the container
backend remains stage 5 of the
[staged plan](workspace-mode-implementation.md#stage-5-the-box).

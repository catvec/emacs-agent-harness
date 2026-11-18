# Evidence: workspace thread mediation

The pictures behind the hand-in, kept whole so they can be looked at rather
than described. They come in two kinds, and each file says which it is.

**Live** pictures are photographs of a running Emacs frame: the task's own
`open_harness` instance, driven through `scripts/dev.sh eval`, with the buffer
in its frame and `harness-dev-shot` reading the pixels. They show the real
faces, the real window and the real echo area.

**Drawn** pictures are made from the code as it stands rather than photographed
from a display. The Emacs ones are rendered from the buffer the code writes,
reading each run of text with the face it carries; the Flutter ones are drawn
by the app's own widget tests. They exist because the pictures must be
reproducible where no display is reachable, and because a picture and its copy
cannot drift apart when the words in it are the words the buffer holds.

| File | Kind | What it is |
|---|---|---|
| `emacs-workspace-live.png` | Live | The `*harness workspace: Home*` buffer in the running frame: the header `Workspace · Home   Thread · Harness memory · Parked` with the `Inbox` button among the others, the thread list, `You From Kitchen renovation`, the reassignment line `Reassigned to Harness memory · mediator`, and the reply. |
| `emacs-inbox-live.png` | Live | The `*Inbox*` buffer in the running frame with nothing waiting: the header `Inbox · Home`, `Scope · Workspace`, the four scope buttons and `No messages waiting`. |
| `emacs-inbox.png` | Drawn | The `*Inbox*` buffer with the header `Inbox · Home`, `Scope · Workspace`, `1 queued · 1 waiting · 1 unavailable`, the four scope buttons, and one row in each state: `Queued`, `Waiting` and `Unavailable` with its reason `Session unavailable`. |
| `emacs-inbox-all.png` | Drawn | The same buffer in the `All` scope, where a row names the workspace it waits in: `Studio · Harness memory  Waiting` beside a row of this workspace, which leaves the name to the header. |
| `emacs-workspace.png` | Drawn | The `*Workspace*` buffer with a routed message and a reassignment: `Thread · Harness memory`, the origin label `You From Kitchen renovation · voice`, the reassignment line `Reassigned Kitchen renovation → Harness memory · queued`, and the reply. |
| `workspace-inbox.png` | The Flutter `Inbox` sheet, drawn by `test/workspace_inbox_screenshots_test.dart` at the phone's own sizes: title `Inbox · Home`, `Refresh`, the four scope chips, the counts and the three states. |
| `workspace-inbox-all.png` | The same sheet in the `All` scope, where a row names the workspace it waits in: `Studio · Harness memory` beside a row of this workspace, which leaves the name to the title. |
| `workspace-inbox-empty.png` | The same sheet with nothing waiting: `No messages waiting`. |
| `workspace-provenance.png` | The Flutter timeline with provenance: `From Kitchen renovation · voice`, `Reassigned to Harness memory · mediator`, and the reassignment line `Reassigned from Kitchen renovation to Harness memory · queued`. |

## Taking the live pictures

The live pictures are taken from the task's own running instance, with the
buffer in its frame:

```
HARNESS_DEV_SOCKET=<socket from open_harness> scripts/dev.sh eval \
  '(let* ((f (seq-find (lambda (fr) (equal (frame-parameter fr (quote name)) "harness-dev"))
                       (frame-list)))
          (b (get-buffer "*harness workspace: Home*")))
     (with-selected-frame f
       (set-frame-size f 150 40)
       (set-window-buffer (frame-selected-window f) b)
       (with-current-buffer b (goto-char (point-min)) (recenter 0))
       (redisplay t)
       (harness-dev-shot "/tmp/workspace-final.png")))'
```

`harness-dev-shot` lowers the frame again before it exports, so a picture
never raises the instance over the person's own windows.

## Drawing the Emacs pictures

`render.el` renders the buffers with their own code and reads each run of text
with the face it carries; `render.py` draws those runs in the face's colours.
A picture and its copy cannot drift apart, because the words in it are the
words the buffer holds.

```
emacs -Q --batch -L lisp -L lisp/modules -L lisp/ui \
  -l test/harness-test-helpers.el \
  -l docs/evidence/workspace-thread-mediation/render.el \
  --eval '(progn (require (quote harness-ui-workspace)) (ws-evidence-render "/tmp/shots"))'
for n in emacs-inbox emacs-inbox-all emacs-workspace; do
  python3 docs/evidence/workspace-thread-mediation/render.py /tmp/shots/$n.json /tmp/shots/$n.png
done
```

## Drawing the Flutter pictures

The Flutter pictures are written by

```
HARNESS_SHOTS=/some/directory flutter test test/workspace_inbox_screenshots_test.dart
```

which also asserts the exact strings above, so a picture and its copy cannot
drift apart. Without `HARNESS_SHOTS` the same cases still draw and check that
nothing overflows, and write nothing.

The full suite, the lint and the Flutter build check are quoted as tool calls
of this session rather than stored here, because each run's log names the
commit it covered and a commit cannot hold its own run.

# Evidence: the freeform agent board

Pictures of the Flutter board page, drawn by the app itself.

They come from the widget tests, which render the real page and write the
pixels:

```
cd harness_client
HARNESS_SHOTS=../docs/evidence/freeform-board \
  FLUTTER_VERSIONS_DIR=…/flutter-versions \
  ./tool/flutter test test/board_screenshots_test.dart
```

The drawing is the engine's own fixture, `test/fixtures/harness-board-fixture.el`,
mirrored in the app's preview document, so a picture of it shows the same
geometry a harness answers with.

| File | What it is |
|---|---|
| `board-desktop.png` | The overview at 1280×860: the framed region with its title tab, sticky notes with their questions kept open, component cards, a store drawn from a path, the raw ink a person drew, the reference picture with its name above it, a task marker, and three connectors with their labels. |
| `board-phone.png` | The same board on a 390×844 phone. |
| `board-queue-detail.png` | A second diagram, walked into: the same `api` component placed by this diagram's own view, its own connector, and the breadcrumb back to the overview. One identity, two views. |
| `board-list-phone.png` | The boards list, with the harness's own figures for the board. |
| `board-tools-phone.png` | The tools a person builds a diagram with, on a phone: `Select`, `Note`, `Shape`, `Frame`, `Label`, `Ink`, and `New diagram`. |
| `board-selection-desktop.png` | A selected component and the actions it offers: `Edit`, `Rotate`, `Connect`, `Group`, `Portal`, `Discuss`, `Request task`, `Delete`, `Links`, with the actions that need two objects disabled and their tooltips saying why. |
| `emacs-render.svg`, `emacs-render.png` | The board engine's own renderer (`harness-board-svg`) drawing the same fixture. This is the picture the Emacs page shows, made by Emacs, not by the app: `emacs -Q --batch … --eval '(harness-board-svg (harness-board-fixture-board) "d-overview")'`, then `rsvg-convert -z 2`. |
| `board-demo.txt` | `scripts/board-demo.sh`: one board built through the tools (`scene.read`, `grammar.describe`, `scene.edit`, `patch.preview`, `patch.commit`, `history.undo`, `board.pin`), with the exact geometry, the resource states and the diagnostics the agent is shown, and the revision a task hands in pinned apart from the board. |

Both placements are asserted in `harness_client/test/board_test.dart`
(`a picture and a note are drawn where their words can be read`): the
picture sits clear of the worker pool's card, the note is the size that
holds its wrapped words, the ink does not lie across a note, and every
object's box agrees with its transform.

The Emacs page and the agent's own tools are shown by
`scripts/board-demo.sh`, which draws a board through the tools and
writes its pictures; the design is `docs/design/freeform-agent-board.md`.

The app's own authoring -- a tool, a tap, a drag, a turn, a group, a
connector, a drill-down and a task asked for from the selection -- is
covered by `test/board_test.dart` (`a person builds their own diagram`),
and against a real harness by `test/board_real_harness_test.dart`:

```
harness_client/tool/with_real_harness.sh \
  harness_client/tool/flutter test --no-pub test/board_real_harness_test.dart
```

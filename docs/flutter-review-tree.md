# The files of a review, in a tree

The review's `Files` tab draws the change as a file tree or a flat list
(`harness_client/lib/src/ui/screens/review_screen.dart`). Two things were
wrong with the tree.

- **A file did not go in with its directory.** Every row carries the depth
  it sits at, and a directory row used it, but a file row was drawn from
  the page's left edge whatever its depth. `lib/src/ui/chat_screen.dart`
  looked like a top-level row with its path written under its name, while
  `lib/`, `src/` and `ui/` stepped in above it. The tree said one thing and
  the rows another.
- **The view control drew the view it was on, not the one it gives.** In
  the tree its tooltip was `Flat list` and its icon was the tree's own
  glyph; in the flat list the tooltip was `File tree` and the icon was the
  list's. The label names what a tap gives, so the icon was wrong exactly
  where a person looks for the way to the flat list.

## What the rows do now

A directory and a file take their left inset from one place,
`_treeInset(depth) = gutter + depth * 12`; a flat row is built at depth 0
and so stays at the gutter.

- **A directory row** puts its disclosure arrow at the inset. The folder
  glyph and the name follow it.
- **A file row** puts its status square at the inset. The square is 22
  points wide and is followed by 8 points; a directory's arrow, gap and
  folder are 18, 4 and 17. A file's name therefore lands within 3 points of
  the name of the directory that holds it — close enough that a file reads
  as that directory's child without a guide line between them.
- **The directory path line** under a file's name stays in both views. In
  the flat list it is what makes a bare `widget.dart` findable; in the tree
  it is still the quickest answer to where a file is when its directory has
  scrolled off the top.

The toolbar control now draws the icon of the view a tap gives:
`Icons.view_list_outlined` with `Flat list` while the tree shows, and
`Icons.account_tree_outlined` with `File tree` while the flat list shows.
It is the same rule as the rest of the toolbar, where an icon is the action
and the tooltip is its name.

## Alternatives

- **A chevron-width spacer before the status square** would line a file's
  name up with its sibling directories' names exactly. It would also put
  the file's name 19 points to the right of the name of the directory that
  holds it, which is the relation a tree is meant to show. Rejected.
- **Guide rails** down each level make nesting clearer in a tall tree, but
  add chrome to every row for two levels of nesting on a phone. Not drawn.
- **A selected icon showing the current view** would turn one control into
  a two-state choice and make its tooltip ambiguous; naming and drawing
  the target view is simpler and matches the other toolbar buttons.
- **No path line in tree mode** would make the rows shorter. It would also
  hide the path the moment the tree is scrolled past its directory, so the
  line stays.

## What it gives up

Twelve points a level is width on a 320-point phone: at depth 4 a file's
status square starts at 64 points, so a long name has less room and
ellipsizes sooner. The path line below it and the file page's header still
say the whole path, and the flat list drops the indentation entirely.

## What is checked

- `test/review_screen_test.dart`, "a file sits under the directory that
  holds it, in either view": exact pixel positions from `getTopLeft` for a
  directory name at depth 0 and 1 (12 points apart), a file's status square
  at depth 1 and 4 in the tree (gutter + 12 and gutter + 48), and the same
  files at the gutter in the flat list; plus the tooltip and icon of the
  control in each view.
- The copy test still asserts the exact words, and this change adds none:
  `Flat list`, `File tree`, `N files`, `Skip approved: on` and
  `Skip approved: off` are as they were.
- `test/review_model_test.dart` covers the tree and its flattening; the
  model is unchanged.
- `HARNESS_SHOTS=screenshots flutter test
  test/review_screenshots_test.dart` writes `review-files.png` and
  `review-320-text2.png`; the pictures in `harness_client/screenshots/`
  come from that run.

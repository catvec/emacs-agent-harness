# Folding the workspace computer

## What was wrong

The workspace's computer desk is a side column 330 to 460 points wide
that is always there on an expanded window.  A person who wanted the
chat wider had no way to put it away, and a person who put it away had
no way back.

The desk's `Details` action opened the computer's screen sheet: the
same RFB stream, about 300 points high, with the state and the
footer under it.  The action promised details and delivered a second
copy of the screen.  Nothing on the sheet said what the box was
besides what the desk already said: no backend, no display, no home,
no screen size, no reason a stopped box could not start.

## The decision

The desk folds, and the fold is reversible from where the desk was:

- Its header carries `Hide computer`.  Pressing it removes the screen
  and the desk's footer, and the chat takes the room.
- What remains is a narrow rail: the box's state dot, a `Show computer`
  control, the rail's name, and a `Details` control.  `Show computer`
  puts the desk back with its width, its footer and its screen.
- `Details` opens the computer's facts, not its screen: control,
  backend, isolation, display, screen size, home, profile, disk, the
  desktop (noVNC) URL, the socket, and the reason or missing tools when
  the box is off.  It offers `Take over` / `Return control` and `Start`
  where those apply, and `Resources` leads to the page it always has.
- The phone's computer sheet carries the same `Details` action, so the
  facts are reachable from the one computer surface a phone has.  On
  the phone, opening the details closes the screen sheet first.

The box facts are read from `workspace/box/status`; the model now
keeps `isolation`, `display`, `home`, `profile`, `disk` and `missing`
instead of dropping them at the wire.

## Alternatives

- **A toggle in the app bar.**  The app bar already has a `Computer`
  action that opens the screen sheet, and on a phone it is the only way
  to the screen.  Changing what it means by window width would make one
  control do two things; a rail at the desk's edge keeps the way back
  where the desk was, as a collapsed sidebar does.
- **Details under the screen.**  Keeping the screen in the sheet and
  adding the fact rows under it would still draw the same stream twice
  on a desktop and would leave the sheet mostly screen.  The complaint
  was that `Details` showed the screen; the fix is a sheet about the
  box.
- **Fold only the screen inside the desk.**  The header and footer
  would stay and the chat would gain nothing.  The point of hiding the
  screen is the chat's width.
- **Remember the fold in settings.**  Panel visibility is a momentary
  preference of the workspace screen, not a property of the workspace.
  It lasts while the screen does (the tab is kept alive by the shell's
  `IndexedStack`); it is not written to disk, and no settings page has
  to grow a switch for it.

## Shape of the change

`_WorkspaceScreenState` holds `_deskHidden`.  In the expanded layout it
draws either `_Desk` (with `onHide` and `onOpenDetails`) or
`_DeskRail` (with `onShow` and `onOpenDetails`).  Both read the shared
state words through `_computerStateLabel`, `_computerStateColor` and
`_computerFooter`, so the desk, the rail, the screen sheet and the
details sheet cannot drift.

`_DeskRail` is 56 to 72 points wide, growing a little with the text
scale.  It keeps a state dot coloured like the desk's state word and a
vertical `Computer` label beside the two controls.

`_ComputerDetailsSheet` is a scrollable bottom sheet.  `_DetailRow`
draws one label and value; long paths and endpoints are monospace,
ellipsize at three lines and carry the full value in a tooltip.  The
sheet rebuilds from the controller, so a control change it makes shows
at once.

While the desk is folded the RFB connection is disposed, as it is when
the screen sheet closes; showing the desk connects again.  The stream
costs nothing while hidden, at the price of a reconnect when it comes
back.

## Copy

`Hide computer` and `Show computer` name the two controls, and the
rail's vertical label says `Computer · Live`, `Computer · Starting` or
`Computer · Off` so its state is a word as well as a dot.  The details
sheet's labels are `Control`, `Backend`, `Isolation`, `Display`,
`Screen`, `Home`, `Profile`, `Disk`, `Desktop`, `Socket`, and `Reason`
and `Missing` when they have something to say.  Its values are the
box's own data; `Agent` and `You` are the control values the takeover
pill already uses.  `Details`, `Resources`, `Start`, `Take over` and
`Return control` keep the words they had.

## How it is checked

`test/workspace_screen_test.dart` hides the desk, checks that the
screen is gone and the rail's controls are there, and shows it again.
It opens `Details` from the desk, from the rail and from the phone's
sheet, asserts every row's exact label and value, checks that no
`VncTakeover` is inside the details sheet, takes over from the sheet,
and opens the details at twice the text on a phone.  It also reads a
box status from the wire to prove the new facts survive parsing.
`test/workspace_screenshots_test.dart` writes the desk, the folded rail,
the desktop details and the phone details; those pictures are in
`harness_client/screenshots`.

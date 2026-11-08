# Keys in the Flutter client

The client starts from a phone: a tap sends, the on-screen keyboard writes.
On a desktop or a tablet with a keyboard it can also be driven the way its
Emacs harness is. Three options under **Settings › Keys** decide how much of
that a person gets, and none of them changes what a phone without a keyboard
does.

| Option | Values | Default | What it does |
| --- | --- | --- | --- |
| **Send with** | `Enter`, `C-c C-c` | `Enter` | The key that sends a message. The other key writes a new line. The send button always sends. |
| **Emacs editing** | on, off | off | The message box, and every other text field, edits its words with Emacs's keys. |
| **Harness keys** | on, off | off | `C-c` commands run the app's own functions: send, stop the turn, attach images, search, copy the last reply, jump to the bottom. |

## Why they are separate

- **Send with** is the app's own choice about the message box. It is
  independent of the other two. A person who only wants Emacs's `C-c C-c` to
  send never has to give up `Ctrl+C` for copy anywhere else.
- **Emacs editing** changes how a text field moves, kills and yanks. It does
  not take `C-c` away from the platform: `Ctrl+C` still copies while a
  selection is up and this switch alone is on.
- **Harness keys** takes `C-c` everywhere in a screen as a prefix, as Emacs
  does. That is a real trade: `Ctrl+C` in a text field is no longer copy while
  it is on (a selection can still be copied from the selection toolbar). It is
  off by default for that reason, and the settings row says what it buys.

The combinations are meaningful:

| Send with | Harness keys | `Enter` | `C-c C-c` | `Ctrl+C` in a field |
| --- | --- | --- | --- | --- |
| `Enter` | off | sends | nothing | copy |
| `Enter` | on | sends | sends (the screen's layer) | the `C-c` prefix |
| `C-c C-c` | off | a new line | sends (the box answers it) | the `C-c` prefix while the box has focus |
| `C-c C-c` | on | a new line | sends (the screen's layer) | the `C-c` prefix |

## The Emacs editing keys

They are the keys of a plain Emacs buffer, not of a programming mode: motion,
killing and yanking. A mark of the field's own (`C-space`) makes the movement
keys select; the kill ring is shared by the app's fields, so a line killed in
one can be yanked into another. It lives for the run of the app and is never
written to the device.

| Key | What it does | Key | What it does |
| --- | --- | --- | --- |
| `C-a` | beginning of line | `C-e` | end of line |
| `C-f` | forward a character | `C-b` | backward a character |
| `C-n` | next line | `C-p` | previous line |
| `M-f` | forward a word | `M-b` | backward a word |
| `M-<` | beginning of the field | `M->` | end of the field |
| `C-k` | kill to the end of the line | `C-y` | yank the last kill |
| `C-w` | kill the region | `M-w` | copy the region |
| `M-d` | kill the next word | `M-Backspace` | kill the previous word |
| `C-d` | delete the next character | `M-y` | yank the kill before the last |
| `C-t` | transpose two characters | `C-o` | open a line |
| `C-space` | set the mark | `C-g` | drop the mark and the selection |

The rest of the field is untouched: `Ctrl+Z` still undoes, `Ctrl+C` still
copies (unless **Harness keys** is on), and typing still uses the platform's
input method. On macOS, Alt is the Option key and `M-<`/`M->` follow the
keyboard layout, as they do in Emacs on that machine. On a phone's on-screen
keyboard no key event is sent, so nothing here happens; a hardware keyboard
attached to a phone or tablet sends the same events as a desktop's.

## The harness keys

They are the harness chat's own bindings, for the functions the Flutter client
has. The prefix is `C-c`; the command key has Control.

| Key | The harness function | Where |
| --- | --- | --- |
| `C-c C-c` | send the message | a conversation, the workspace |
| `C-c C-k` | stop the running turn | a conversation, the workspace |
| `C-c C-a` | attach images | a conversation that takes images |
| `C-c C-s` | open the quick search | every screen of the shell, and a conversation |
| `C-c C-w` | copy the agent's last reply | a conversation, the workspace |
| `C-c C-e` | jump to the end of the conversation | a conversation, the workspace |

The chat's other Emacs bindings have no function here yet, so they are not
bound: queue a message for the next turn (`C-c C-q`), show or hide the todos
(`C-c C-t`), show the earlier recaps (`C-c C-j`), go up to the parent session
(`C-c C-u`), redraw (`C-c C-r`), the overflow list (`C-c C-o`), and burying
the view (`C-c C-z`). A key after `C-c` that no screen binds is consumed
without doing anything, as Emacs's beep is: it never types itself into the
text.

## Where the keys live

- A screen that has harness commands wraps its page in a `HarnessKeyLayer`
  (`lib/src/ui/harness_keys.dart`). The layer is a non-focusable `Focus` in the
  widget tree: key events from any focus inside the screen — the message box
  included — pass through it, and a screen that is not in front, or whose
  focus is elsewhere, never hears the keys.
- `EmacsEditing` (`lib/src/ui/emacs_keys.dart`) is held by each
  `HarnessTextField`, so the mark and the last yank belong to the field while
  the kill ring is the app's.
- `SettingsController` keeps the three choices in `SharedPreferences`
  (`sendKey`, `emacsEditing`, `harnessKeys`), and a damaged stored value falls
  back to its default without disturbing the others.
- The keys require a platform with a Control key (`kIsWeb`, macOS, Linux,
  Windows), by the same rule the message box already used for Enter-to-send.
  The layer and the box leave every key alone on a phone.

## Alternatives considered

- **Always-on `C-c` prefix.** It would take `Ctrl+C` from every text field on
  a desktop, including for people who never asked for Emacs keys. The harness
  keys are a switch for that reason.
- **One switch for editing and commands.** Simpler to describe, but it would
  force a person who wants `C-k`/`C-y` to lose copy as well. The two needs are
  separate, so the two switches are.
- **Handling keys at the browser or OS level.** Flutter exposes the key
  events through its focus tree; a platform-wide shortcut would also fire over
  dialogs and other apps, and would not exist on the web.
- **A full Emacs keymap, C-x and M-x included.** The client has no minibuffer,
  buffers or commands to name, and `C-x C-c` would quit a conversation, not
  the app. The set here is the editing and harness functions the app actually
  has.

## Tests

`harness_client/test/keyboard_test.dart` drives real key events through the
widget tree: Enter and `C-c C-c` send (and the settings' exact hint copy),
movement by character, word and line, a kill and a yank, a mark with `C-w`, a
field with the editing keys off, a layer on and off, and a conversation on the
fake harness where `C-c C-c` reaches `session/prompt`, `C-c C-s` opens the
quick search and `C-c C-w` reports the copy. The settings' exact copy is
asserted too (the `KEYS` header, the three names and their lines, and both
segments), and the section is drawn on a phone at one and a half times the
text size to prove it fits. `settings_controller_test.dart` checks the
defaults, the stored values, a damaged value, and that the next run of the app
starts from the choices. `keyboard_screenshots_test.dart` writes the two
pictures the README shows, of the Keys section and of the box set to `C-c C-c`.

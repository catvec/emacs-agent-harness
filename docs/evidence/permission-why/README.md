# Permission prompts say why: the pictures

Every permission prompt now says why it is put to the user.  The one
reason that is a safety judgment -- the auto-mode judge weighed the call
and would deny it -- says so in the caution face; a judge that gave no
verdict says that instead, and nothing on it claims the call was judged.

| File | What it shows |
| --- | --- |
| `chat-permission-denied.png` | The Emacs chat of `scripts/media.sh chat-permission` with the judge denying the `pip install`: `Why · Safety check · denied by the permission judge` in the caution face, the judge's words under it, the panel's old `:reason` line and the model summary below, the five answers unchanged |
| `popout-permission-denied.png` | The same request in the session list's popout, where the same line and detail are drawn |
| `permission-why-unsafe.png` | The Flutter card on a phone: the amber `Why` note with the warning icon above the call's arguments, and Allow/Deny as they were |
| `permission-why-no-verdict.png` | The same card for a judge that timed out: a neutral note with the info icon, `No safety verdict · judge timeout`, not amber |
| `permission-why-unsafe-ios.png` | The unsafe note in the iPhone style |

The Emacs pictures are `scripts/media.sh chat-permission popout-permission`
run from a checkout whose scripted judge denies that one call, with the
judge's reason as the demo's: the harness, the panel and the faces are
this branch's, and the media world is otherwise as `docs/screenshots.md`
describes it.  `docs/media/` keeps the pictures the README shows, whose
judge allows the call, so the line there reads `Why · Permission mode` or
the like; these are kept apart from that gallery as the evidence for this
change.

The Flutter pictures are `HARNESS_SHOTS=<dir> flutter test
test/permission_why_screenshots_test.dart`, the app's own screenshot
harness, and they draw the app as it is committed.

# Tests that read the clock, and tests that read a directory

Two suites failed on and off for weeks and were each called a flake. Neither
was a flake in the sense of the code sometimes doing the wrong thing: in both
the production code did what it documents, and the test asserted something that
is only true *sometimes* -- at certain hours, on certain filesystems. This note
records what each one really depended on, what changed, and why the change is in
the test (or in the walk) rather than in an assertion loosened to fit.

## 1. The pinned clock line (`lisp/ui/harness-ui-chat-test.el`)

### What the code guarantees

The chat shows times two ways, deliberately (see `docs/design/chat-timestamps.md`):

- **Sender lines** carry `harness-chat--time-label`: `%H:%M` today,
  `%b %-d %H:%M` another day of this year, `%Y-%m-%d %H:%M` another year.
- **The pinned line under the header**, and `harness-chat--time-line` that
  draws it, carry `harness-chat--time-clock`: `%H:%M`, never a date. The date
  lives in that line's tooltip.

That split was a user decision from the timestamps task: the header area stays
date-free.

### What the tests assumed

`pin-the-time-of-the-first-message-seen` and
`a-run-of-calls-keeps-its-first-time` both build their fixture from
`(float-time)`, put the message 1800 seconds back, and then searched the
**pinned line** for the **dated label**:

```elisp
(should (string-search (harness-chat--time-label t1)
                       (harness-ui-chat-test-time-bar)))
```

`time-label` equals `time-clock` exactly while `t1` falls on today's local
date. With `t1 = now - 1800`, that holds everywhere except the thirty minutes
after local midnight -- where `t1` is yesterday, the label grows a `Nov 13`
prefix, and the search finds nothing. The header assertions had the mirror
problem: they asserted the dated label was *absent* from the header, which was
vacuously true at that hour for the wrong reason.

The reported failure ended `2026-11-11 00:18:43 -0500`. Eighteen minutes after
midnight: the one window in which this test cannot pass.

### The change

- Every assertion about the pinned line or `harness-chat--time-line` now asks
  for `harness-chat--time-clock`; assertions about sender lines keep
  `harness-chat--time-label`. Each check now means what it says at any hour.
- New test `harness-ui-chat-timestamps-the-pinned-line-is-the-clock-alone`
  pins both times **fixed**: one in 2020, one on the day before, so the two
  readings always differ. It asserts the sender line carries the date, the
  pinned line carries the clock and *not* the date, and the tooltip carries
  the whole time.

No production code changed. `harness-chat--time-clock` is the existing helper;
nothing was added to make a test pass.

### Verification

At 00:10 local (`set-time-zone-rule`, `float-time` untouched):

| tree | result |
| --- | --- |
| `HEAD` before this branch | 282 tests, **2 unexpected** -- exactly the two named |
| this branch | 283 tests, **0 unexpected** |

The new test was also checked against a deliberately broken `--time-line` that
draws the dated label: it fails, and so does nothing else, so it guards the
rule and not an accident of the fixture.

## 2. A skill's file listing (`lisp/harness-skills-scan.el`)

### What the code guarantees

`harness-skills-scan-files` returns the supporting files of a skill directory,
sorted, bounded in number and bytes. The fingerprint of a skill hashes that
list, so two machines can compare two copies of one skill by fingerprint.

### What it did

The walk read each directory with `directory-files ... NOSORT` -- whatever order
the filesystem returned -- and stopped at the bound in that order. So *which*
files survived `harness-skills-scan-max-files` was arbitrary. On this machine's
tmpfs the order puts `SKILL.md` in the middle of the listing and the kept three
come out `file-0 file-2 file-3`; on a machine that lists names in order they
come out `file-0 file-1 file-2`.

Two consequences, one visible and one worse:

- The test asserting the first three names failed where the order differed.
  Commit `76aaf47` had fixed the *counting* bug in the same test (the skill's
  own `SKILL.md` took a place of the bound) and tightened it to assert exact
  names -- which is correct, but exposed this second dependency.
- Two copies of one skill with identical bytes could fingerprint differently,
  which defeats the point of the fingerprint.

### The change

The walk sorts each directory's listing by name before applying the bound, so a
bound always keeps the same first names. New test
`harness-skills-scan-the-bound-keeps-the-first-names-in-order` pins the
contract and fails against the unsorted walk.

This one is a production change, not a test change: the arbitrary subset was a
real defect in what the module promises, and the test was right to demand
better.

### Verification

| tree | result |
| --- | --- |
| unsorted walk | 11 tests, **2 unexpected** -- `bounds-what-it-lists` and the new one |
| sorted walk | 11 tests, **0 unexpected** |

## Why not loosen the assertions

The tempting fix for both is to accept either reading (`time-label` or
`time-clock`; any three files). That would delete the guarantee the test exists
to state: that the header area carries no date, and that a fingerprint is a
function of a skill's bytes. A test that passes at any hour by not checking
anything is the flake, written down.

## Full suite

`scripts/test.sh` on `3b16000`, clean tree: **218 suites, 0 failed, exit 0**;
`scripts/test.sh --status` reports **PASS (full, 218 suites, 0 failed)**.
`scripts/lint.sh` exits 0 with no warning in either changed file.

One unrelated flake was seen while verifying and is *not* fixed here:
`harness-http-download-saves-the-body-and-reports-progress` failed once under
the full run's parallel load (a progress report arrived before `Content-Length`
was known, so one entry carried no total) and passes in isolation on both this
branch and its base. It is recorded, not relabelled.


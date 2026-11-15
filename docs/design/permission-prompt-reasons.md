# A permission prompt says why it is asked

## The failure

A permission dialog said `Permission` and the call, and nothing else. The
person reading it could not tell a call the auto-mode judge had weighed
and found dangerous from one that simply met an `ask` mode, or from a
call that reached a directory outside the allowed ones. Every prompt
looked the same, so the one prompt that deserved a warning -- the judge
said this call is unsafe -- looked exactly like the ordinary ones.

The cost is not cosmetic. A person who cannot tell a safety objection
from a routine ask either approves everything (the warning is worthless)
or denies everything (the mode stops meaning anything). The judge's
objection already reached the panel as a `:reason` line -- "The permission
judge would deny this call: it force pushes to the shared remote" -- but
that line was a sentence in the panel's prose, not a stated verdict, and
nothing said the same thing to the Flutter client, which drew the
`_harness.reason` string among the paths and the working directory.

## What the change decides

### 1. One reason per prompt, in a shape a client can read

Every prompt carries `:why`, a plist:

```elisp
(:code judge-deny
 :label "Safety check · denied by the permission judge"
 :unsafe t
 :detail "it force pushes to the shared remote")
```

- `:code` is a symbol from `harness-perms--why-codes`, the machine's name
  for the reason. A client that writes its own words reads this.
- `:label` is the harness's words, a noun phrase, for a client that shows
  the harness's. Both UIs show it.
- `:unsafe` is true for **one** code: `judge-deny`. It is the only reason
  that is a judgment on the call itself. A client must not infer it from
  anything else, and the harness never sets it for anything else.
- `:detail` is the words behind the reason -- the judge's own, the
  harness's phrase about where a path lies -- masked of secrets
  (`harness-secrets-mask-text`, when the secrets module is loaded) and cut
  to `harness-perms--why-detail-chars`. Never the call's arguments: the
  prompt already shows those, and repeating them is the one thing that
  would make the line a second copy of a command that may hold a
  credential.

### 2. The codes, and what each claims

| Code | When | Unsafe | Says |
|---|---|---|---|
| `judge-deny` | The judge weighed the call and would deny it, and the user is present to overrule | **yes** | Safety check · denied by the permission judge |
| `judge-timeout` | The judge took longer than `harness-perms--auto-timeout` | no | No safety verdict · judge timeout |
| `judge-unavailable` | No provider could be asked at all | no | No safety verdict · judge unavailable |
| `judge-unreadable` | The reply held no verdict the strict reader takes | no | No safety verdict · unreadable judge reply |
| `judge-failed` | The request failed (transport, encoding, provider error) | no | No safety verdict · failed judge call |
| `judge-empty` | The judge replied nothing | no | No safety verdict · empty judge reply |
| `judge-stopped` | The judge ended for any reason but the end of its turn | no | No safety verdict · incomplete judge reply |
| `judge-asked` | The judge said `{"decision":"ask"}` | no | No safety verdict · judge abstention |
| `mode` | The permission mode asks; nothing weighed the call | no | Permission mode |
| `access` | A path outside the allowed directories, or an agent's own request for a directory | no | Directory access |
| `confirm` | A call only the user may confirm (`harness-perms-confirm`) | no | Confirmation · yours alone |
| `away` | An agent asks to turn non-interactive mode on | no | Non-interactive mode · yours to turn on |

The seven `judge-*` codes that are not `judge-deny` are the ones this
change exists for as much as the denial is: a judge that timed out, failed
or answered unreadably **made no judgment on the call**, and the prompt
says so. Before, a prompt caused by a malformed reply and a prompt caused
by a mode were indistinguishable, and both read as if something might be
wrong with the call.

### 3. Where the reason comes from

`harness-perms--auto` already recorded `:no-verdict` (the words) when it
gave none. It now records `:no-verdict-code` beside it -- `judge-timeout`
from the timer, `judge-failed`/`judge-stopped`/`judge-empty`/
`judge-unreadable` from `harness-perms--judge-failure-code` on the `done`
event, `judge-asked` when the reader saw an explicit ask -- and
`:no-verdict-detail` for the reader's own phrase when it differs from the
denial's.

`harness-perms--judge-decision` puts `:why (harness-perms--why
'judge-deny ...)` on the ask it makes of an interactive judge denial, so the
unsafe flag is set where the judgment is made, not inferred later.

`harness-perms--why-of DECISION FALLBACK` is what a prompt calls: the
decision's own `:why` if it has one, else `:judge-deny` -> `judge-deny`,
else `:no-verdict-code` -> that code, else the stage's fallback (`mode`,
`access`, `confirm`, `away`).

### 4. The prompt is the same prompt after a reconnect

The reason rides in the pending request's payload, so:

- `session/pending-add` keeps it in the session record;
- `harness-acp--on-permission-requested` sends it as `_harness.why`;
- `permission/pending` (the fallback for a harness without the session
  module) reads it from the waiting table, which is why each prompt's
  waiting entry keeps `:why` too;
- the Flutter client's `_syntheticPermission`, which builds a request from
  the pending list a reconnect recovered, maps `payload['why']` into
  `_harness.why`.

So a live request and the same request recovered after a dropped
connection carry the same reason, code and detail -- there is no second
place the reason is computed.

### 5. What the panels draw

Emacs (`harness-ui-pending.el`): a `Why · <label>` line under the facts
and above the call's input, the detail under it in the dim face. A safety
judgment wears `harness-ui-pending-why-unsafe-face` (inheriting the
caution face) and its tooltip says the judge weighed the call and the
person decides; every other reason wears `harness-ui-pending-why-face`
and its tooltip says no safety judgment was made. A request
that carries no `:why` -- from a harness that sends none -- draws exactly
as it did, with no line.

Flutter (`interaction_card.dart`): a `_WhyNote` card at the top of the
permission body, keyed `permission-why`, amber and warning-iconed when
unsafe, neutral and info-iconed otherwise, with the label and the detail.
Its semantics label carries the same words for a screen reader.

The words are interface copy, so they are noun phrases and adjectives,
never sentences (`CLAUDE.md`): `No safety verdict · judge timeout`, not
"the judge timed out"; `Confirmation · yours alone`, not "only you
answer this".  The one place a clause would be natural -- the tooltip --
says what the line is in the same register: `Why · safety judgment · the
auto-mode judge would deny this call · unsafe · your decision`.  A client
that draws its own words reads `:code` and is not bound by these.

### 6. What does not change

- Approval and denial semantics: the same five options, the same keys,
  the same scopes, the same rules recorded. Nothing reads `:why` to
  decide anything.
- The fail-closed chain: a malformed reply still never allows a call, a
  timeout still asks the user (or denies, when they are away), and the
  correction retry is untouched.
- The `:reason` lines the prompts already had, and every reader of them.
- The redaction rules: a reason is masked where it is made, and no
  argument is copied into it.

## Alternatives considered

- **Only the judge's denial gets a reason.** Half the problem: the person
  still cannot tell an ordinary ask from a missing verdict, and the
  Flutter card still shows nothing.
- **Reuse `:reason` as the reason line.** `:reason` is prose for a person
  and is absent for a mode prompt; a client cannot tell "the judge
  objected" from "the agent asked" by reading it, and a stage that wrote
  no reason would show nothing rather than "the mode asked".
- **A boolean `:unsafe` alone.** Says nothing about *why*, and invites a
  client to render "unsafe" for a timeout because the flag was missing
  rather than false. The code plus the flag makes the distinction
  explicit at the wire.
- **Put the call's arguments in `:detail`.** The panel already shows
  them, and copying them into a second place doubles the chance a
  credential reaches a screen.
- **Derive the reason in each UI from the fields it has.** Two places to
  get it wrong, and the Flutter client has none of the stage names.
- **Say "unsafe" for a judge that gave no verdict.** Exactly the thing
  this must not do: no judgment was made, and implying one is a lie the
  person would act on.

## The shape of the change

- `lisp/modules/harness-perms.el`: `harness-perms--why-codes`,
  `--why-labels`, `--why-detail-chars`, `--why-label`, `--why-detail`,
  `--why`, `--why-of`, `--judge-failure-code` (new); `--auto` (codes with
  the no-verdict), `--judge-decision` (the unsafe reason), `--unapproved`
  (keeps the code), `--ask`, `--pend-dir`, `--away-request`,
  `harness-perms-confirm` (the payload's `:why`), `permission/pending`
  (the fallback's).
- `lisp/modules/harness-acp.el`: `_harness.why` on the request, and the
  contract in the handler's docstring.
- `lisp/ui/harness-ui-pending.el`: the record's `:why`,
  `harness-ui-pending-why-face`, `--why-unsafe-face`, `--why-label`,
  `--why`, `--why-unsafe-p`, `--why-help`, `--insert-why` (new), and the
  panel drawing it.
- `harness_client/lib/src/state/interaction.dart`: `PermissionWhy` and
  `InteractionRequest.why`.
- `harness_client/lib/src/state/session_controller.dart`: the synthetic
  request carries `why`.
- `harness_client/lib/src/ui/widgets/interaction_card.dart`: `_WhyNote`.

## What the tests hold

In `lisp/modules/harness-perms-test.el`:

| Test | What it pins down |
|---|---|
| `a-prompt-says-the-judge-found-the-call-unsafe` | `judge-deny`, unsafe, the judge's words, the old `:reason` intact |
| `a-prompt-the-mode-asks-is-no-safety-judgment` | `mode`, not unsafe, no detail |
| `a-directory-prompt-says-access-not-safety` | `access` for the jail and for the agent's request, with the phrase |
| `a-malformed-reply-says-the-reply-was-unreadable` | `judge-unreadable`, two calls, still not run |
| `a-judge-timeout-says-no-verdict-not-unsafe` | `judge-timeout`, the wait, the call cancelled |
| `a-failed-judge-call-says-it-failed` | `judge-failed`, the provider's error in the detail |
| `a-judge-that-asked-for-the-user-says-no-verdict` | `judge-asked`, one call, not corrected |
| `a-reason-is-masked-and-cut` | a Stripe-shaped value becomes its placeholder; the detail is cut |
| `a-reason-is-told-apart-from-the-call` | every code's label and unsafe flag |
| `a-decision-names-the-reason-it-was-asked-for` | `--why-of` precedence: own, judge-deny, no-verdict, fallback |
| `a-recovered-prompt-says-the-same-why` | the pending payload and `permission/pending` carry the same reason |

In `lisp/modules/harness-acp-test.el`:
`local-permission-request-carries-its-reason` -- the wire's `_harness.why`,
a code as its name, an unsafe denial, a mode, and a request with none.

In `lisp/ui/harness-ui-pending-test.el`:
`panel-says-why-a-safety-judgment-was-made` (the exact line, the face, the
tooltip), `panel-says-why-with-no-safety-judgment` (three reasons, none
unsafe, the faces), `panel-without-a-reason-is-as-it-was`, and
`reason-survives-the-news-of-a-summary`.

In `harness_client/test/permission_why_test.dart`: the model reads
`_harness.why`, the synthetic request keeps it across a reconnect, and the
card renders the unsafe and the ordinary reason, with the exact copy.

`harness_client/test/permission_why_screenshots_test.dart` draws the card
on a phone for each of the two, which is where the pictures in
`docs/evidence/permission-why/` come from.

The panel's two tooltips are asserted whole, not by the words inside
them: a sentence creeping back into the copy fails the suite rather than
passing a substring search.

## What you can watch

`demo/permission-why/demo.sh` draws the line the panel draws, offline, for
every code: the words, the face and the tooltip of each, the one safety
judgment beside the reasons that are none, and where each reason comes
from (`harness-perms--why-of` on the chain's own decisions). It sends no
model request and runs no tool.

`docs/evidence/permission-why/` keeps the pictures: the Emacs chat and the
session list's popout with a prompt the judge would deny, and the Flutter
card on a phone for that prompt and for one whose judge timed out. The
Flutter pictures come from `harness_client/test/permission_why_screenshots_test.dart`,
the app's own screenshot harness, so they cannot drift from what it draws.

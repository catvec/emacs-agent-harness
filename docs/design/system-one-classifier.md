# A local reflex in front of the permission judge

## The problem

Every call the permission chain cannot settle from its rules is put to a
model (`harness-perms--auto`): a cheap one, one call at a time, with no
memory of the turn. It takes a few hundred milliseconds to a few
seconds, and it is asked about ordinary work — `git status`, a
`read_file` of a file the session already read — as often as about the
hard calls it is really for.

Most of those calls are not hard. A reflex that reads them the way a
person reads a familiar command would take almost all of them off the
judge's desk, if it were fast, local, and honest about what it does not
know.

## What decides

Two settings, not one, because the two mistakes cost differently:

- a wrong **allow** runs the call; it is the failure the permission
  chain exists to prevent;
- a wrong **deny** stops work the user asked for; it is annoying, and a
  session that keeps being stopped is one the user turns off.

One threshold cannot be both. So `harness-system-one-trust` (0.95 by
default) is read at both ends: at or above it the call is allowed, at or
below one minus it the call is denied, and between them the reflex says
nothing and the chain goes on to the judge and the user exactly as it
would have. On the held-out data that decides 17% of calls, and the one
it gets wrong is a good call stopped — never harm let through.

The model answers one number, not an `allow` bool: a bool cannot say how
sure it is, and the threshold is the whole design. The plugin turns that
number into the three-way reading.

## Why the answer is about one call, with the turn before it

The decision is about the call being run, so the window ends at it, and
the calls before it are context: the same `rm -rf build/` is ordinary
after a build and destructive after a checkout. `schema.render_decision`
writes the task, the earlier calls, and then the call to decide, set
apart — a window of five equal calls teaches a model to average them,
which is what the first attempt did.

The experiment (see `scripts/system-one/MODEL_CARD.md`) says the context
does not pay for itself: AUC is 0.930 at one call, 0.906 at two, 0.909 at
three and 0.856 at five. The module therefore reads one call by default,
and `harness-system-one-window` is there for whoever measures otherwise.

## What it reads, and the one misreading that would matter

The text is the training data's shape: a `Task:` line, the earlier calls
of the turn, then `Call to decide:` and the call. `schema.render_call`
wrote it as `tool(key=value ...)`, and the module renders it the same
way, in the order the input holds its keys.

A call whose input is not a keyword plist — an alist, a nested list, a
bare string — is rendered whole as `tool(input=...)`, never dropped.
This is not tidiness: a call printed as `bash()` when it does carry a
command reads to the model as a call with nothing to run, which is the
one misreading that turns harm into safe-looking work. A call with no
arguments at all is still `bash()`, which is what it is.

## Where it sits in the chain

A `permission/decide` filter at priority 25, between the mode stage (20),
which has already allowed what the mode allows, and the judge (30). So
the reflex sees exactly the calls that would otherwise cost a model
call, and nothing it decides can override a standing rule or the jail.
It runs only on a call whose decision is still `ask`, and passes every
other decision through untouched.

The chain runs **once**, whichever of the two answers first: the model,
or a timer that gives up on it. A late answer after the timer fired is
dropped.

## The model and its process

`sentence-transformers/all-MiniLM-L6-v2`, 22.7M parameters, chosen on
this machine's numbers: 23.7 ms per 256-token window against 72.9 ms for
distilbert-base and 224.9 ms for ModernBERT-base. It is a plain
`AutoModelForSequenceClassification` with one logit, which is the
best-documented fine-tuning path there is.

Loading it takes about a second, which a reflex cannot pay per call, so
`predict.py` is a JSON-lines server the module keeps warm and restarts
when it dies. A call that waits longer than
`harness-system-one-timeout` goes on undecided. With no model on the
machine the stage does nothing at all: the harness works as it did, and
`harness-system-one-status` says what is missing.

## The alternatives, and why not

- **A generative model with a prompt** (Qwen3-0.6B, SmolLM2): it can
  explain itself, but it generates tokens, and a generation per
  permission decision is hundreds of milliseconds on CPU at best. The
  reflex needs a forward pass, not a paragraph.
- **A bigger encoder** (ModernBERT-base, distilbert-base): both scored
  fine in training, both cost 3–10× the latency for a window this
  short.
- **A rule list**: it is what the chain already has, and the reason the
  judge exists is that the interesting calls do not fit one.
- **Asking the judge with a shorter prompt**: cheaper, not faster. The
  latency is the round trip, not the tokens.

## What is committed, and what is not

The workflows, the windows, the evaluation report, the ablation and the
model card are in `scripts/system-one/data/`; the training and serving
code is beside them. The weights (88 MB) are not: `train.py` writes them
to the directory `harness-system-one-model-directory` names, and the
model card has the command.

## Turning it on

The module is `system-one` in `lisp/modules/`, so a session enables it by
naming it in `harness-enabled-modules`. `.harness/plugins/system-one/`
is the project plugin that requires it, for a project whose
`.dir-locals.el` names it; this repository does not, so the reflex is
off here until someone asks for it.

Off is the deliberate default for the deciding stage. At trust 0.95 it
settles about a sixth of the calls it sees, and every one it gets wrong
on the held-out data is a good call stopped — a small number, but a
denial ends a turn's work, and a classifier that silently denies one
call in a hundred is something a user should turn on rather than find
on. The tool `system_one_classify` reads a call without deciding
anything, so it can be tried before the stage is enabled.

The numbers in `data/report.json` are the ones to read first: at trust
0.5 the reflex decides everything and is wrong about one call in five;
at 0.95 it decides a sixth and lets no harm through on the held-out
data. `harness-system-one-trust` is the dial, and it is read at both
ends.

## Failure modes

- **A predictor that dies**: the next call starts a new one; the call in
  flight goes undecided.
- **A slow predictor**: the timer fires, the call goes to the judge, and
  the late answer is dropped.
- **A model that reads a call wrong with confidence**: this is the one
  that matters. The trust threshold is where it is paid for, and the
  `by` field of every decision names `system-one`, so a session's
  decisions can be audited against the judge's.
- **A distribution shift** (a tool the model never saw): the model
  should be unsure, and the threshold then sends the call on. It is not
  guaranteed to be; the ablation in the model card is the check that it
  is reading the calls rather than the task.

# Task for the config-doom project: move the OpenRouter narrowing onto the endpoint

**Status: written down, not submitted.** `task_submit` with
`cwd: ~/.config/doom` is refused to this session: the task board resolves
a project from the submission's directory, and that directory is outside
this session's allowed roots. Reading the project's board is allowed;
submitting to it is not. The session is non-interactive, so nobody can
grant the directory. This file is the task, ready to be submitted by a
session that may reach `~/.config/doom/`.

The reason a session cannot file work into another project at all is
filed as task **t-gdhczfl7**, *Allow cross-project task submission*:
`task_submit` takes a project directory, the user answers for it once,
and a session's own roots are unchanged by it. Once that lands, this file
can be submitted with `project: "/home/noah/.config/doom"` from here.

Submit it with:

```
task_submit(cwd: "/home/noah/.config/doom", prompt: <the section below>)
```

---

## Prompt

Move this file's OpenRouter model narrowing from the harness-wide
`harness-allowed-models` onto the OpenRouter endpoint's own
`:allow-models`, and record why the agent that added the key would not
edit it.

### What changed in the harness

The harness now takes an optional `:allow-models` key on an endpoint
definition, taking the same glob patterns `harness-allowed-models` takes
(`*` for any run of characters, `?` for one; a pattern with a colon
matches the whole `provider:model` id, one without names providers).
Core does the filtering where a provider's models are settled, so the
model picker, `provider/models`, tier selection, cost estimates and
price ranking all see one narrowed set, and a request for an excluded
model is refused before it is sent.

It narrows that one provider only. It never widens
`harness-allowed-models`, and both still apply: a model must pass both.

In the harness repository, `docs/design/provider-model-allowlist.md` is
the design page, `docs/model-selection.md` has the short version, and
`demo/allow-models/demo.sh` runs the whole thing offline.

### What this file should say

Today the routing example here constrains the models it will send to with
`harness-allowed-models`, which applies to every provider at once — so a
list meant for one OpenRouter model also constrains Claude Code, Bedrock,
DeepSeek, the local server and everything else.

That narrowing belongs on the OpenRouter endpoint instead. In the
`harness-openai-endpoints` entry for `openrouter` (this file's own
configuration; the OpenRouter module reads the entry for its URL, key and
headers), add:

```elisp
:allow-models '("openrouter:deepseek/deepseek-v4.1-flash-1017")
```

and drop the OpenRouter entries from `harness-allowed-models`, leaving
that global list for what the whole harness may use. A pattern can be a
family instead, `("openrouter:deepseek/*")`, or several patterns in one
list.

Keep every other value exactly as it is. Do not enable
`harness-openrouter-routing`, do not uncomment a policy, do not change
credentials, API keys or account settings, and do not raise or lower a
price ceiling. This is a narrowing of what is offered, not an
activation.

Two things that are easy to get wrong, from the harness's side:

- An empty list is **not** "offer nothing" — it is the same as absent,
  and offers every model the endpoint lists. A list that matches nothing
  is what offers nothing, and the harness logs once which pattern did it.
- The ceilings in the existing routing comment are DeepSeek's off-peak
  token rates (prompt 0.15, completion 0.60, cache-read 0.003 USD per
  million), and that correspondence plus its source URL belongs in the
  comment right there. Do not move those figures or that citation into
  the harness repository, and do not restate them in a harness doc.

### Why the harness agent did not edit this file

The agent that added `:allow-models` to the harness would not change
`~/.config/doom/`: it is outside that session's allowed directories, and
reading or writing it was refused there. That boundary is the right one.
This is a personal Doom configuration, not the harness repository, and a
change to it should be reviewed on its own terms rather than arrive as a
side effect of a harness task. So this task is the record of the change
and of the refusal, and it is for a session that is allowed to make it.

### How to check it

After the change, with the harness loaded, `M-x customize-option RET
harness-openai-endpoints` shows the `openrouter` entry with an `Allowed
models` list holding the patterns, and a model picker lists only the
OpenRouter models those patterns match. A request for an OpenRouter model
left out is refused with a message naming the setting and its patterns,
before anything is sent.

# Optional-field boundary audit (2026-10-27)

## Result

Two integration issues are addressed without changing tool authorization or
silently treating empty strings as omitted fields:

1. **Responses did not specify function-tool strictness.** Its serialized
   `additional_tools` item preserved the source schema's optional properties,
   but omitted `strict`. The adapter now sends **`"strict": false`** on each
   function, preserving the non-strict contract expected by the handlers.
2. **`session_settings` advertised inputs that are never accepted.** Removed
   `permission_mode`, `non_interactive`, `allowed_dirs`, `directory`, and `host`
   from its schema's properties. The description still directs callers to the
   correct tools, and all refusal checks remain intact, including on reads and
   for empty/null values.

There is no blank-string coercion, permission bypass, screenshot enforcement,
or summary-length rule in these changes.

## Evidence and attribution

The [earlier research](harness:session/a0510ccd-73dc-4805-b036-4aebe34536ac)
identified overfilled argument objects, but did not capture the historical
requests. This audit uses the actual registered tool specs and adapter
functions, then JSON-serializes and parses them. It uses **synthetic requests,
not authenticated provider traffic**. Source schemas and emitted JSON agree:

| Boundary | `spawn_agent.required` | `session_settings.required` | Optional fields locally expanded? |
| --- | --- | --- | --- |
| Registered tools / public specs | `["prompt"]` | `["action"]` | No |
| Responses `input[0].tools[*].parameters` | `["prompt"]` | `["action"]` | No |
| OpenAI-compatible `tools[*].function.parameters` | `["prompt"]` | `["action"]` | No |
| Claude MCP `inputSchema` | `["prompt"]` | `["action"]` | No |

The Responses before/after delta is:

```json
// Before, representative function envelope:
{"type":"function","name":"spawn_agent","parameters":{"required":["prompt"],"properties":{"prompt":{"type":"string"},"model":{"type":"string"}}}}
// After (other description/property details omitted only in this excerpt):
{"type":"function","name":"spawn_agent","strict":false,"parameters":{"required":["prompt"],"properties":{"prompt":{"type":"string"},"model":{"type":"string"}}}}
```

The [official OpenAI function-calling guide](https://developers.openai.com/api/docs/guides/function-calling#strict-mode),
retrieved 2026-10-27, supplies an important missing mechanism:

> If you omit `strict`, the default depends on the API: Responses requests will
> attempt to normalize your schema into strict mode when possible, and will fall
> back to non-strict, best-effort function calling if the schema cannot be made
> compatible with strict mode. … Chat Completions requests remain non-strict by
> default. To opt out of strict mode in Responses and keep non-strict,
> best-effort function calling, explicitly set `strict: false`.

The same section says strict mode requires all properties to be required, with
nullable types for optional values. This is a documented provider-side
transformation consistent with the all-required declarations observed in the
research sessions. It is stronger evidence than attributing those declarations
to model behavior alone. It is **not a historical wire capture or direct
observation of the special ChatGPT `additional_tools` route's internal
normalization**. This audit alone cannot establish that this mechanism caused
every historical call. Route acceptance and live A/B results belong to the
parent task's integration/comparison report; these local tests do not claim
that live validation happened. The parent subsequently reported that the
isolated instance had no signed-in ChatGPT account and no OpenAI API key, so
live acceptance and omitted-versus-false A/B validation on this special route
were unavailable. Comparisons through a common OpenRouter adapter, if run,
do not validate the ChatGPT Responses route.

## Argument boundary

The Responses and OpenAI-compatible parsers both call `harness-json-parse`;
neither adds missing optional keys. The Responses stream's emitted tool-call
input is the parsed object too. The tool runner takes the call's input and
passes it to the handler after permission processing (which can intentionally
supply a replacement input); there is no schema-default expansion here.

The synthetic reproductions establish these distinctions:

| Raw JSON input | Parsed/handler consequence |
| --- | --- |
| `{"prompt":"synthetic"}` | Model/thinking keys absent; child inherits parent settings. |
| `{"prompt":"synthetic","model":null,"thinking":null}` | Keys present with Lisp `nil`; current child creation also inherits. This characterizes parsing/handling, **not** schema validity: the advertised types are strings, not nullable. |
| `{"prompt":"synthetic","model":"","thinking":""}` | Both empty strings survive parsing. They are explicit truthy Lisp values; thinking validation errors before creation. |
| `{"action":"read"}` | Valid minimal settings read reaches its handler. |
| `{"action":"read","session_id":""}` / `session_id:null` | Current target selection uses the caller's session. Null is again a parser/handler characterization, not schema validity. |
| `{"action":"read","permission_mode":"","non_interactive":false,"allowed_dirs":null}` | All keys/values survive; forbidden key presence rejects before session lookup. |
| `{"action":"read","permission_mode":null}` / action `set` | Rejected by presence too; no permission change. |

For an unknown synthetic model with no catalogue thinking levels, the explicit
empty-string reproduction yields the same immediate error as the research:

> Model  does not offer the thinking level ; it offers none. Leave :thinking out
> to use this session's level.

This is an input contract failure, not evidence of attempted escalation. Making
forbidden keys nullable or ignoring them would not fix the schema contract and
could hide errors at a security-sensitive boundary. Removing them from the
advertised parameters leaves the authoritative refusal in place.

## Regression tests and saved artifacts

`test/harness-tool-schema-boundary-test.el` has six network-free tests covering:

- Actual schemas serialized through Responses, OpenAI-compatible, and Claude
  MCP adapters, with the original required lists and explicit Responses false.
- Settings schemas advertising only accepted keys.
- Raw argument parsing and Responses stream emission: omission, empty strings,
  null, and false retained without inserted keys.
- Child inheritance for omitted/null fields and refusal of explicit empty
  thinking; no real child is created.
- Every forbidden settings key on both actions, with empty, null, false, empty
  array, and nonempty values, refused before session lookup.
- Minimal reads and current default-session targeting.

Focused checks: **6/6** new boundary tests, **33/33** Responses provider tests,
and **66/66** settings tests passed. The first local run exposed a missing test
parenthesis and the existing expected envelope lacking `strict`; those test
issues were corrected before the passing rerun. `scripts/lint.sh` also exited
0; its warnings are in unchanged files (`lint.log`). The parent runs the full
project check after merging all changes.

Durable audit artifacts (all synthetic, no credentials):

- [Before schemas](provider-schema-audit/schema-before.json) and
  [after schemas](provider-schema-audit/schema-after.json): full serialized
  schemas for all three local adapters (pretty-printed after capture; values
  unchanged).
- [Argument boundary](provider-schema-audit/argument-boundary.json): raw JSON
  strings, parsed Lisp representations and boundary errors. The capture uses
  an empty thinking-level catalogue for the unknown synthetic model.

Supporting logs and the documentation download remain under
`/var/tmp/harness-1000/804ac6ba-2238-4cf4-885c-62ec9a4a94e8/`:

- `capture-schema.el`, `schema-capture-v3.log`: capture script and output; the
  script stubs only the synthetic model's thinking-level catalogue.
- `openai-function-calling.md`: complete retrieved documentation, strict-mode
  text at lines 1095–1114.
- `focused-tests.log`, `tests/`: initial run, including the passing settings
  suite and initial failures; `focused-tests-v2.log`, `tests-v2/`: complete
  passing boundary/Responses rerun logs.

The committed boundary suite reconstructs current serialized schemas without
credentials. It intentionally does not claim to reproduce opaque server-side
schema conversion or model generation. Those remain separate observability
boundaries, to be tested with sanitized live traffic when available.

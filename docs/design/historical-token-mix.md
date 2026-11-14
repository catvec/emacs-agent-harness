# Historical token mix and spend

## Ownership and review

Owner: Noah. Follow-up tracking: ChatGPT thread `01a1a1d2-f5ae-703b-b85a-d351dcbfd031`.
This is an implementation feature, not the separate OpenRouter versus DeepInfra analysis. Acceptance and merging belong to the human reviewer.

## Purpose and navigation

The usage dashboard gains a **Token mix** view, with a reciprocal **Usage** control. Its command is autoloaded, so dashboard navigation also works before the history UI has loaded. It reuses the dashboard's period selectors, faces, header fitting, ACP transport and read-only view conventions. Overall, project, workspace and day groupings share one accounting path; selecting a group opens that group's token and pricing details. A workspace is the recorded working-directory/project path; a project folds git worktrees under their owning checkout, as the existing usage dashboard does. Scratch sessions retain their parent's project attribution when available.

The distinctive comparison is **token share versus estimated monetary share** for the same workload, not a decorative spending chart. Four category rows align volumes, percentages and reconstructed contributions. Theme faces supply the palette (default foreground/background, shadow, success, caution and link); the user's Emacs font supplies typography. Left-aligned section headings and right-aligned figures follow the existing dashboard. Narrow windows use stacked category details rather than clipped table columns. No private conversation text appears on the page.

## Sources and precedence

The existing usage ledger is authoritative for recorded usage. New rows retain an additive metadata envelope: presence-preserving counters, input semantics, write-counter availability, cost origin and the rates used. Existing budget math remains unchanged.

A background reader reconstructs counters from assistant-node usage metadata in `sessions/<id>.nodes.jsonl`. It reads JSONL operations, not provider authentication directories, and exports only whitelisted metadata. It ignores inherited fork nodes, deleted/replaced node versions and repeated snapshots. Session cumulative totals are not added to dated events and are never divided across arbitrary days. External provider directories and raw provider payloads without reliable identities are intentionally not imported.

The ledger wins over log reconstructions for an overlapping session. Ambiguous overlap is excluded, not summed. Log events use a recorded workspace stamp, or a worktree session's immovable scope. A plain session's current directory is not historical evidence: older unstamped events remain in the unknown project/workspace group, so a later move cannot reassign their usage. New assistant metadata includes the workspace stamp. Missing files, malformed/truncated lines, ambiguous snapshots, undated records and counter gaps remain coverage information. A missing day is not a zero-spend day. Boundaries are `since <= timestamp < until`, with calendar-day grouping in the harness's local time zone.

## Token accounting

All totals use disjoint categories: cache-read, separately reported cache-write, uncached input and output. Inclusive input subtracts reported cache categories exactly once; exclusive input already excludes them. An inclusive input with an unknown cached part cannot be called uncached. Invalid/negative/inconsistent counters become unknown, not clamped to zero. A provider without separate write telemetry has an unavailable write category; its non-read input may include inseparable writes, as explained in Help.

Each category carries its known subtotal, number of known records, number of unavailable records and total selected records. No observations means `Unknown` or `Not reported`, never `0`. Partial subtotals are explicitly partial, including a known zero subtotal with missing records. Token percentages use **known category tokens**, the sum of available disjoint category subtotals, with the numerical denominator shown. This is not an inferred cache-hit rate or a share of all historical tokens.

Legacy ledger rows lack presence/provenance because old code filled absent counters with zero. Such zeros remain unknown. Positive counters can be used only where the recorded provider's semantics are known; uncertain input remains unclassified. This deliberately trades apparent completeness for truthful historical coverage.

## Monetary accounting and pricing matrix

Observed billed amounts, recorded totals with unknown provenance, plan-covered records and reconstructed category estimates are separate measures. A provider's known billed total is never allocated proportionally to token categories. Subscription API-equivalent values are not billed spending.

Reconstruction multiplies disjoint recorded counters by rates in USD per million tokens. New rows use their recorded rate snapshot. Older records may use the existing provider catalogue and its time-sensitive pricing function at the event timestamp; these are explicitly **catalogue estimates**, not historical invoices. Unknown prices remain unknown. No network/model call is needed to inspect the report. The pricing matrix identifies each model, rate source, price timestamp, historical workload period, rates and resulting contributions.

Monetary percentages use **known reconstructed USD**, not observed invoices. The cache-read-majority finding uses only the comparable, fully partitioned, fully priced, non-subscription cohort; its record coverage and denominator accompany the finding. It is a result of the selected workload, not an assumption about caching. Missing coverage prevents a general claim about all recurring spending. The view can legitimately show a high cache-read token share and a small cache-read monetary share.

## Confidence, privacy and help

Coverage is record-based, not an assertion that every provider call was captured. Explicit Help explains source precedence, unknown versus zero, inclusive/exclusive normalization, non-separated writes, estimated rates, subscriptions, cohort selection, local-day boundaries and historical gaps. Aggregate responses contain no prompts, responses, tool inputs, secrets, session names or provider credentials. Background reconstruction uses only local persisted metadata, with bounded reads and explicit failures.

## Copy-first inventory

Authored interface copy is noun phrases/adjectives; explanatory prose is confined to the explicit Help surface. Dynamic paths, dates, model identifiers and server error payloads are data.

| Surface | Exact planned copy |
| --- | --- |
| Navigation / tooltips | `Token mix`, `Historical token mix and spend`, `Usage`, `Usage and cost dashboard`, `Help`, `Accounting and coverage help`, `Refresh`, `Usage refresh`, `Back`, `All groups`, `Close`, `View closure` |
| Menus | `Token mix`, `View`, `Next period`, `Grouping`, `Group details`, `All groups`, `Refresh`, `Accounting help`, `Usage` |
| Worker failures | `Historical usage scan failure`, `Historical usage scan timeout` |
| Periods / tooltips | `Today` / `Local calendar day`, `7 days` / `Last seven calendar days`, `30 days` / `Last thirty calendar days`, `All` / `All available history` |
| Groups / tooltips | `Overall`, `Project`, `Workspace`, `Day`; `Overall breakdown`, `Project breakdown`, `Workspace breakdown`, `Daily breakdown` |
| Headings | `Historical token mix`, `Token categories`, `Spending`, `Coverage`, `Pricing matrix`, `Groups`, `Accounting and coverage help` |
| Category labels | `Cache read`, `Cache write`, `Uncached input`, `Output` |
| Column/detail labels | `Tokens`, `Token share`, `Reconstructed USD`, `Spend share`, `Records`, `Known category tokens`, `Known reconstructed USD`, `Observed billed USD`, `Recorded USD · origin unknown`, `Plan-covered records`, `Comparable records`, `Period`, `Local time`, `Model`, `Rates · USD / million tokens`, `Snapshot`, `Catalogue estimate`, `Price date`, `Unknown prices`, `Unclassified input`, `Source gaps`, `Ledger records`, `Log records`, `Overlap exclusions`, `Duplicate exclusions`, `Ledger-precedence sessions`, `Metadata files`, `Missing`, `Unreadable`, `Ambiguous records`, `Undated records` |
| Status / empty / failure | `Loading history…`, `History unavailable`, `No historical usage`, `No groups`, `No price evidence`, `Unknown`, `Not reported`, `Partial`, `Complete`, `No comparable spending`, `Cache-read majority`, `No cache-read majority`, `Reconstructed spending · comparable records`, `Historical coverage · partial`, `Historical coverage · recorded metadata` |
| Category tooltips | `Known disjoint category tokens`, `Share of known category tokens`, `Token-count × rate estimate · not an invoice allocation`, `Share of known reconstructed USD`, `Known records / selected records`, `Separate write counters unavailable` |
| Validation | `Unknown history grouping`, `Unknown history period`, `No group at point` |

Exact rendered-copy tests cover navigation, header tooltips, loading, empty, partial and error states. Before hand-in, live screenshots and changed UI strings are inspected against this inventory separately from the accounting tests.

## Alternatives and verification

Extending the old zero-filled summary would silently turn missing data into zeros. Re-reading all provider histories would expand privacy risk, require unreliable cross-provider identity heuristics and duplicate the existing ledger. Treating invoice totals as category allocations would manufacture evidence. These alternatives are rejected.

Focused synthetic fixtures cover mixed providers, inclusive/exclusive inputs, separate writes, missing versus zero, partial totals, duplicate/fork/turn boundaries, observed versus estimated costs, unavailable rates, period boundaries and all grouping dimensions. A synthetic live demo exercises navigation and help without real private logs or model calls. Final evidence includes screenshots, focused checks, lint and the committed tree's full project test run.

## Rendered-copy and accounting review

The separate copy review checked the changed UI-string diff against the inventory, exact header/menu/tooltips and loading/empty/partial/error regressions, and live wide, narrow, pending, empty, daily-detail and Help captures. Group and model counters use `Records N`; long directory labels retain distinguishable ends; explicit Help wraps at word boundaries. The committed [overview image](../media/usage-token-mix.png) and the task's additional captures use synthetic metadata only. The demo is not a conclusion about Noah's actual invoices.

An independent read-only accounting review led to regressions for cold-catalogue inspection without provider fetching, preserved compaction provenance, late request/message identity bridges, disappearing selected groups, and unstamped historical workspace attribution. Contradictory inclusive cache totals also remain unknown rather than priced. The synthetic demo resets to All/Overall and opens one full view, without first creating a duplicate side window. Full-run results and retained logs accompany the task review, rather than being embedded as a lasting claim in this document.

## Full-check isolation

Final verification exposed small infrastructure defects outside the accounting path. Their fixes remain separate, reviewable commits:

- The workspace-box fixture's invented PIDs can name the test runner's supervisor inside a sandbox. Its test-only adopted-PID cleanup is stubbed, with a no-signal regression; production workspace behavior is unchanged.
- A bounded skill-file scan must sort directory enumeration before applying count and byte limits. Sorting only the retained subset made the selected files and fingerprint depend on filesystem order. A forced-order regression covers both limits.
- A nested sandbox supervisor must discard its caller's inherited run tag before spawning helpers, and status/cancellation enumeration must require its own exact, literal instance tag. Otherwise the parent run or a foreign runtime can appear to be an owned survivor. A real-supervisor regression checks survivor counts, cancellation and preservation of a foreign process with a colliding run token.

These fixes do not change permission or queue settings. Cold dashboard navigation also has an autoload regression and participates in the shared UI menu-registration checks.

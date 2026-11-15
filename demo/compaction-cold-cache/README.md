# What a compaction answers

A batch demonstration of the cold-cache rule after a compaction:

```sh
demo/compaction-cold-cache/demo.sh
```

It runs the real cold-cache gate (`harness-cowboy--settled-p`), the real
cache panel (`harness-ui-cache--state`) and the real session record
against real sessions.  No model is called -- the provider is scripted
-- and no harness is started, so it is safe to run anywhere Emacs is.

| Case | asked | panel |
| --- | --- | --- |
| 1. A compaction's own result goes cold | nothing | none |
| 2. Its cache lapses again, a turn later | nothing | none |
| 3. Grown back past what was replaced | the question | shown |
| 4. A compaction that failed | the question | shown |
| 5. A compaction that was reverted | the question | shown |

Case 2 is the reported bug: before this change the second lapse asked
again and, unasked in a task session, compacted the summary a second
time.  Case 3 is what keeps the rule honest -- a conversation as big
again as the one the compaction replaced is a new question.  Cases 4 and
5 are what a failed or reverted compaction must not settle.

The last line prints what a record read costs on a 2000-node session,
which is why the answer is carried on the session record rather than
derived from the transcript: 0.07 ms a read, against 3.2 ms when it was
derived.

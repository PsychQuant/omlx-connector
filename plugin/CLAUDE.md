# omlx-connector

Delegates text work to a model running on this machine via
[oMLX](https://github.com/jundot/omlx). Five tools: `local_summarize`,
`local_rewrite`, `local_classify`, `local_complete`, `local_models`.

For **when** to delegate, see the `local-delegation` skill — it carries the test
(whose words are these?) and the cost model. This file covers what the skill
assumes: the architecture, and the limits that decide whether delegation is even
possible.

## Two arrangements, and this plugin is one of them

Users combining a local model with Claude Code have two options, and they are
frequently confused for each other. The axis is **who answers the user**.

| | **Usage 1** | **Usage 2 — this plugin** |
|---|---|---|
| Started by | `omlx launch claude` | installing this plugin |
| Who answers | the local model | Claude |
| The local model is | the agent itself | a tool Claude calls |
| Claude present | no | yes |
| Works offline | yes | no |

When a user asks "what can the local model do", establish which arrangement they
mean before answering. Capability measured under usage 1 does not transfer: usage 1
requires the local model to plan its own tool use, usage 2 does not.

## Hard limits, not gradual degradation

**Context window ≥ 48K or the model is refused.** Claude Code's minimum
(`CLAUDE_CODE_MIN_CONTEXT_WINDOW`) rejects smaller models outright rather than
running them slowly. This rules out otherwise capable models: `Qwen3-32B` has a
native window of 40,960 and cannot be used at all. Check `max_context_window` via
`local_models` before recommending one.

This limit applies to usage 1. Usage 2 (these tools) has no such floor, since
Claude handles the agent loop.

## Costs the user will feel

**Cold start.** A model not already in memory must load first — roughly 17 seconds
for a 15 GB 4-bit model, longer for larger ones. `local_models` reports which are
`loaded`. An already-loaded model answers short work in about a second.

**Memory contention.** A loaded model holds its full weights in unified memory and
competes with everything else running. Loading a 15 GB model on a machine already
running a heavy job can leave the system with a few hundred MB free, which slows
that job badly. Before delegating a large batch, consider what else is running.
Unload when done:

```
curl -X POST http://127.0.0.1:8000/v1/models/<model-id>/unload
```

**Quality floor.** Smaller models fail in ways that are easy to miss because the
output still reads fluently. Two observed on a 0.6B model: Traditional and
Simplified Chinese mixed within one sentence when Traditional was requested; and
"the effect size was too small and it disappeared after two weeks" classified as
*positive*. Neither occurred on a 27B model. Read what comes back — do not pass it
through unchecked.

## Reasoning is off by default

The task-specific tools disable it; measured on Qwen3.8-27B it costs roughly 3.5x
the latency (6.0s vs 1.7s) for work that rarely needs it. `local_complete` accepts
`thinking: true`. When it is on, allow generous `max_tokens` — the budget goes to
thinking first, and a tight cap truncates the answer before it begins. Reasoning is
returned in a separate `reasoning` field, never mixed into the answer.

## When the server is not running

Every tool fails with a message naming the fix (`open -a oMLX`, or `omlx start`).
If oMLX is not installed at all, say so plainly. **Do not quietly fall back to
processing the content yourself** — the user chose these tools precisely so that the
content would not reach a cloud API, and silently doing it anyway defeats the reason
they installed this.

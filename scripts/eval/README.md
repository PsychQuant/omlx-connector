# Delegation-quality evaluation

`Tests/` answers *does the code behave as designed*. This answers *is the delegated
work any good* — a different question, with no pass/fail answer, that needs a model
loaded and cannot run in CI. Issue #1.

```bash
make eval                                             # whatever oMLX has loaded
make eval MODELS="--model A --model B --model C"      # the comparison that matters
```

Output is `scripts/eval/results.jsonl`, one row per (model × case). It is a
measurement record, not a score: **the interesting output is where the cliff is**, and
a single number would destroy exactly that. The file is gitignored — a committed
measurement goes stale silently, and a stale one is worse than none.

## What a row contains

| field | meaning |
|---|---|
| `case`, `why`, `tool` | which case ran, and why it exists |
| `model`, `model_requested` | what oMLX actually served vs. what was asked for. Quantization is part of the id (`…-4bit`), so the id is recorded verbatim. This was an *echo* until `ChatResponse` was taught to decode the response's own `model` field — before that the two columns were identical by construction on the `--model` path, and this table described a distinction the code did not provide |
| `elapsed_seconds` | wall clock for that call. First call to a cold model includes the load |
| `finish_reason` | present **only** when the model did not stop on its own. A reply truncated at the token limit is a different finding from one that ignored the instruction |
| `text` | the reply, verbatim. Read it — see below |
| `checks`, `mechanical_ok` | the mechanical verdicts. **Not** `all_ok` — that name is the reading this whole file forbids, and it is what any downstream pass-rate would have taken |
| `text`, `text_field` | which payload key was checked. `local_classify` has no `text` key; it is scored on `raw_response` |
| `category`, `matched` | `local_classify` only. `matched: false` is the issue's actual question about that tool |
| `human_review` | what a person still has to decide. Nothing scores these |
| `error` | a tool or transport error. Recorded as a result, not raised as a crash |

## What is checked mechanically, and what is not

Five checks, in `check.py`. Each is a pure function of the reply text, and each is
unit-tested in the **hermetic** suite (`scripts/tests/eval-checks.test.sh`) with a fixture
it must fail on and one it must pass on, so they stay verified on a machine with no oMLX.

**On "mutation-proven", carefully, because the first version of this sentence was false.**
It claimed the checks were mutation-proven in both directions. That held only for the
coarsest possible mutation — replacing an entire `ok` expression with a constant. A
reviewer injected real logic mutations and the suite stayed green for all of them: an
off-by-one on the sentence ceiling, `all()` → `any()`, removing the regex anchoring,
deleting 11 of the 13 preamble patterns one at a time, and shrinking the 422-character
Simplified set to two characters. The fixtures came from the same mental model as the
code, so they could not disconfirm it — the trap `CLAUDE.md` had already recorded three
times, walked into a fourth.

What is true now is narrower and checkable: a sweep of 12 targeted logic mutations plus
per-pattern deletion of all 13 preamble regexes leaves **zero survivors**. The fixtures
sit on the boundary (3-vs-2, not 4-vs-2) for that reason. The sweep is not automated —
it lives in this round's history, not in `make test` — so treat it as a claim about a
point in time, and re-run it when you change a check.

| check | asks |
|---|---|
| `non_empty` | did the model reply at all? Runs on **every** case regardless of what `expect` says, because an empty reply used to satisfy all three of the others trivially, and a case with no `expect` used to produce a green row having checked nothing |
| `sentence_count` | was `max_sentences` respected? (a ceiling — under-shooting is not a violation) |
| `no_preamble` | did the reply start with content, or with "Here is a summary of…"? The server sends `outputOnlyRule` as its system prompt on every call; this measures whether the model obeyed it |
| `script_purity` | Traditional Chinese asked for, Simplified characters delivered? |
| `category_member` | is the label one of the offered candidates, or a sentence mentioning one? (for `local_classify`; no cases use it yet) |

**Coverage and faithfulness are deliberately not judged.** Issue #1 asks for them to be
"recorded for human review", and an LLM-as-judge would replace a judgement with another
black box that itself needs verifying. They appear as `human_review` prompts on each
case, answerable only by reading `text`.

### Each check's limits, stated rather than papered over

A check whose failure modes are written down beats one that pretends to be exact.

- **`sentence_count`** treats `.!?。！？…` as terminators, skips a `.` flanked by digits
  (so `0.05` is not two sentences), and collapses runs. It does **not** know
  abbreviations — "Dr. Chen" reads as two — nor a single comma-spliced sentence that
  should have been three.
- **`no_preamble`** matches known *openers*, anchored at the start. A lead-in buried
  mid-reply is not caught. Anchoring is what keeps ordinary content containing a colon
  ("Three items were deferred: budget, venue") from being flagged.
- **`script_purity`** uses a curated set of characters that exist **only** in Simplified.
  It is not exhaustive, and that direction is deliberate: a false positive would flag a
  clean reply and quietly discredit the harness, whereas a miss only under-reports. **It
  finds mixing; it does not certify purity.**

  That direction is now *enforced*, not promised. The first version stated the rule here
  and broke it in the data: `紫` (紫色) and `凰` (鳳凰) are the same codepoint in both
  scripts, and `划` (划算) and `据` (拮据) are ordinary Traditional characters — all four
  flagged clean Traditional replies, in the one check written for the constituency issue #1
  calls non-negotiable. Twenty members of the set were encodable in **Big5**, a
  Traditional-only charset, which is the mechanical form of the sentence the prose was
  trying to make. All twenty are gone, and the hermetic suite now asserts both halves:
  no member may encode in Big5, and the set may not shrink below 300 characters (so
  emptying it — which satisfies the first assertion perfectly — fails the second).

  It still cannot see the other half of the failure issue #1 documents: a model that
  answers a Chinese prompt *in English* passes trivially, since there are no Han characters
  to be Simplified. The Chinese case carries a `human_review` line about exactly that.

## Read the replies. Green does not mean good.

The first cross-size run (2026-09-01, oMLX 0.6.4, five `local_summarize` cases against
`mlx-community--Qwen3-0.6B-4bit`, `mlx-community--Qwen3-4B-Instruct-2507-4bit` and
`Qwen3.8-27B-4bit` — written out in full, because the row above says ids are recorded
verbatim and an abbreviation here would contradict it) came back **15 rows, zero mechanical
flags** — and the models were plainly not equally good:

- On `meeting-coverage-2sentence`, the 0.6B opened with "The meeting was held in the
  usual room", spending its two-sentence budget on the one sentence carrying nothing,
  and dropped the deferred control-condition decision entirely. 2 of 3 load-bearing
  items. This reproduces the failure issue #1 documents.
- On `focus-open-questions`, the 0.6B answered *about* the task — "The summary
  emphasizes open questions and unresolved decisions…" — and asserted a "delayed
  finalization of the deadline" that the source does not contain. The 27B returned
  exactly the two genuinely open items and nothing else.
- On `traditional-chinese-purity`, the 0.6B rendered "deferred" as 延續 ("continued"),
  which inverts the meaning. Script purity passed on all three.

So for `local_summarize` at these sizes, the mechanical layer **did not discriminate at
all**. That is a finding about the checks, not a clean bill of health for the models:
length and preamble compliance are the easy part, and everything that separated the
0.6B from the 27B was in the half no check touches.

The `local_classify` cases make the same point more sharply, because there the mechanical
verdict is closest to looking like an answer. All three came back green on the 0.6B, and
**two of the three are wrong**: "The app crashes on launch whenever the config file is
missing" was classified `feature request`, and 「測試測試測試」 — content that fits neither
offered label — was forced into `feature request` as well. A forced label *matches*, so
`matched` stays true and the row looks clean. That is the worst case this harness has: a
green verdict that is not merely uninformative but actively misleading, and only the
`human_review` line says so.

Do not report a green run as "the model passed".

## Adding cases

Cases are data (`cases/*.json`). `tool` and `arguments` go straight to `tools/call`, and
`expect` names checks in `check.py`; the hermetic suite asserts every name in every case
file exists, so a typo fails in seconds rather than mid-run against a live model.

**A new tool is data only if its payload shape is already handled.** This paragraph used
to say a new tool "means a new file, not a change to `run.sh` or `check.py`", and that was
false for the one tool it was making a promise about: `local_classify`'s payload is
`task/category/matched/raw_response` with no `text` key, so `rpc.py` needed a shape-aware
extractor before any classify case could work at all. `render()`-shaped tools
(`local_rewrite`, `local_complete`) are genuinely data; anything else needs a look at
`checkable_text()` first.

## Shape, and why

Three files, and the split is load-bearing:

- `check.py` — pure text in, verdict out. No I/O, no model, no subprocess. That is what
  lets the hermetic suite verify it anywhere.
- `rpc.py` — case files, MCP envelopes, row assembly, and the run's **verdict**
  (`summarize`). Kept out of `check.py` so file handling never reaches the one part with a
  right answer. Its envelope handling is hermetically tested, because "a failing check
  reaches the row" was carried by inspection for one round and that is how this repo's
  defects usually look.

  The verdict lives here rather than in `run.sh` for the same reason. As inline bash it
  counted rows *appended* — and a recorded tool error is a row — so a run in which every
  single call failed printed `5 row(s) written, 0 error(s)` and exited 0, the guard failing
  open on precisely the state its own comment said it existed to catch. Counting the right
  thing was half the fix; being testable at all was the other half.
- `run.sh` — process lifecycle and the JSON-RPC pump, and nothing that needs asserting.

This directory sits outside both test globs (`scripts/tests/*.test.sh` and
`scripts/tests/headed/*.test.sh`) so it cannot join either by accident — separation by
file layout, not by a flag anyone has to remember.

**The preflight is `$BINARY --ping`, deliberately.** The first version curled `$OMLX_URL`
— which is the *usage-1* variable read by `omlx-claude`, while the binary this harness
drives reads `OMLX_BASE_URL`. The go/no-go check therefore verified an address the run
never used, which is the same shape as the managed-settings defect `CLAUDE.md` describes.
`--ping` is the run's own client, so it cannot drift from it, and it goes through
`OmlxConfig.resolveBaseURL` — which means `LoopbackPolicy`, rather than a fourth
address-resolving path the top-level `CLAUDE.md` explicitly forbids.

**The non-obvious plumbing detail:** stdin must stay open until the reply arrives. The
first probe written for this closed it immediately after writing the request; the
server exited without answering, which looks exactly like a broken server rather than a
closed pipe. `run.sh` holds it with an explicit fd on a FIFO (macOS ships bash 3.2, so
`coproc` is unavailable — and the fd states the mechanism more plainly anyway).

## What this does not cover

- `local_rewrite`, `local_complete`, `local_models` — the issue's own first step is
  summarize alone. The case format is tool-agnostic, so these are data later.
- **Whether a classify label is correct.** `classify.json` checks that the model answered
  with a bare label from the list; whether that label is the right one is a `human_review`
  question. Automating it needs a labelled set this repo does not have, and the issue's
  clarification puts judgement of correctness on the human side.
- CI — needs a live oMLX and Apple silicon.
- A formal benchmark with pre-registration. That discipline lives in
  `local-llm-benchmarking` and stays there.

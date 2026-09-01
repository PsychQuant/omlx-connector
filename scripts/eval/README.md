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
| `model`, `model_requested` | what oMLX actually served vs. what was asked for. Quantization is part of the id (`…-4bit`), which is why the id is recorded verbatim and never shortened |
| `elapsed_seconds` | wall clock for that call. First call to a cold model includes the load |
| `finish_reason` | present **only** when the model did not stop on its own. A reply truncated at the token limit is a different finding from one that ignored the instruction |
| `text` | the reply, verbatim. Read it — see below |
| `checks`, `all_ok` | the mechanical verdicts |
| `human_review` | what a person still has to decide. Nothing scores these |
| `error` | a tool or transport error. Recorded as a result, not raised as a crash |

## What is checked mechanically, and what is not

Four checks, in `check.py`. Each is a pure function of the reply text, and each is
unit-tested in the **hermetic** suite (`scripts/tests/eval-checks.test.sh`) with a
fixture it must fail on and one it must pass on. So they stay verified on a machine
with no oMLX, and they are mutation-proven: neuter any one of them to always-pass and
exactly its "refuses" cases go red; to always-fail and its "accepts" cases do.

| check | asks |
|---|---|
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
- **`script_purity`** uses a curated set of characters that exist **only** in
  Simplified. It is not exhaustive, and that direction is chosen: characters valid in
  both scripts (`里` `干` `万` `与` `云` `后` `几` `周`…) are left out, because a false
  positive would flag a clean reply and quietly discredit the harness, whereas a miss
  only under-reports. **It finds mixing; it does not certify purity.** It also cannot
  see the other half of the failure issue #1 documents — a model that answers a Chinese
  prompt *in English* passes trivially, since there are no Han characters to be
  Simplified. That is why the Chinese case carries a `human_review` line about it.

## Read the replies. Green does not mean good.

The first cross-size run (2026-09-01, oMLX 0.6.4, five `local_summarize` cases against
Qwen3 0.6B-4bit / 4B-Instruct-2507-4bit / 27B-4bit) came back **15 rows, zero
mechanical flags** — and the models were plainly not equally good:

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
0.6B from the 27B was in the half no check touches. Do not report an all-green run as
"the model passed".

## Adding cases

Cases are data (`cases/*.json`). A new tool means a new file, not a change to `run.sh`
or `check.py` — `tool` and `arguments` go straight to `tools/call`. `expect` names
checks in `check.py`; the hermetic suite asserts every name in every case file exists,
so a typo fails in seconds rather than mid-run against a live model.

## Shape, and why

Three files, and the split is load-bearing:

- `check.py` — pure text in, verdict out. No I/O, no model, no subprocess. That is what
  lets the hermetic suite verify it anywhere.
- `rpc.py` — case files, MCP envelopes, subprocess. Kept out of `check.py` so file
  handling never reaches the one part with a right answer. Its envelope handling is
  hermetically tested too, because "a failing check reaches the row" was carried by
  inspection for one round and that is how this repo's defects usually look.
- `run.sh` — process lifecycle and the JSON-RPC pump.

This directory sits outside both test globs (`scripts/tests/*.test.sh` and
`scripts/tests/headed/*.test.sh`) so it cannot join either by accident — separation by
file layout, not by a flag anyone has to remember.

**The non-obvious plumbing detail:** stdin must stay open until the reply arrives. The
first probe written for this closed it immediately after writing the request; the
server exited without answering, which looks exactly like a broken server rather than a
closed pipe. `run.sh` holds it with an explicit fd on a FIFO (macOS ships bash 3.2, so
`coproc` is unavailable — and the fd states the mechanism more plainly anyway).

## What this does not cover

- `local_rewrite`, `local_complete`, `local_models` — the issue's own first step is
  summarize alone. The case format is tool-agnostic, so these are data later.
- `local_classify` cases — `category_member` is implemented, no cases use it yet.
- CI — needs a live oMLX and Apple silicon.
- A formal benchmark with pre-registration. That discipline lives in
  `local-llm-benchmarking` and stays there.

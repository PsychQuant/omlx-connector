# Delegation-quality evaluation

`Tests/` answers *does the code behave as designed*. This answers *is the delegated
work any good* — a different question, with no pass/fail answer, that needs a model
loaded and cannot run in CI. Issue #1.

```bash
make eval                                             # whatever oMLX has loaded
make eval MODELS="--model A --model B --model C"      # the comparison that matters
```

**Exit codes**, because the exit status is the only part of this a machine reads:

| | |
|---|---|
| `0` | the run happened and every mechanical check passed |
| `2` | the run happened and there are **findings** — a model did badly, which is data, not a build failure |
| `1` | the run did **not** happen: nothing measured, a tool/transport/malformed failure, or rows that are not the (model, case) pairs the run owed — too few, too many, duplicated, or for the wrong cases |
| `64` | usage error (`EX_USAGE`) — a bad flag, a malformed environment value, the same model or case file given twice, the same case **id** in two files. Decided from the arguments and the case files, before any server is contacted. In **every** program of the harness: round 4 fixed `run.sh` alone and left `check.py`/`rpc.py` at argparse's 2 |

A malformed *case file* is `1`, not `64`: the run did not happen. The line is flags-and-
environment versus input files, and it is drawn there so that "the harness was invoked
wrong" and "the harness was given something it could not measure" stay distinguishable.

`make eval` maps `2` to success and prints a line saying so — make would otherwise render
"findings present" as `*** [eval] Error 2`, for exactly the runs that are most informative.
Run `scripts/eval/run.sh` directly if you need the raw code.

The two-way version of this was indefensible: a tool error exited 1 while a model returning
an empty string exited 0, so the axis was *which layer the emptiness happened at* rather
than what it meant — and an all-red run reported success. `results.jsonl` is only replaced
by a **complete** run; an incomplete one leaves the previous file alone and writes what it
did measure to `results.jsonl.partial`, which a later run moves aside under a timestamped
name rather than overwriting (both spellings are gitignored).

**Completeness is counted, not inferred.** `run.sh` computes how many rows a run owes
(models × cases) before anything starts, and `summarize` compares. Every fail-open variant
the first three review rounds found reduces to that number being unknown: a tool error that
produced a row the guard misread, a transport failure that produced none, a model whose
handshake failed, a case file that would not parse. Each was fixed as its own branch and the
next appeared one layer out. The README already named the root — *"nothing in it says how
many rows it should have"* — so the fix is to count.

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
| `text` | the reply, verbatim — model-authored and **unfiltered**, the one field the harness never sanitizes. Read it (see below) with `cat -v` or a pager, not a bare `cat`: the harness itself never prints it |
| `checks`, `mechanical_ok` | the mechanical verdicts. **Not** `all_ok` — that name is the reading this whole file forbids, and it is what any downstream pass-rate would have taken. Includes `row.<field>` entries from a case's `expect_row` |
| `text`, `text_field` | which payload key was checked. `local_classify` has no `text` key; it is scored on `raw_response` |
| `category`, `matched` | `local_classify` only. `matched: false` is the issue's actual question about that tool |
| `human_review` | what a person still has to decide. Nothing scores these |
| `error` | a tool **or transport** error. Both are recorded as results rather than raised — and transport failures really do produce a row now: for a round they produced nothing at all, so four of five cases could vanish and the run still exit 0 |

## What is checked mechanically, and what is not

Six checks, in `check.py`. Each is a pure function of the reply text, and each is
unit-tested in the **hermetic** suite (`scripts/tests/eval-checks.test.sh`) with a fixture
it must fail on and one it must pass on, so they stay verified on a machine with no oMLX.

| check | asks |
|---|---|
| `non_empty` | did the model reply at all? Runs on **every** case regardless of what `expect` says, because an empty reply used to satisfy all the others trivially, and a case with no `expect` used to produce a green row having checked nothing |
| `sentence_count` | was `max_sentences` respected? (a ceiling — under-shooting is not a violation) |
| `no_preamble` | did the reply start with content, or with "Here is a summary of…"? The server sends `outputOnlyRule` as its system prompt on every call; this measures whether the model obeyed it |
| `script_purity` | Traditional Chinese asked for, Simplified characters delivered? |
| `category_member` | is the reply a **bare** label from the offered list? A sentence that merely mentions one fails. This is the format question, **not** "was it right" — that is `expect_row.category` |
| `label_is` | correct **and** bare, conjoined — it compares the raw reply to a gold label. Useful when you want both at once; **not** the accuracy signal, because a right answer that was decorated fails it identically to a wrong one |

Accuracy independent of format comes from `expect_row: {"category": …}` — the server has
already matched the reply onto the caller's list, so it survives decoration. Round 3 used
`label_is` for accuracy and then told readers that it and `category_member` separated "right
but undisciplined" from "disciplined but wrong"; since gold is always one of the categories
and both applied the same normalisation, `label_is` passing *implied* `category_member`
passing, and the combination readers were told to look for was unreachable.

A case may also carry `expect_row`, which asserts on **row fields** rather than reply text —
`{"matched": false}` for out-of-domain classify input, where the right behaviour is to name
none of the offered labels. No text check can express that: scoring it with
`category_member` pointed the verdict backwards, failing the desired outcome and passing the
undesired one.

**On mutation coverage, carefully, because this sentence has been wrong twice.**

Round 1 claimed the checks were "mutation-proven in both directions". That held only for
replacing a whole `ok` expression with a constant; real logic mutations all left the suite
green. Round 2 fixed that for **code paths** — 12 targeted mutations and per-pattern
deletion of every preamble regex, zero survivors — and then claimed the class was closed.
It was not: the same trap had moved onto the **constant tables**. Deleting any one line of
`_SIMPLIFIED_ONLY` survived, shrinking the set to exactly the asserted floor survived,
`_TERMINATORS` losing terminators survived, and `_CLOSERS` losing its whitespace survived —
because a table's power was pinned only by whichever characters happened to appear in some
fixture. Round 4 found the same trap once more in the **add** direction, and found the
guards themselves individually deletable because nothing counted them.

What is true now, measured rather than asserted: every line of `_SIMPLIFIED_ONLY` has a
per-character probe tested **alone**, plus an assertion that every line still *has* one, so
the coverage cannot weaken silently as the table is re-wrapped; `_TERMINATORS` and
`_CLOSERS` have fixtures using `？`, `！`, `…` and a trailing newline. All of those
mutations now go red.

**Round 4's count could not see weakening, and round 5 adds a canary for that.** The suite
asserts its own assertion count (`EXPECTED_CASES`), which catches a deleted guard. Round 4's
verify neutered the central assertion helper — `if [ "$actual" = "$expect" ]` → `if true` —
and the count stayed exactly where it was, byte-identical, while a defect seeded into
`check.py` that 11 cases used to catch was caught by 2. Moving a boundary fixture back off
the boundary, or hollowing a 21-entry corpus to one, were the same: the number counted
`PASS++` calls, not what each call asserted.

So the suite now re-runs itself against three deliberately broken copies of `check.py` —
every check says ok, every check says not-ok, and `<= ceiling` made `<= ceiling + 1` — and
requires **exactly** a pinned number of its own assertions to fail against each. The three
constants live in the suite beside `EXPECTED_CASES` and are **not repeated here**: a prose
copy of them drifted from the suite in round 5 and again in round 7, the second time twelve
lines from arithmetic that used the new values. That is the offline mutation sweep in miniature, inside `make test`, and it
catches the three weakening mutations by construction: a neutered helper fails nothing, an
off-boundary fixture no longer trips the off-by-one mutant, a corpus hollowed by **deletion**
changes the count because corpora and probes are counted per fixture. A corpus hollowed by
**replacement** — the same number of sentences, each saying less — does not, and the round-7
verify did exactly that (two clean sentences → 「好。好。」, 謝 added to the Simplified set,
336 / 0, 「謝謝大家的協助與體諒。」 flagged as Simplified in green). The suite's own
`HONEST LIMIT` comment had already said it: corpora close the shapes they contain, not the
property. The previous version of this sentence promised more than that. The three
numbers are updated on purpose when fixtures change, like the count itself.

**What the canary does not see — families named in round 5, counts measured in the suite.** A canary
sees only an assertion whose verdict flips under one of the three mutants. Two families do
not: everything after the canary exit (the `rpc.py` score / summarize / complete / append
cases, the `run.sh` end-to-end cases, the manifest, the served-model call site), and
assertions that check an *exit code* or a table's *membership* rather than a verdict
(`usage64()`, `guard()`, the probe-coverage and add-direction checks). How many fall in each
family is measured in the suite header beside the constants it is computed from, with the
one-line command that re-measures it; this file carries no copy, for the reason just given.
Neutering any one
of those helpers is a single-line edit that touches no fixture
and no constant and leaves the count and all three canaries unchanged; so is neutering the
canary's own comparison. Round 5's verify did each of these and showed a real defect escaping
behind it. Round 6 closed the two that were one line each — the ambient-variable bypass now
needs a per-run token written into the mutant, and the add-direction guards count per
fixture — and stopped there: the next layer is a second mutant family for `rpc.py` and a
guard for `canary()`, and the layer after that is the same question. A test suite cannot be
immune to someone with write access to it. This file says where that immunity ends instead
of claiming it does not.

**The sweep is still not part of `make test`** — it takes ~30 suite runs. So this remains a
claim about a point in time, and the honest reading of two rounds of getting it wrong is:
when you change a check or a table, re-run the sweep, and expect to find that the class you
thought you closed has moved one layer out.

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

  This has now been wrong in both directions, and both are worth keeping. Round 1 stated
  the rule here and broke it in the data: `紫` (紫色) and `凰` (鳳凰) are the same codepoint
  in both scripts, and `划` (划算) and `据` (拮据) are ordinary Traditional characters — all
  four flagged clean Traditional replies. Round 2 "fixed" that by removing every member
  encodable in **Big5**, on the theory that a Traditional-only charset made encodability the
  mechanical form of the rule. It is not: Big5 also carries rare archaic Traditional
  variants of characters that are plain Simplified markers in modern text. Twenty went;
  only four were the false-positive sources. The other sixteen — `么听圣坏复宁庄怀惊扑扰网胜赶适吨`
  — were real detection, and `什么`, about the highest-frequency Simplified-exclusive word
  there is, began passing silently. The property test made it irreversible.

  The sixteen are back, and the guard is a **corpus** rather than a computable property:
  clean Traditional sentences that must all pass, Simplified content that must all be
  flagged, and a per-character probe from every line of the set. Whether a character is
  Simplified-only is a fact about language, not a property of an encoding.

  The residual cost, stated rather than hidden: a classical or archaic Traditional text
  using `宁` (zhù) or `听` (yǐn) is flagged. That is a real false positive, accepted because
  eval replies are modern prose.

  It still cannot see the other half of the failure issue #1 documents: a model that answers
  a Chinese prompt *in English* passes trivially, since there are no Han characters to be
  Simplified. The Chinese case carries a `human_review` line about exactly that.

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

The `local_classify` cases were the sharpest illustration of the problem, and are now the
sharpest illustration of the fix. For two rounds all three came back **green on the 0.6B
with two of the three answers wrong**: "The app crashes on launch whenever the config file
is missing" classified `feature request`, and 「測試測試測試」 — content fitting neither
offered label — forced into `feature request` as well. A forced label *matches*, so
`matched` stayed true and the row looked clean. The gold labels existed the whole time, as
prose in `human_review`, while this file claimed automating them "needs a labelled set this
repo does not have".

With `expect_row.category` and `expect_row.matched`, the round-5 live run — `run.sh`'s
per-case lines verbatim, elapsed and served id included (the blank lines `run.sh` prints
between sections are elided), because two earlier versions of this block printed output no
run could produce:

```
model: mlx-community--Qwen3-0.6B-4bit
  classify-negative-hedged     ok      0.1s  mlx-community--Qwen3-0.6B-4bit
  classify-bare-label-discipline FLAG    0.1s  mlx-community--Qwen3-0.6B-4bit  row.category
  classify-none-of-the-above   FLAG    0.1s  mlx-community--Qwen3-0.6B-4bit  row.matched
  meeting-coverage-2sentence   ok      0.2s  mlx-community--Qwen3-0.6B-4bit
  traditional-chinese-purity   ok      0.2s  mlx-community--Qwen3-0.6B-4bit
  numbers-one-sentence         ok      0.3s  mlx-community--Qwen3-0.6B-4bit
  focus-open-questions         ok      0.2s  mlx-community--Qwen3-0.6B-4bit
  short-source-preamble-bait   ok      0.2s  mlx-community--Qwen3-0.6B-4bit
model: mlx-community--Qwen3-4B-Instruct-2507-4bit
  classify-negative-hedged     ok      0.2s  mlx-community--Qwen3-4B-Instruct-2507-4bit
  classify-bare-label-discipline ok      0.1s  mlx-community--Qwen3-4B-Instruct-2507-4bit
  classify-none-of-the-above   FLAG    0.2s  mlx-community--Qwen3-4B-Instruct-2507-4bit  row.matched
  meeting-coverage-2sentence   ok      0.5s  mlx-community--Qwen3-4B-Instruct-2507-4bit
  traditional-chinese-purity   ok      0.6s  mlx-community--Qwen3-4B-Instruct-2507-4bit
  numbers-one-sentence         ok      0.5s  mlx-community--Qwen3-4B-Instruct-2507-4bit
  focus-open-questions         ok      0.8s  mlx-community--Qwen3-4B-Instruct-2507-4bit
  short-source-preamble-bait   ok      0.4s  mlx-community--Qwen3-4B-Instruct-2507-4bit
  measured=16  errored=0  malformed=0  (of 16 owed)
```

A decorated wrong answer ("Category: feature request.") would print `FLAG … category_member,
row.category` — both checks, on one line; the 0.6B here answered a bare wrong label, so only
`row.category` fired.

Two findings at 0.6B, one at 4B — **the cliff, visible mechanically**, which is what issue #1
asked for and what the first two rounds could not show. Note also what stays a human's job:
`classify-negative-hedged` is `ok` on both, and whether a near-miss (`neutral`) would have
been better than an inversion (`positive`) is not something `row.category` can weigh.

Do not report a green run as "the model passed".

## Adding cases

Cases are data (`cases/*.json`). `tool` and `arguments` go straight to `tools/call`, and
`expect` names checks in `check.py`; the hermetic suite asserts every name in every case
file exists, so a typo fails in seconds rather than mid-run against a live model.

**A new tool is data only if its payload shape is already handled, and a new KIND of
expectation is never data.** This paragraph once said a new tool "means a new file, not a
change to `run.sh` or `check.py`", and that was false for the one tool it promised about:
`local_classify`'s payload is `task/category/matched/raw_response` with no `text` key, so
`rpc.py` needed a shape-aware extractor first. `render()`-shaped tools (`local_rewrite`,
`local_complete`) are genuinely data; anything else needs a look at `checkable_text()`.

Likewise `label_is` (a new check) and `expect_row` (a new expectation channel) each took
code. What is data is a new *case* using mechanisms that exist.

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
- **Judging *how* wrong a wrong label is.** `expect_row.category` decides correct/incorrect
  against a gold label; whether an incorrect answer was a near miss or an inversion is a
  `human_review` question. (Two earlier versions of this bullet were wrong in turn: one said
  correctness could not be automated "without a labelled set this repo does not have" while
  the labels sat in the case files as prose; the next credited `label_is`, which conjoins
  correctness with format and is no longer any shipped case's accuracy signal.)

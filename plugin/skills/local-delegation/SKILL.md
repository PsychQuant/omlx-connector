---
name: local-delegation
description: Use when about to process content that may not be safe to send to a cloud API — recordings or transcripts of other people, unpublished research, student or client records, anything under NDA or IRB — to decide whether to delegate the work to a local model on oMLX instead, and how to do it well.
---

# Delegating work to a local model

You have `local_summarize`, `local_rewrite`, `local_classify`, `local_complete`, and
`local_models` available. They run on a model on this machine via oMLX. Nothing sent
to them reaches any cloud API.

They are slower than answering directly and the models are usually weaker. So the
question is not "can I use these" but "must I".

## The test: whose words are these?

Ask who authored the text in front of you.

**Someone else's own words → delegate locally.** A recording or transcript of another
person, a message they wrote, an interview, a student's submission, a client's file, a
colleague's unpublished draft. You are holding it because they gave it to you for a
purpose; sending it to a third-party service is a decision that was never yours to
make on their behalf.

**Your own words → no constraint.** Your notes, your code, your drafts, your published
work. Handle them however is fastest.

**Your derivative of someone else's words → normally no constraint.** Once you have
read a transcript and written your own summary in your own words, that summary is
yours. The raw transcript stays local; what you wrote about it does not have to.

This test extends to cases no list would have covered, which is why it is a better
tool than a list of categories. When it genuinely does not resolve — jointly authored
material, an ambiguous consent scope — treat that ambiguity itself as the answer and
keep it local.

## Three cases the test does not cover

Beyond authorship, delegate locally when:

- **A rule says so.** NDA, IRB protocol, data-processing agreement, employer policy.
  The rule outranks your judgement about whether the content "seems sensitive".
- **The content identifies a living person who is not the user.** Names with medical,
  financial, legal, or disciplinary context. Even your own notes about a third party
  fall here.
- **You are offline or want to stay that way.** A local model works with no network.

## What this costs

Delegation is not free, and pretending otherwise leads to using it for everything and
then abandoning it.

**Cold start.** If the model is not already in memory, the first call loads it —
roughly 17 seconds for a 15 GB 4-bit model, longer for bigger ones. Call
`local_models` first: it reports which models are `loaded`. An already-loaded model
answers in about a second for short work.

**Memory.** A loaded model holds its full weights in unified memory and competes with
everything else running. Loading a 15 GB model on a machine already running a heavy
job can leave the system with almost nothing free. Before delegating a large batch,
consider whether something memory-hungry is running.

**Quality.** Local models are smaller. Two failure modes to watch for, both observed
on a 0.6B model:

- Asked for Traditional Chinese, it mixed Traditional and Simplified within one
  sentence. Asked for a Chinese summary, it answered in English.
- It classified "the effect size was too small and it disappeared after two weeks" as
  *positive*.

Neither happened on a 27B model. **Read what comes back.** If the work matters and the
only available model is small, it may be better to do the work yourself by hand than
to accept an answer you have not checked.

## Using them well

**Reasoning is off by default** in the task-specific tools, because it costs roughly
3.5x the latency for work that rarely needs it. `local_complete` accepts
`thinking: true` for problems that genuinely require working-out. When reasoning is
on, allow generous `max_tokens` — the budget is spent on thinking first, and a tight
cap truncates the answer before it starts.

**Prefer the specific tool over `local_complete`.** `local_summarize`,
`local_rewrite`, and `local_classify` carry defaults tuned for their task, including
instructions that stop the model from prefacing its answer with commentary.

**`local_classify` returns your own category strings.** It matches the model's reply
back onto the list you supplied and reports `matched: false` when nothing lines up,
rather than inventing a category.

**Batch work benefits most.** One summary is barely worth the cold start; forty
transcript segments are exactly what this is for, since the model stays loaded across
the run.

## When the server is not running

Every tool fails with a message naming the fix: start oMLX with `open -a oMLX` (or
`omlx start`). If oMLX is not installed at all, say so plainly rather than silently
falling back to processing the content in the cloud — that fallback is precisely the
outcome the user was trying to avoid.

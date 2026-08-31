# Testing covers both headed and headless

Every test of an interactive entry point covers **both** modes. Headless alone is not a
verification of this product, because this product is an interactive one.

## Why this rule exists

On 2026-09-01, `omlx-claude` was verified end-to-end against oMLX 0.6.4: a local model
answered through Claude Code, exited 0, and passed a multi-step tool-use task (Read →
compute → Write, output checked). All of it through `-p`.

In the same session, `/model` was reported as **untestable** — "it needs an interactive
session, and `-p` has no way to invoke it."

`/model` writing a model id into the operator's real settings is the headline defect of
issue #12, a P0. So the one behaviour the harness could not reach was the exact thing the
most important open issue is about. That is not a coverage percentage; it is a whole
category of behaviour with no harness, and the gap was invisible because everything that
*was* tested came back green.

## Which mode covers what

| | Headless (`-p`) | Headed (PTY) |
|---|---|---|
| Model answers a prompt | ✅ | — |
| Tool calling, multi-step | ✅ | — |
| Exit status, stderr warnings | ✅ | — |
| **Slash commands** (`/model`, `/config`, `/effort`) | ❌ cannot invoke | ✅ |
| **Interactive pickers** (model list, permission prompts) | ❌ | ✅ |
| **Anything that branches on `isatty()`** | ❌ wrong branch | ✅ |
| What a session writes to disk over its lifetime | partial | ✅ |

Use headless where it suffices — it is faster and simpler. Reach for headed the moment the
behaviour under test only exists when a prompt does.

## Driving the headed path

Use a **PTY driver that can read the rendered pane back**. `tmux` is the recommendation,
because read-back is what turns keystroke replay into an assertion.

`tmux` is not installed by default on this machine:

```bash
brew install tmux
```

Shape of a headed test:

```bash
SESSION="omlx-headed-$$"
PROBE=$(mktemp -d)                 # isolated config root — see below, this is mandatory
SCRATCH=$(mktemp -d)               # NOT under ~/.claude — see traps

tmux new-session -d -s "$SESSION" -c "$SCRATCH" \
  "CLAUDE_CONFIG_DIR=$PROBE omlx-claude --model <id>"

# wait for the prompt to actually appear before sending anything
until tmux capture-pane -p -t "$SESSION" | grep -q '<prompt marker>'; do sleep 1; done

tmux send-keys -t "$SESSION" '/model' Enter
sleep 2
tmux capture-pane -p -t "$SESSION" > pane.txt     # assert against this

tmux kill-session -t "$SESSION"
```

`expect` and `screen` ship with macOS and can drive a PTY, so they are acceptable
fallbacks — but they replay keystrokes without giving you the rendered pane back, so the
assertions get weaker. Prefer tmux; say so in the test if you had to use something else.

## Isolation is mandatory, not optional

A headed test runs the exact code path that writes to the operator's real configuration.
That is the defect under test, so the test must not reproduce it on the operator's machine.

Always set `CLAUDE_CONFIG_DIR` to a temp root. It survives the whole
`omlx-claude → omlx launch claude → Claude Code` exec chain — verified through that chain,
not just against `claude` directly (see #12; oMLX's `_scrubbed_env` copies the environment
and drops only three `PYTHON*` keys).

Prove the isolation held rather than assuming it. Hash the real files before and after:

```bash
shasum -a 256 ~/.claude/settings.json ~/.claude.json    # before, and again after
```

## Where headed tests run

`make test-headed`, a target of its own. **It does not exist yet** — creating it is the
implementation of issue #17, of which this rule is the specification half.

**Not** in `make test`. That suite is deliberately hermetic — no network, no oMLX required —
and a headed test needs a live server. Folding one into the other would trade a fast, always-
runnable suite for a slow, environment-dependent one, and the hermetic property is worth more
than the convenience of a single command.

This is the same layer as the hand-verification `CLAUDE.md` already asks for (`make ping` plus
a real tool call before releasing), except automated and repeatable.

## Traps, each one paid for

- **`~/.claude/` is treated as a sensitive path.** Claude Code's permission layer intercepts
  writes anywhere under it. A scratch directory placed there makes the tool call fail for
  reasons that have nothing to do with what you were testing — and the failure looks like the
  model being unable to use tools. Put scratch dirs somewhere else.
- **A skip is not a pass.** Already recorded in `CLAUDE.md` for the signing tests, and it
  applies with more force here: a headed test that silently skips when tmux is missing leaves
  the whole category unverified while the suite still exits 0. Count skips, print them, and
  make `REQUIRE_FULL_SUITE=1` turn any skip into a failure on a release path.
- **Waiting a fixed number of seconds is not waiting for the prompt.** Cold-loading a model
  can take minutes. Poll `capture-pane` for a marker; do not `sleep 5` and hope.
- **Green headless is not end-to-end.** It is one half, and it is the half that cannot see the
  defects this repo's open issues are mostly about. Say which mode a result came from when
  reporting it.

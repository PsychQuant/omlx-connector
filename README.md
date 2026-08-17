# omlx-connector

Connects [oMLX](https://github.com/jundot/omlx) to Claude Code, so that content which
must not leave your machine never reaches a cloud API. One install, two ways to use
it — as the agent, or as a tool the agent calls.

```bash
omlx-claude --model <model-id>   # the local model answers you
```
```
local_summarize, local_rewrite, local_classify, …   # Claude answers, and hands over
                                                    # what must stay local
```

## Two ways to use a local model

The question that separates them is **who answers you**.

| | **Usage 1** | **Usage 2** |
|---|---|---|
| How you start it | `omlx-claude` | the MCP server's five tools |
| **Who answers you** | **the local model** | **Claude** |
| The local model is | the agent itself | a tool the agent calls |
| Claude involved? | no | yes |
| Works offline | yes | no (the agent still needs the network) |
| What you give up | frontier-model reasoning | nothing, except latency on the delegated part |

Both arrive together. Installing the plugin puts `omlx-claude` on your `PATH` and
registers the MCP server; you do not choose between them at install time.

**Usage 1 — the local model is the agent.** Claude Code becomes an interface to
Qwen (or whatever you loaded). Nothing you type reaches Anthropic. Everything runs
at the local model's ability, which is the real cost: see
[Choosing a model](#choosing-a-model) for two failure modes that are easy to miss.

**Usage 2 — Claude answers, and hands over what must stay local.** This is what the
MCP server does. You keep frontier-model reasoning for the work that benefits from
it, and route only the material that cannot leave the machine to oMLX.

```
Usage 1                          Usage 2
                                 Claude Code  (cloud model)
Claude Code  ──▶  oMLX                 │  MCP tool call
   (the CLI)      (answers you)        ▼
                                  omlx-connector ──▶ oMLX
                                       │
                                       └─ only this part stays local
```

The motivating case for usage 2: material you are contractually or ethically barred
from sending to a third party — recordings and transcripts of other people,
unpublished research, student or client records — but which still needs summarizing,
cleaning up, or sorting. Usage 1 would also keep it local, but at the price of doing
*all* your work on the smaller model.

### What `omlx-claude` does that `omlx launch claude` does not

`omlx launch claude` is oMLX's own command, and `omlx-claude` **execs into it** —
this is a layer on top, not a replacement. oMLX's integration carries knowledge that
keeps moving (tier mapping, the auto-compact denominator, the LSP prefix-cache
footgun, the telemetry trade-off), and reimplementing that here would fork it and
then let it rot.

What the layer adds:

- **A settings override that survives your own settings.** The launcher passes its
  configuration as environment variables, but Claude Code ranks a settings-file
  `env` block above inherited environment. If your `~/.claude/settings.json` sets
  `ANTHROPIC_BASE_URL` — any gateway, proxy, or rate-limiting plugin does — the
  launcher's value is silently overridden, requests leave for whatever that points
  at, and you get `401 Invalid bearer token` while the oMLX log shows nothing
  arrived ([jundot/omlx#2715](https://github.com/jundot/omlx/issues/2715)).
  `omlx-claude` re-asserts those keys through `--settings`, a CLI argument, which
  outranks user settings and applies to that launch only. Your own config is never
  modified.
- **More than the endpoint.** `API_TIMEOUT_MS` is in the override too, and it is not
  decoration: the launcher sets it to 3,000,000 because a cold model load alone can
  outlast a normal timeout, and a settings file that shadows it aborts inference
  mid-generation.
- **Honesty about what it cannot cover.** Some of what the launcher sets depends on
  which model oMLX ends up serving — the tier defaults, the context window. Those
  cannot be re-asserted from outside without reimplementing oMLX's model selection,
  so instead the command *names* them when your settings would shadow them. A
  warning beats silence about a key nobody controls.
- **A preflight against the right address.** `--host` and `--port` are read (not
  consumed — they still belong to oMLX) so that the reachability check probes the
  server the launcher is about to use.
- **An expiry notice.** It records the oMLX version this workaround was last read
  against and says so when yours is newer, so "upstream may have fixed this" is
  something the tool tells you rather than something you have to remember.

It will keep existing after
[#2715](https://github.com/jundot/omlx/issues/2715) and
[#2716](https://github.com/jundot/omlx/issues/2716) are fixed — distribution, the
preflight, and the wider override are worth having on their own — but it should not
quietly keep asserting a workaround against a version nobody checked. Hence the
notice.

## The loopback guarantee

The server **refuses to send anything to a non-loopback host**:

```
$ OMLX_BASE_URL=https://api.example.com OmlxConnectorMCP --ping
OmlxConnectorMCP: Refusing to send content to non-loopback host 'api.example.com'.
This server exists so that content stays on this machine. If 'api.example.com' is a
machine you own and you intend to send content there, set OMLX_ALLOW_REMOTE=1.
```

This is enforced in code rather than promised in documentation, because a privacy
property that depends on nobody mis-editing a config file is not a privacy property.
`OMLX_ALLOW_REMOTE=1` exists for the one legitimate exception — an oMLX instance on
another machine you own — and requires a deliberate act to enable.

## Requirements

- macOS 14+, Apple silicon
- [oMLX](https://github.com/jundot/omlx) running locally, with at least one model
- Swift 5.9+ to build from source

## Install

### Claude Code (recommended)

```bash
claude plugin marketplace add PsychQuant/omlx-connector
claude plugin install omlx-connector@omlx-connector
```

The plugin fetches the signed binary on first use and keeps it pinned to the
plugin's version. Restart Claude Code afterwards so the server loads.

### Claude Desktop

Download `omlx-connector-<version>.mcpb` from
[Releases](https://github.com/PsychQuant/omlx-connector/releases/latest) and open it.
The bundle carries the signed binary, so there is nothing else to install.

### Manual

The release binary is signed with a Developer ID and notarized by Apple, so it runs
without a Gatekeeper prompt.

```bash
curl -sL https://github.com/PsychQuant/omlx-connector/releases/latest/download/OmlxConnectorMCP \
  -o ~/bin/OmlxConnectorMCP
chmod +x ~/bin/OmlxConnectorMCP
OmlxConnectorMCP --ping
```

Expected output:

```
OmlxConnectorMCP 0.1.0
server:  http://127.0.0.1:8000 — reachable
models:  41 available
loaded:  none (first call will pay a cold start)
```

Then register it:

```bash
claude mcp add omlx -- ~/bin/OmlxConnectorMCP
```

### Codex

In `~/.codex/config.toml`:

```toml
[mcp_servers.omlx]
command = "/Users/you/bin/OmlxConnectorMCP"
args = []
```

The same server serves both clients; nothing extra is needed for Codex.

### From source

```bash
git clone https://github.com/PsychQuant/omlx-connector.git
cd omlx-connector
make install     # builds and ad-hoc signs into ~/bin
make test
```

### Usage 1 — running the agent itself on a local model

```bash
omlx-claude --model <model-id>
```

Where it comes from depends on how you installed:

| Install route | Gets `omlx-claude`? |
|---|---|
| Plugin (marketplace) | **Yes** — a session-start hook keeps `~/bin/omlx-claude` current |
| From a clone | `make install-omlx-claude` |
| Release asset | download `omlx-claude`, `chmod +x`, put it on your `PATH` |
| `.mcpb` bundle (Claude Desktop) | **No** — see below |

**The `.mcpb` bundle ships the MCP server only.** Claude Desktop has no terminal for
a command to be typed into, so a launcher inside the bundle would be weight nobody
could reach. If you installed that way and are looking for `omlx-claude`, nothing is
broken — take it from the release assets instead.

`~/bin` must be on your `PATH` for the command to be found. The plugin's hook checks
and tells you if it is not; installed-but-unreachable otherwise reads as a failed
install.

> `bin/claude-local` is the former name of this command. It still forwards, prints a
> deprecation notice, and **is removed in 0.4.0**.

The model must have a context window of **at least 48K** — Claude Code refuses
smaller ones outright, which rules out some otherwise capable models (`Qwen3-32B` is
40,960 and cannot be used). Run `local_models`, or check `max_context_window` at
`/v1/models/status`, before picking.

## Tools

| Tool | Purpose |
|---|---|
| `local_summarize` | Summarize, with a sentence budget and optional focus |
| `local_rewrite` | Rewrite per an instruction — ASR cleanup, tone, formatting |
| `local_classify` | Assign text to one of a set of categories |
| `local_complete` | Arbitrary prompt; the escape hatch |
| `local_models` | List available models, context windows, and what is loaded |

The Claude Code plugin also ships a `local-delegation` skill, which gives the agent a
test for deciding *when* work belongs on a local model rather than leaving it to
guess from tool names. The short version: ask whose words the text is. Someone else's
own words — a recording of them, a message they wrote, their submission or file — were
given to you for a purpose, and sending them to a third-party service is not a
decision you can make on their behalf. Your own writing, and your own summary of
theirs, carry no such constraint.

### Reasoning is off by default

Reasoning-capable models cost several times the latency for it. Measured on
Qwen3.8-27B, already loaded:

| | Latency | Output |
|---|---:|---|
| reasoning on | 6.0 s | 326 chars of thinking + 34 chars of answer |
| reasoning off | **1.7 s** | the answer, of comparable quality |

So `local_summarize` / `local_rewrite` / `local_classify` disable it, and
`local_complete` takes `thinking: true` when a task genuinely needs working-out.
When reasoning is on, the model's thinking is returned separately in a `reasoning`
field rather than mixed into the answer.

One consequence worth knowing: with reasoning on, `max_tokens` must be well above
the expected answer length, or the budget is consumed by thinking and the answer is
truncated before it starts.

## Choosing a model

**Model size matters more here than for a cloud agent, because you see the raw
output.** Two failure modes show up on small models and are worth checking before
you trust a model with real work:

- **Script and register drift in CJK.** A 0.6B model asked for Traditional Chinese
  returned a mix of Traditional and Simplified within one sentence. Larger models
  (27B class) did not. If you write in Traditional Chinese, test this explicitly.
- **Shallow judgement on classification.** The same 0.6B model classified "the
  effect size was too small and it disappeared after two weeks" as *positive*.

Use `local_models` to see what is available. A model already loaded answers
immediately; a cold one pays a load first — roughly 17 s for a 15 GB 4-bit model on
Apple silicon, longer for bigger ones.

**Memory is the real constraint.** A loaded model holds its full weights in unified
memory and competes with everything else you are running. Loading a 15 GB model
while a document-conversion job was running took this machine from 17 GB free to
334 MB. If you use this alongside memory-hungry work, either pin a small model or
unload between sessions:

```bash
curl -X POST http://127.0.0.1:8000/v1/models/<model-id>/unload
```

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `OMLX_BASE_URL` | `http://127.0.0.1:8000` | oMLX server. Non-loopback refused unless `OMLX_ALLOW_REMOTE=1` |
| `OMLX_ALLOW_REMOTE` | unset | Set to `1` to permit a non-loopback host you own |
| `OMLX_MODEL` | unset | Default model id. If unset, the first loaded model is used, else the first available |
| `OMLX_TIMEOUT` | `120` | Per-request timeout in seconds. Cold starts need headroom |
| `OMLX_CONNECTOR_NO_BANNER` | unset | Suppress the stderr startup line |

`127.0.0.1` is the default rather than `localhost` because the latter can resolve to
`::1` first, which a server bound only to IPv4 will refuse.

## Signing & notarization

`make install` signs ad-hoc, which is fine on the machine that built it. For
distribution:

```bash
export DEVELOPER_ID="<Developer ID certificate SHA-1>"
export NOTARY_PROFILE="<notarytool keychain profile>"
make release-signed
```

Both binaries are signed and go to Apple in a single notarization submission, so
the second one costs no extra round-trip. The script prints the exact
`gh release create` line; every asset it names is matched downstream by filename,
so leaving one out surfaces as a download error pointing nowhere useful.

## Related

Two upstream issues, found while building usage 1, are why `omlx-claude` overrides
what it overrides. They are filed against oMLX and remain open:

- [jundot/omlx#2715](https://github.com/jundot/omlx/issues/2715) — `ANTHROPIC_BASE_URL`
  set by the launcher is silently overridden by a `~/.claude/settings.json` `env`
  block, producing a 401 whose request never reaches the server
- [jundot/omlx#2716](https://github.com/jundot/omlx/issues/2716) —
  `CLAUDE_CODE_MAX_CONTEXT_TOKENS` is ignored when the model ID carries a `[1m]`
  suffix, which happens on plans where Opus is auto-upgraded to 1M context

## License

MIT

# omlx-connector

An MCP server that lets Claude Code, Codex, and other MCP clients delegate text work
to a model running on **your own machine** via [oMLX](https://github.com/jundot/omlx),
so that content which must not leave the machine never reaches a cloud API.

## What this is (and what it is not)

There are two ways to combine a coding agent with a local model, and they point in
opposite directions.

**Running the agent itself on a local model** is what `omlx launch claude` does. That
is not this project.

**Delegating specific tasks to a local model** is this project. The agent keeps
running on whatever frontier model you normally use; only the pieces that must stay
on your hardware are routed to oMLX.

```
Claude Code / Codex  (cloud model)
        │
        │  MCP tool call
        ▼
   omlx-connector  ──HTTP──▶  127.0.0.1:8000 (oMLX)  ──▶  local model
        │
        └─ the content never leaves this machine
```

The motivating case: material you are contractually or ethically barred from sending
to a third party — recordings and transcripts of other people, unpublished research,
student or client records — but which still needs summarizing, cleaning up, or sorting.

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

## Tools

| Tool | Purpose |
|---|---|
| `local_summarize` | Summarize, with a sentence budget and optional focus |
| `local_rewrite` | Rewrite per an instruction — ASR cleanup, tone, formatting |
| `local_classify` | Assign text to one of a set of categories |
| `local_complete` | Arbitrary prompt; the escape hatch |
| `local_models` | List available models, context windows, and what is loaded |

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

## Related

`omlx launch claude` — running the agent itself on a local model — is a separate
concern handled upstream. Two issues found while setting that up are filed there:

- [jundot/omlx#2715](https://github.com/jundot/omlx/issues/2715) — `ANTHROPIC_BASE_URL`
  set by the launcher is silently overridden by a `~/.claude/settings.json` `env`
  block, producing a 401 whose request never reaches the server
- [jundot/omlx#2716](https://github.com/jundot/omlx/issues/2716) —
  `CLAUDE_CODE_MAX_CONTEXT_TOKENS` is ignored when the model ID carries a `[1m]`
  suffix, which happens on plans where Opus is auto-upgraded to 1M context

## License

MIT

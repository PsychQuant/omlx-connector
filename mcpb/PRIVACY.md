# Privacy

This server exists so that text you process does not leave your machine. That claim is
worth stating precisely.

## Where your content goes

Text passed to any tool is sent over HTTP to an oMLX server, which by default is
`http://127.0.0.1:8000` — a loopback address on the same machine. It never leaves the
host.

The server **refuses to start** if `OMLX_BASE_URL` names a non-loopback host, unless
`OMLX_ALLOW_REMOTE=1` is also set. That check is in the code, not in a configuration
file that could be edited by accident:

```
Refusing to send content to non-loopback host 'example.com'. This server exists so
that content stays on this machine. If 'example.com' is a machine you own and you
intend to send content there, set OMLX_ALLOW_REMOTE=1.
```

If you do set `OMLX_ALLOW_REMOTE=1`, content travels to whatever host you named, over
plain HTTP. The guarantee then becomes whatever that host and network provide. Only
use it for a machine you control on a network you trust.

## What is collected

Nothing. This server has no telemetry, no analytics, no crash reporting, and no
usage counters. It makes exactly two kinds of outbound request:

1. To the configured oMLX server, to list models and run completions.
2. Nothing else.

The plugin wrapper (`omlx-connector-wrapper.sh`, used only in the Claude Code plugin
distribution, not in this bundle) contacts `api.github.com` and
`objects.githubusercontent.com` to download the binary when it is missing or outdated.
That request carries no content — only the version being fetched. This MCPB bundle
ships the binary inside it and makes no such request.

## What is stored

Nothing by this server. It holds no state between calls and writes no files.

The oMLX server it talks to may cache model state on disk (its KV cache), governed by
oMLX's own settings, not by this server. See
[oMLX](https://github.com/jundot/omlx) for how that cache works and where it lives.

## What is logged

A single startup line to stderr naming the version and configured base URL, which the
host application may capture in its logs. Suppress it with
`OMLX_CONNECTOR_NO_BANNER=1`.

Error messages may quote responses from the oMLX server. These are sanitized of
control characters before display, and bounded in length. Your input text is not
echoed into error messages.

## Third parties

None. Apple notarizes the released binary, which means Apple has seen the compiled
binary — not your data.

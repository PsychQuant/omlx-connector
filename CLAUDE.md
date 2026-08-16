# omlx-connector

An MCP server that lets an agent delegate text work to a local model served by
[oMLX](https://github.com/jundot/omlx), plus a wrapper for the opposite arrangement.

## The distinction that organizes this repo

Two ways to combine Claude Code with a local model. They are easy to conflate, and
conflating them leads to reasoning about one from measurements of the other. The
axis is **who answers the user**.

| | **Usage 1** | **Usage 2** |
|---|---|---|
| Entry point | `omlx launch claude` / `bin/claude-local` | the MCP server (`Sources/`) |
| Who answers | the local model | Claude |
| The local model is | the agent | a tool the agent calls |
| This repo ships | a workaround wrapper | the actual product |

**Usage 2 is what this project is.** Usage 1 belongs to oMLX; `bin/claude-local`
exists only because the official path breaks for a common configuration, and it
should be deleted once [#2715](https://github.com/jundot/omlx/issues/2715) and
[#2716](https://github.com/jundot/omlx/issues/2716) are fixed. Do not grow features
into it.

## Version consistency is enforced, and for a reason

`Sources/OmlxConnectorMCP/Version.swift` is the single source of truth. Three files
mirror it, and `scripts/build-release.sh` **fails the build** if any disagrees:

- `plugin/.claude-plugin/plugin.json`
- `.claude-plugin/marketplace.json`
- `mcpb/manifest.json`

This is not tidiness. The plugin wrapper resolves the release tag from
`plugin.json`'s version, so a mismatch sends users to a tag whose asset does not
exist — and the failure surfaces as a download error pointing nowhere useful.

The same script also checks that `AppVersion.mcpServerName` equals the mcpb
manifest's `name`. **Claude Desktop silently drops a server on that mismatch** — no
error, the tools just never appear.

## Architecture

```
main.swift          flags, config resolution, startup guards
Server.swift        tool definitions + handlers (dispatch is `internal`, tests assert coverage)
OmlxClient.swift    actor; single HTTP choke point; loopback enforcement
ResponseFormatting  formatJSON / error sanitization / TrustedErrorMessage
Version.swift       single source of truth
```

Conventions worth keeping:

- **Handlers return `String`**, never `CallTool.Result`. Keeps the tool logic
  testable without the MCP layer.
- **All HTTP goes through one `request()`** in `OmlxClient`. Error translation
  (notably connection-refused → an actionable message) lives there and nowhere else.
- **`formatJSON` pre-checks `isValidJSONObject`.** `JSONSerialization` raises an
  ObjC exception on a `Date`/NaN/non-string key, which Swift cannot catch — it takes
  down the process. The check is load-bearing.
- **`TrustedErrorMessage`** marks errors whose text we authored. Anything else
  (notably `URLError`) is sanitized before display; system-generated strings are not
  trusted into logs.

## The loopback constraint

`OmlxConfig.resolveBaseURL` refuses non-loopback hosts unless `OMLX_ALLOW_REMOTE=1`.
This is the one invariant that cannot regress: the entire premise is that content
stays on the machine. Tests cover it, including that the opt-in accepts *only* `1`
(so a stray `true` does not open the door).

Any change touching config resolution should keep those tests passing without
weakening them.

## Build and release

```bash
make build / make test / make ping
make install                      # ad-hoc signed into ~/bin, dev only

export DEVELOPER_ID="<cert SHA-1>"
export NOTARY_PROFILE="<notarytool keychain profile>"
make release-signed               # build → sign → notarize → pack mcpb
```

arm64 only, deliberately: oMLX requires Apple silicon, so an x86_64 slice could
never reach a working server.

After `release-signed`, publish with the four assets it names — the bare binary
(the wrapper matches it by exact filename), its `.sha256`, the `.mcpb`, and that
bundle's `.sha256`.

## Testing notes

The suite is fast and hermetic — no network, no oMLX required. `StubClient` fakes
the `OmlxClienting` protocol. When adding a tool, add it to `defineTools()` and to
`executeToolCall`; `testEveryDeclaredToolDispatches` will catch the second if you
forget it.

What the tests do *not* cover: anything requiring a live oMLX server. Verify those
by hand with `make ping` and a real tool call before releasing.

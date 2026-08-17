# omlx-connector

One module connecting [oMLX](https://github.com/jundot/omlx) to Claude Code, with
two entry points: `omlx-claude` (the local model is the agent) and
`OmlxConnectorMCP` (Claude calls the local model as a tool).

## The distinction that organizes this repo

Two ways to combine Claude Code with a local model. They are easy to conflate, and
conflating them leads to reasoning about one from measurements of the other. The
axis is **who answers the user**.

| | **Usage 1** | **Usage 2** |
|---|---|---|
| Entry point | `omlx-claude` (`Sources/OmlxClaude/`) | `OmlxConnectorMCP` (`Sources/OmlxConnectorMCP/`) |
| Who answers | the local model | Claude |
| The local model is | the agent | a tool the agent calls |

**Both are the product.** They share `Sources/OmlxConnectorCore/`, one version, one
release, and one plugin install. Capability measured under one does not transfer to
the other: usage 1 requires the local model to plan its own tool use, usage 2 does
not.

Distribution is not symmetric, and the asymmetry is load-bearing rather than an
oversight: the `.mcpb` bundle carries the MCP server alone, because Claude Desktop
has no terminal for a command to be typed into. Say so wherever install is
described — someone who installs the bundle and cannot find `omlx-claude` will
otherwise conclude the install failed.

### `omlx-claude` is a layer, not a replacement

It **execs `omlx launch claude`**. oMLX's integration sets a dozen environment
variables carrying knowledge that keeps moving — tier mapping, the auto-compact
denominator, the LSP prefix-cache footgun, the telemetry trade-off. Reimplementing
any of that here forks it and then lets it rot. Changes to this command should keep
the exec at the end.

The settings override splits deliberately in two, and the split is the interesting
part. Keys we can determine independently are re-asserted through `--settings` (a
CLI argument, so it outranks the user's `settings.json` — that is the whole
mechanism against [#2715](https://github.com/jundot/omlx/issues/2715)). Keys whose
values depend on which model oMLX ends up serving are **reported, not guessed**: see
`LaunchSettings.modelDependentKeys`. Moving one from the second list to the first
means reimplementing oMLX's model selection, which is the fork above.

### It keeps existing after upstream is fixed, and says so itself

[#2715](https://github.com/jundot/omlx/issues/2715) and
[#2716](https://github.com/jundot/omlx/issues/2716) being fixed does not retire this
command — it also carries distribution, the preflight, and a wider override than the
launcher's own keys. But it must not quietly keep asserting a workaround against a
version nobody checked.

`UpstreamWorkaround.lastVerifiedOmlxVersion` is that mechanism. It records the oMLX
release the workaround was **read against**, and the command speaks up when the
installed one is newer. Deliberately not a "fixed in version X" constant: that
number does not exist while the bugs are open, and filling it in later is the act of
remembering this mechanism exists to remove.

**Bump it only after re-reading `integrations/claude.py` and `cli.py` in the
installed oMLX**, not merely after confirming a launch still works.

## Version consistency is enforced, and for a reason

`Sources/OmlxConnectorCore/Version.swift` is the single source of truth, shared by
both executables. Three files mirror it, and `scripts/build-release.sh` **fails the
build** if any disagrees:

- `plugin/.claude-plugin/plugin.json`
- `.claude-plugin/marketplace.json`
- `mcpb/manifest.json`

This is not tidiness. The plugin wrapper resolves the release tag from
`plugin.json`'s version, so a mismatch sends users to a tag whose asset does not
exist — and the failure surfaces as a download error pointing nowhere useful.

The same script also checks that `MCPIdentity.mcpServerName` equals the mcpb
manifest's `name`. **Claude Desktop silently drops a server on that mismatch** — no
error, the tools just never appear.

Both greps address files by path. Moving either one without updating the script
leaves a revision where the release build necessarily fails.

## Architecture

```
Sources/OmlxConnectorCore/          shared by both executables — keep it small
  Version.swift                     single source of truth for the version
  UpstreamWorkaround.swift          verified-baseline check + version ordering

Sources/OmlxConnectorMCP/           usage 2 — Claude calls the local model
  main.swift                        flags, config resolution, startup guards
  Identity.swift                    binary name, MCP serverInfo.name, help text
  Server.swift                      tool definitions + handlers (dispatch is `internal`, tests assert coverage)
  OmlxClient.swift                  actor; single HTTP choke point; loopback enforcement
  ResponseFormatting.swift          formatJSON / error sanitization / TrustedErrorMessage

Sources/OmlxClaude/                 usage 1 — the local model is the agent
  main.swift                        preflight, staleness notice, exec into omlx launch
  LaunchSettings.swift              what the --settings override covers, and what it only reports
  ProbeTarget.swift                 reads --host/--port without consuming them
  Help.swift                        command name + help text
```

**Core stays small on purpose.** It holds what more than one executable needs and
nothing else. Adding a type here means widening its access level for every caller,
and an earlier draft that moved `OmlxClient` and `ResponseFormatting` in would have
made twelve types public to serve one caller. Identity belonging to a single command
goes the other way, into that command's own target.

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
make install                      # MCP server, ad-hoc signed into ~/bin, dev only
make install-omlx-claude          # usage-1 command, same deal

export DEVELOPER_ID="<cert SHA-1>"
export NOTARY_PROFILE="<notarytool keychain profile>"
make release-signed               # build → sign → notarize → pack mcpb
```

arm64 only, deliberately: oMLX requires Apple silicon, so an x86_64 slice could
never reach a working server.

After `release-signed`, publish with the **six** assets it names — both bare
binaries, their `.sha256` files, the `.mcpb`, and that bundle's `.sha256`. The
script prints the exact command. Every one of those is matched downstream by exact
filename (`plugin/bin/omlx-connector-wrapper.sh` and `plugin/hooks/session-start.sh`
each look up their own), so an omission surfaces as a download error pointing
nowhere useful.

Both binaries go to Apple in one notarization submission: it notarizes every Mach-O
in the archive, so the second costs no extra round-trip.

## Testing notes

The suite is fast and hermetic — no network, no oMLX required. `StubClient` fakes
the `OmlxClienting` protocol. When adding a tool, add it to `defineTools()` and to
`executeToolCall`; `testEveryDeclaredToolDispatches` will catch the second if you
forget it.

What the tests do *not* cover: anything requiring a live oMLX server. Verify those
by hand with `make ping` and a real tool call before releasing.

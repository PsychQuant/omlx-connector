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
mechanism against [#2715](https://github.com/jundot/omlx/issues/2715)). **It does not
outrank managed/MDM policy settings**, which sit above command-line arguments; on a
managed Mac #2715 is not worked around and the loopback gate will have verified an address
the session does not use. Those paths are scanned so the conflict is at least named — see
`LaunchSettings.settingsScopePaths`. Any text here claiming `--settings` "outranks
everything" is wrong; five such claims had to be corrected at once.) Keys whose
values depend on which model oMLX ends up serving are **reported, not guessed**: see
`LaunchSettings.modelDependentKeys`. Moving one from the second list to the first
means reimplementing oMLX's model selection, which is the fork above.

### What it actually works around, and what it only tracks

[#2715](https://github.com/jundot/omlx/issues/2715) **is** worked around, by the
`--settings` override. [#2716](https://github.com/jundot/omlx/issues/2716) **is not**:
the launch sets `CLAUDE_CODE_DISABLE_1M_CONTEXT`, which Claude Code honours only for
model ids it recognizes, and oMLX-served ids never are. The key is kept because it is
correct if one ever is, and inert otherwise — but **nothing may describe it as the
fix**. Claude Code prints its own warning saying so at startup. Tracked in issue #6.

That distinction was not free. The first cut of this command shipped the key with
README, help text and source comments all calling it the #2716 workaround, while the
end-to-end run that would have disproved it had already been done — the warning was in
the output and went unread. The mechanism was harmless; the claim was the defect.

### It keeps existing after upstream is fixed, and says so itself

Either issue being fixed does not retire this command — it also carries distribution,
the preflight, and a wider override than the launcher's own keys. But it must not
quietly keep asserting a workaround against a version nobody checked.

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
  LoopbackPolicy.swift              the invariant, shared by every entry point

Sources/OmlxConnectorMCP/           usage 2 — Claude calls the local model
  main.swift                        flags, config resolution, startup guards
  Identity.swift                    binary name, MCP serverInfo.name, help text
  Server.swift                      tool definitions + handlers (dispatch is `internal`, tests assert coverage)
  OmlxClient.swift                  actor; single HTTP choke point; loopback enforcement
  ResponseFormatting.swift          formatJSON / error sanitization / TrustedErrorMessage

Sources/OmlxClaude/                 usage 1 — the local model is the agent
  main.swift                        preflight, staleness notice, exec into omlx launch
  LaunchSettings.swift              what the --settings override covers, and what it only reports
  ProbeTarget.swift                 address + credential resolution, loopback gate, argparse-compatible flag scan
  Help.swift                        command name + help text

plugin/bin/                         distribution — one download path, two callers
  fetch-release-binary.sh           resolve → download → verify → atomic install
  verify-download.sh                checksum + Developer ID requirement; refuses on either
  omlx-connector-wrapper.sh         MCP server entry: delegates, then execs
plugin/hooks/session-start.sh       usage-1 entry: delegates, then reports PATH state
```

**Neither caller downloads anything itself.** They pass a binary name to
`fetch-release-binary.sh` and that is all. This shape is not a preference — see
"one call site at a time" below.

**Core stays small on purpose.** It holds what more than one executable needs and
nothing else. Adding a type here means widening its access level for every caller,
and an earlier draft that moved `OmlxClient` and `ResponseFormatting` in would have
made twelve types public to serve one caller. Identity belonging to a single command
goes the other way, into that command's own target.

"Small" is not the same as "minimal", and the difference cost a regression. Keeping
`OmlxClient` out was right — twelve public types to serve one caller is a bad trade.
Keeping `LoopbackPolicy` out was wrong, and not because of where the line was drawn but
because of what it was drawn on: the test is **who depends on this**, not how big it is.
An invariant both commands are supposed to enforce belongs here no matter how few lines
it takes, and it went unnoticed precisely because it was small enough to look like it
did not qualify.

Conventions worth keeping:

- **Handlers return `String`**, never `CallTool.Result`. Keeps the tool logic
  testable without the MCP layer.
- **All HTTP goes through one `request()`** in `OmlxClient`. Error translation
  (notably connection-refused → an actionable message) lives there and nowhere else.
- **`formatJSON` pre-checks `isValidJSONObject`.** `JSONSerialization` raises an
  ObjC exception on a `Date`/NaN/non-string key, which Swift cannot catch — it takes
  down the process. The check is load-bearing.
- **`ProbeTarget` matches oMLX's argparse, not our idea of it.** Last occurrence wins,
  unambiguous prefixes count (`--ho` is `--host`), nothing past `--` is read. This is
  not politeness: the resolved address is written into `ANTHROPIC_BASE_URL`, so parsing
  a flag differently from oMLX means content leaving for a host oMLX is not serving. The
  full option set is listed in `omlxOptions` because prefix matching needs to know the
  options we *don't* care about too — otherwise `--ha` (haiku) looks like a prefix of
  `--host`.
- **`TrustedErrorMessage`** marks errors whose text we authored. Anything else
  (notably `URLError`) is sanitized before display; system-generated strings are not
  trusted into logs.

## The loopback constraint

`LoopbackPolicy` in `OmlxConnectorCore` refuses non-loopback hosts unless
`OMLX_ALLOW_REMOTE=1`. This is the one invariant that cannot regress: the entire
premise is that content stays on the machine. Tests cover it, including that the opt-in
accepts *only* `1` (so a stray `true` does not open the door).

**It requires the address in canonical form.** Two rounds got this wrong in two
different ways, and the second one is the instructive one.

`hasPrefix("127.")` was a text check, and RFC 1123 permits a DNS label to begin with a
digit — so `127.evil.example` is an ordinary registrable name that satisfied it, and
reviewers demonstrated it passing on both binaries.

The replacement parsed with `inet_pton`, and the doc here then claimed the whole class was
gone. **It was not.** BSD's `inet_pton` reads a leading-zero field as decimal while the
resolver and Claude Code's URL parser read it as octal, so `0127.13.37.42` passed as
127.13.37.42 and content went to 87.13.37.42. One spelling-sensitive parser for another —
and the preflight made it worse, because URLSession agrees with `inet_pton` and reported
success against the real local server on the way past.

So the check is now: parse, print back with `inet_ntop`, require equality. Any spelling
two parsers could read differently fails the round-trip, which is a property rather than a
list of examples. `::1` is compared by bytes, not text, because `0:0:0:0:0:0:0:1` is a
form people write and every parser agrees on — a strict text round-trip there would
reintroduce the over-strictness the old string equality had.

**Do not write "this removes the whole class" here again.** That sentence, added the round
before the octal defect was found, is what made the octal defect hard to see: a reader
checking whether spellings were handled found an assurance where a check should have been.

DNS is deliberately not consulted: resolving the name would make the answer depend on a
lookup that can differ between the check and the connection that follows. A name is not
this machine unless it is the literal `localhost`.

**Every entry point must go through it.** `OmlxConfig.resolveBaseURL` does, for the MCP
server; `ProbeTarget.resolveChecked` does, for the launcher. Adding a third path that
resolves an address without consulting the policy reopens the hole described next.

### It was already regressed once, and how that happened is worth keeping

`omlx-claude` shipped without any loopback check. A grep for the policy over
`Sources/OmlxClaude/` returned one line — a comment *mentioning* it. Four independent
reviewers found this in a single pass; `OMLX_URL=https://external.example/api` resolved
cleanly and would have been asserted into `ANTHROPIC_BASE_URL`, which outranks
everything, taking the whole session and the bearer token with it.

Two things made it possible, and both are structural rather than careless:

1. **The policy lived in the MCP target.** A second entry point could not reach it
   without either moving it or copying it, and neither happened — so the invariant was
   enforced in the half of the module that had always had it.
2. **A fix for a different bug pinned the hole as correct.** An earlier round fixed
   `OMLX_URL` losing its scheme, and the regression test it added asserted that
   `https://server.example:8443/api` resolves. That is a true statement about URL
   assembly and a false statement about policy, and it was sitting in the suite reading
   like approval.

The lesson for future work here: a test that uses a remote address as a *fixture* must
opt in explicitly (`OMLX_ALLOW_REMOTE=1`), so that it cannot be mistaken for a statement
that remote addresses are acceptable. `ProbeTargetResolveTests` does this deliberately.

Any change touching address resolution should keep those tests passing without
weakening them.

## Build and release

```bash
make build / make test / make ping   # test = Swift suite + shell suites, both required
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

`make test` also runs `scripts/tests/*.test.sh`. Those are not extras — the two things
they assert cannot be expressed in the Swift suite: that `verify-download.sh` refuses a
binary forging `TeamIdentifier` in `codesign` output, and that **no** script under
`plugin/` downloads or execs without going through the shared fetcher.

What the tests do *not* cover: anything requiring a live oMLX server. Verify those
by hand with `make ping` and a real tool call before releasing.

### Write the test so it can fail

Three consecutive review rounds here found fixes shipped with tests that could not fail
on the defect they were for. Each time the fixtures were drawn from the same mental
model as the code, so they could not disconfirm it:

- the IPv6 fix bracketed anything containing a colon; its two fixtures were `a b c` and
  `a|b`, both colon-free.
- the loopback fix matched `hasPrefix("127.")`; every near-miss fixture broke on the
  character right after `127` (`127x.`, `1270.`), so none put a legitimate dot there.

Run the new test against the old code and watch it fail *before* writing the fix. Two
mistakes in the round-3 fixes were caught this way and never shipped.

**A check that refuses everything passes every negative test.** The round-3 signature
requirement was briefly malformed — codesign read it as a path and rejected all input.
Eight "refuses X" cases stayed green; only the one positive case, "accepts a genuinely
signed binary", noticed. Any gate needs at least one test that it must *not* refuse.

**A skip is not a pass, and a test that constructs a fixture must assert it.** Round 4
found both, in the tests written for the rule above:

- that positive case *skipped* without `DEVELOPER_ID` and the suite still exited 0, so
  the one guard against "refuses everything" was silently absent in CI. Skips are now
  counted and printed, and `REQUIRE_FULL_SUITE=1` turns any skip into a failure. Set it
  on a release path.
- the forgery case discarded `codesign`'s exit status. Had codesign ever refused the
  embedded newline, the fixture would have been merely *unsigned*, refused for that
  instead, and the case would have printed `ok` forever while defending nothing. Building
  a fixture is part of the assertion: check that it succeeded, and that it has the
  property it exists to have.

### Fix the property, not the file

Round 2 rated an unverified download CRITICAL. It was fixed in the file the report
named, and round 3 found the sibling downloader in the same plugin — same release, other
binary — still doing every one of the same things.

`scripts/tests/no-unverified-download.test.sh` asserts the property instead: it scans
every shipped script and fails if any of them downloads or execs outside the shared
path. A third downloader added later goes red on its own, with nobody remembering to
extend the test.

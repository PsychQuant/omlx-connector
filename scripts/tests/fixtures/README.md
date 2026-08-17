# Adversarial fixtures for `no-unverified-download.test.sh`

**A fixture's path here is where it installs under `plugin/`.** That is the whole design:
version 3 dropped every fixture at `plugin/hooks/<basename>`, so three of the scanner's four
clauses never saw a failing case — a fixture written for the fetcher clause landed on an
unlisted path and was refused *for being unlisted*, passing while proving nothing.

Each file must be refused by the scanner, and each is refused by a **different** clause:

| fixture | clause it must trip | how a previous version let it through |
|---|---|---|
| `bin/fetch-release-binary.sh` | the fetcher must *run* the verifier | the check was a grep satisfied by a **trailing** comment, because the stripper only removed comments that started a line. Round 2's original defect, third recurrence |
| `hooks/session-start.sh` | a delegator must call the fetcher | same trailing-comment bypass, one layer out — the body is the verbatim round-2 CRITICAL |
| `hooks/hooks.json` | a data file must not be a script | `hooks.json`'s `command` field takes any executable path, so a data file with a shebang is a live surface |
| `hooks/rogue-no-extension` | unlisted paths are refused | `find -name '*.sh'` never enumerated it |
| `hooks/rogue-alt-mechanisms.sh` | unlisted paths are refused | `git clone` was absent from the mechanism list, `ncat ` does not match `nc `, and `"$D/evil2"` contains no `bin/` literal |
| `hooks/rogue-python-urlretrieve.sh` | unlisted paths are refused | no `curl`, no `chmod +x`, no `exec "$BINARY"` — three clauses walked around at once |

## Extending this

**Add a fixture, not just a clause.** Then verify it fails for the reason you intend, by
mutating that clause alone and watching *that* fixture go red. Three of these were confirmed
that way; the fourth appeared not to be until the mutation itself was asserted — a `sed` that
silently failed to match looks exactly like a clause with no test.

Do not delete a fixture because it now passes. Passing is the point.

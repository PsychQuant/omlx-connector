# Adversarial fixtures for `no-unverified-download.test.sh`

Each file here is a downloader that **must** be refused by the scanner. They live outside
`plugin/` so they can never ship to a user, and the scanner copies them in temporarily.

They are not hypotheticals. Every one of them was reported green by a version of that
scanner:

| fixture | how it evaded |
|---|---|
| `rogue-no-extension` | no `.sh` suffix, so `find -name '*.sh'` never enumerated it — while `hooks.json` accepts any executable path. Its body is the verbatim round-2 CRITICAL |
| `rogue-alt-mechanisms.sh` | `git clone` was absent from the mechanism list, `ncat ` does not match `nc `, and `"$D/evil2"` contains no `bin/` literal |
| `rogue-python-urlretrieve.sh` | no `curl`, no `chmod +x`, no `exec "$BINARY"` — three clauses walked around at once |
| `rogue-basename-privilege/fetch-release-binary.sh` | authorization was by **basename**, so any file with that name anywhere under `plugin/` inherited "the one permitted downloader" privilege; the "must verify" check was a `grep`, which a comment satisfies |

The last one is round 2's original defect — *a grep for the policy returned one line, a
comment mentioning it* — reproduced inside the check written to prevent it.

**Adding a fixture is how you extend this test.** Do not add a clause to the scanner
without a fixture that fails on it, and do not remove a fixture because it now passes.

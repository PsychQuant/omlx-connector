BINARY_NAME := OmlxConnectorMCP

# Swift 6 concurrency guard: build natively first, and fall back to Swift 5
# language mode only if an upstream dependency trips strict concurrency.
FALLBACK_FLAGS := $(shell swift build 2>&1 | grep -q "SendingRisksDataRace" && echo "-Xswiftc -swift-version -Xswiftc 5")

.PHONY: build release release-signed verify-developer-id install install-omlx-claude install-signed clean test test-swift test-shell test-headed eval ping

build:
	swift build $(FALLBACK_FLAGS)

release:
	swift build -c release $(FALLBACK_FLAGS)

## Swift tests plus the shell suites. The shell ones are not optional extras: the
## download verification and the "no unverified downloads anywhere in plugin/" property
## are only expressible there, and both exist because a defect survived a review round
## by being fixed in one file.
test: test-swift test-shell

test-swift:
	swift test $(FALLBACK_FLAGS)

test-shell:
	@# NON-RECURSIVE on purpose: scripts/tests/headed/ holds suites that need a live
	@# oMLX server and a PTY. Making this glob recursive would pull them into the
	@# hermetic `make test`. See scripts/tests/headed/model-picker.test.sh (#17).
	@for suite in scripts/tests/*.test.sh; do bash "$$suite" || exit 1; done

## Headed tests: drive the interactive path through a real PTY (tmux).
## Deliberately NOT part of `test` — these need a live oMLX server, so folding them in
## would trade a fast always-runnable suite for an environment-dependent one. Same layer
## as the hand-checks CLAUDE.md already asks for, but repeatable.
## Set REQUIRE_FULL_SUITE=1 to make a skip (missing tmux / no server) a failure.
test-headed:
	@for suite in scripts/tests/headed/*.test.sh; do bash "$$suite" || exit 1; done

## Delegation-quality evaluation (issue #1). Drives the shipped binary over JSON-RPC
## against a live oMLX server and writes one JSONL row per case. NOT part of `test`:
## it needs a model loaded and takes seconds to minutes per case. It also lives outside
## both test globs (scripts/eval/, not scripts/tests/), so it cannot join either by
## accident. The checks it applies ARE unit-tested in the hermetic suite —
## scripts/tests/eval-checks.test.sh — so they stay verified where no model exists.
##   make eval MODELS="--model a --model b"   compares across sizes; that comparison is
##   the point, per the issue: the interesting output is where the cliff is.
eval: build
	./scripts/eval/run.sh $(MODELS)

## Reachability check against the configured oMLX server.
ping: build
	.build/debug/$(BINARY_NAME) --ping

verify-developer-id:
	@: $${DEVELOPER_ID:?DEVELOPER_ID not set. See README 'Signing & notarization'.}

## The only documented release command. It pointed at scripts/build-mcpb.sh, which has
## never existed in this repo — `make release-signed` failed with exit 127 for anyone
## who followed the README. It went unnoticed because the script was always invoked
## directly during development.
release-signed: verify-developer-id
	@: $${NOTARY_PROFILE:?NOTARY_PROFILE not set. See README 'Signing & notarization'.}
	./scripts/build-release.sh

## Local install, ad-hoc signed. Fine for development on this machine only.
install: release
	@mkdir -p ~/bin
	rm -f ~/bin/$(BINARY_NAME)
	cp .build/release/$(BINARY_NAME) ~/bin/$(BINARY_NAME)
	chmod +x ~/bin/$(BINARY_NAME)
	codesign --force --sign - ~/bin/$(BINARY_NAME)
	@echo "installed ~/bin/$(BINARY_NAME)"

## Local install of the usage-1 command, ad-hoc signed. Development only —
## end users get it from the plugin's session-start hook, which downloads the
## notarized build from the release.
install-omlx-claude: release
	@mkdir -p ~/bin
	rm -f ~/bin/omlx-claude
	cp .build/release/omlx-claude ~/bin/omlx-claude
	chmod +x ~/bin/omlx-claude
	codesign --force --sign - ~/bin/omlx-claude
	@~/bin/omlx-claude --version | awk '{print $$NF}' > ~/bin/.omlx-claude.version
	@echo "installed ~/bin/omlx-claude"
	@case ":$$PATH:" in *":$$HOME/bin:"*) ;; \
	  *) echo "warning: ~/bin is not on your PATH — typing 'omlx-claude' will not find it" ;; \
	esac

## Local install with the real Developer ID.
install-signed: verify-developer-id release
	@mkdir -p ~/bin
	rm -f ~/bin/$(BINARY_NAME)
	cp .build/release/$(BINARY_NAME) ~/bin/$(BINARY_NAME)
	chmod +x ~/bin/$(BINARY_NAME)
	codesign --force --sign "$$DEVELOPER_ID" --options runtime ~/bin/$(BINARY_NAME)
	@echo "installed + signed ~/bin/$(BINARY_NAME)"

clean:
	swift package clean
	rm -rf .build

# `rm -f` before every copy is deliberate: the kernel caches the code-signature
# per inode, so overwriting a running binary in place can serve a stale signature.

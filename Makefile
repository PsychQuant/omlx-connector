BINARY_NAME := OmlxConnectorMCP

# Swift 6 concurrency guard: build natively first, and fall back to Swift 5
# language mode only if an upstream dependency trips strict concurrency.
FALLBACK_FLAGS := $(shell swift build 2>&1 | grep -q "SendingRisksDataRace" && echo "-Xswiftc -swift-version -Xswiftc 5")

.PHONY: build release release-signed verify-developer-id install install-signed clean test ping

build:
	swift build $(FALLBACK_FLAGS)

release:
	swift build -c release $(FALLBACK_FLAGS)

test:
	swift test $(FALLBACK_FLAGS)

## Reachability check against the configured oMLX server.
ping: build
	.build/debug/$(BINARY_NAME) --ping

verify-developer-id:
	@: $${DEVELOPER_ID:?DEVELOPER_ID not set. See README 'Signing & notarization'.}

release-signed: verify-developer-id
	@: $${NOTARY_PROFILE:?NOTARY_PROFILE not set. See README 'Signing & notarization'.}
	REQUIRE_CODESIGN=1 ./scripts/build-mcpb.sh

## Local install, ad-hoc signed. Fine for development on this machine only.
install: release
	@mkdir -p ~/bin
	rm -f ~/bin/$(BINARY_NAME)
	cp .build/release/$(BINARY_NAME) ~/bin/$(BINARY_NAME)
	chmod +x ~/bin/$(BINARY_NAME)
	codesign --force --sign - ~/bin/$(BINARY_NAME)
	@echo "installed ~/bin/$(BINARY_NAME)"

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

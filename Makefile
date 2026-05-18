.PHONY: build build-debug sign test test-integration run install clean

# Default install prefix; override on the command line, e.g. `make install PREFIX=/usr/local`.
PREFIX ?= $(HOME)/.local

# `swift run` SKIPS code-signing and will crash dictamac on first SpeechAnalyzer
# touch. Always go through `make build` / `make build-debug` so the binary is
# signed with the right entitlements before invocation.

build:
	swift build -c release \
		-Xlinker -sectcreate -Xlinker __TEXT \
		-Xlinker __info_plist -Xlinker Resources/Info.plist
	$(MAKE) sign BINARY=.build/release/dictamac

build-debug:
	swift build \
		-Xlinker -sectcreate -Xlinker __TEXT \
		-Xlinker __info_plist -Xlinker Resources/Info.plist
	$(MAKE) sign BINARY=.build/debug/dictamac

sign:
	@if [ -z "$(BINARY)" ]; then \
		echo "error: BINARY is required, e.g. make sign BINARY=.build/release/dictamac" >&2; \
		exit 2; \
	fi
	codesign --sign - --options runtime \
		--entitlements Resources/dictamac.entitlements \
		--force "$(BINARY)"

# `make test` runs the full suite via `swift test`. The MCP subprocess
# integration test (see #28) skips by default because it can only
# exercise an explicitly-fresh signed binary — running it against a
# stale `.build/release/dictamac` would hide MCP regressions or yield
# spurious failures after a protocol/schema change. Use
# `make test-integration` to do a fresh build and opt in.
test:
	swift test

# Convenience target that guarantees a fresh signed binary, then opts
# the MCP subprocess integration test into running via the
# `DICTAMAC_RUN_MCP_SUBPROCESS_TEST` env var. The dependency on `build`
# guarantees no stale-binary scenario.
test-integration: build
	DICTAMAC_RUN_MCP_SUBPROCESS_TEST=1 swift test

run: build-debug
	.build/debug/dictamac $(ARGS)

install: build
	mkdir -p "$(PREFIX)/bin"
	cp .build/release/dictamac "$(PREFIX)/bin/"

clean:
	swift package clean
	rm -rf .build dist

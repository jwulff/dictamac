.PHONY: build build-debug sign test run install clean

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

test:
	swift test

run: build-debug
	.build/debug/dictamac $(ARGS)

install: build
	mkdir -p "$(PREFIX)/bin"
	cp .build/release/dictamac "$(PREFIX)/bin/"

clean:
	swift package clean
	rm -rf .build dist

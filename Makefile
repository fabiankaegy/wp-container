XCODEGEN := /opt/homebrew/bin/xcodegen
PROJECT  := WPContainer.xcodeproj
CONFIG   := Debug
DERIVED  := build
PRODUCTS := $(DERIVED)/Build/Products/$(CONFIG)
PREFIX   := /usr/local/bin

.PHONY: all generate build build-app build-cli test install-cli verify-version release clean

all: build

generate:
	$(XCODEGEN) generate

# Build every target (kit is pulled in as a dependency of both app and CLI).
build: generate
	xcodebuild -project $(PROJECT) -scheme WPContainer  -configuration $(CONFIG) -derivedDataPath $(DERIVED) build
	xcodebuild -project $(PROJECT) -scheme wp-container  -configuration $(CONFIG) -derivedDataPath $(DERIVED) build

build-app: generate
	xcodebuild -project $(PROJECT) -scheme WPContainer -configuration $(CONFIG) -derivedDataPath $(DERIVED) build

build-cli: generate
	xcodebuild -project $(PROJECT) -scheme wp-container -configuration $(CONFIG) -derivedDataPath $(DERIVED) build

# Runs both unit-test bundles (pure logic: no app launch, no containers).
test: generate
	xcodebuild -project $(PROJECT) -scheme WPContainerKitTests -configuration $(CONFIG) -derivedDataPath $(DERIVED) test
	xcodebuild -project $(PROJECT) -scheme HostsHelperTests    -configuration $(CONFIG) -derivedDataPath $(DERIVED) test

# Copies the built CLI to /usr/local/bin and adds a `wpc` convenience symlink.
# Run this yourself after `make build-cli`; it is intentionally not invoked by CI.
install-cli: build-cli
	install -m 0755 "$(PRODUCTS)/wp-container" "$(PREFIX)/wp-container"
	ln -sf "$(PREFIX)/wp-container" "$(PREFIX)/wpc"
	@echo "Installed wp-container (+ wpc symlink) to $(PREFIX)"
	@# The global `wp` router is per-user (it lives under the user's Application
	@# Support dir and prepends a block to ~/.zshrc), so it must NOT be installed
	@# here — this target typically runs under sudo, which would resolve to root's
	@# home. Run 'wp-container setup wp' (or the app's toggle) as your user.
	@echo "Run 'wp-container setup wp' (unprivileged) or use the app toggle to enable plain 'wp' inside sites."

# Confirms the marketing version is identical in the Swift source of truth and
# project.yml. Run by `make release`; handy on its own before tagging.
verify-version:
	@src=$$(sed -n 's/.*marketing = "\([0-9][^"]*\)".*/\1/p' WPContainerKit/WPContainerVersion.swift | head -1); \
	yml=$$(sed -n 's/.*MARKETING_VERSION: *"\([0-9][^"]*\)".*/\1/p' project.yml | head -1); \
	if [ "$$src" != "$$yml" ]; then \
	  echo "version mismatch: WPContainerVersion.swift=$$src project.yml=$$yml"; exit 1; \
	fi; \
	echo "version OK: $$src"

# Full signed/hardened/optionally-notarized release into dist/.
# Usage:
#   make release SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#                TEAM_ID=TEAMID NOTARY_PROFILE=wpc-notary
# With no SIGN_IDENTITY it validates the pipeline end-to-end with an ad-hoc
# signature (not distributable). See docs/RELEASING.md.
release: verify-version
	SIGN_IDENTITY="$(SIGN_IDENTITY)" TEAM_ID="$(TEAM_ID)" NOTARY_PROFILE="$(NOTARY_PROFILE)" VERSION="$(VERSION)" ./scripts/release.sh

clean:
	rm -rf $(DERIVED) $(PROJECT) dist

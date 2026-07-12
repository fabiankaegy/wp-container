XCODEGEN := /opt/homebrew/bin/xcodegen
PROJECT  := WPContainer.xcodeproj
CONFIG   := Debug
DERIVED  := build
PRODUCTS := $(DERIVED)/Build/Products/$(CONFIG)
PREFIX   := /usr/local/bin

.PHONY: all generate build build-app build-cli install-cli clean

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

# Copies the built CLI to /usr/local/bin and adds a `wpc` convenience symlink.
# Run this yourself after `make build-cli`; it is intentionally not invoked by CI.
install-cli: build-cli
	install -m 0755 "$(PRODUCTS)/wp-container" "$(PREFIX)/wp-container"
	ln -sf "$(PREFIX)/wp-container" "$(PREFIX)/wpc"
	@# Write the global `wp` router binary (no shell edits). Run
	@# `wp-container setup wp` (or the app's toggle) to put it first on PATH.
	"$(PREFIX)/wp-container" setup wp --install-binary
	@echo "Installed wp-container (+ wpc symlink) to $(PREFIX)"
	@echo "Global wp router staged; run 'wp-container setup wp' to enable plain 'wp' inside sites."

clean:
	rm -rf $(DERIVED) $(PROJECT)

#!/usr/bin/env bash
#
# release.sh — produce a signed, hardened-runtime, optionally-notarized release
# of WP Container: a versioned WPContainer.app + a .dmg, plus a .zip of the
# wp-container CLI with an installer. Driven by `make release`.
#
# Nothing here is committed with secrets: the signing identity and team come
# from the environment (or default to ad-hoc "-"), and the notary credential is
# a keychain profile name only.
#
# Environment:
#   SIGN_IDENTITY   codesign identity. Default "-" (ad-hoc) with a loud warning.
#                   For a real release:
#                     SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   TEAM_ID         Apple Developer Team ID (10 chars). Optional; used for
#                   DEVELOPMENT_TEAM and as a sanity hint. Never committed.
#   NOTARY_PROFILE  Name of a `xcrun notarytool store-credentials` keychain
#                   profile (e.g. "wpc-notary"). If set (and identity is real),
#                   the .dmg is submitted for notarization and stapled.
#                   Alternatively set ASC_API_KEY_ID + ASC_API_ISSUER_ID +
#                   ASC_API_KEY_PATH for App Store Connect API-key notarization.
#   VERSION         Override the marketing version. Default: read from source.
#
# Outputs (in dist/, gitignored):
#   dist/WPContainer-<version>.dmg
#   dist/wp-container-cli-<version>.zip
#   dist/WPContainer.app          (the signed app, for inspection / re-signing)
#   dist/SHASUMS256.txt

set -euo pipefail

# ---- resolve paths -----------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

XCODEGEN="${XCODEGEN:-/opt/homebrew/bin/xcodegen}"
PROJECT="WPContainer.xcodeproj"
DERIVED="$ROOT/build/release"           # isolated derived data (under gitignored build/)
DIST="$ROOT/dist"
PRODUCTS="$DERIVED/Build/Products/Release"
STAGE="$DIST/.stage"                    # scratch DMG root

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
TEAM_ID="${TEAM_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

# ---- helpers -----------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

is_adhoc() { [ "$SIGN_IDENTITY" = "-" ]; }

# ---- version (single source of truth: WPContainerKit/WPContainerVersion.swift)
SRC_VERSION="$(sed -n 's/.*marketing = "\([0-9][^"]*\)".*/\1/p' \
  "$ROOT/WPContainerKit/WPContainerVersion.swift" | head -1)"
YML_VERSION="$(sed -n 's/.*MARKETING_VERSION: *"\([0-9][^"]*\)".*/\1/p' \
  "$ROOT/project.yml" | head -1)"
[ -n "$SRC_VERSION" ] || die "could not read version from WPContainerVersion.swift"
if [ "$SRC_VERSION" != "$YML_VERSION" ]; then
  die "version mismatch: WPContainerVersion.swift=$SRC_VERSION project.yml=$YML_VERSION (keep them in sync)"
fi
VERSION="${VERSION:-$SRC_VERSION}"
log "Releasing WP Container $VERSION"

if is_adhoc; then
  warn "SIGN_IDENTITY is ad-hoc (\"-\"). Artifacts will NOT be distributable:"
  warn "  Gatekeeper (spctl) will reject them and notarization is impossible."
  warn "  Set SIGN_IDENTITY=\"Developer ID Application: …\" for a real release."
else
  log "Signing identity: $SIGN_IDENTITY"
fi

# ---- clean + generate --------------------------------------------------------
rm -rf "$DIST"
mkdir -p "$DIST" "$STAGE"
log "Generating Xcode project"
"$XCODEGEN" generate >/dev/null

# ---- build (Release, isolated derived data) ----------------------------------
XCB_TEAM=()
[ -n "$TEAM_ID" ] && XCB_TEAM=(DEVELOPMENT_TEAM="$TEAM_ID")

log "Building WPContainer.app (Release, Hardened Runtime)"
xcodebuild -project "$PROJECT" -scheme WPContainer -configuration Release \
  -derivedDataPath "$DERIVED" ${XCB_TEAM[@]+"${XCB_TEAM[@]}"} build >/dev/null

log "Building wp-container CLI (Release)"
xcodebuild -project "$PROJECT" -scheme wp-container -configuration Release \
  -derivedDataPath "$DERIVED" ${XCB_TEAM[@]+"${XCB_TEAM[@]}"} build >/dev/null

APP_SRC="$PRODUCTS/WPContainer.app"
CLI_SRC="$PRODUCTS/wp-container"
[ -d "$APP_SRC" ] || die "app not found at $APP_SRC"
[ -x "$CLI_SRC" ] || die "cli not found at $CLI_SRC"

# ---- stage copies we will sign / package ------------------------------------
APP="$DIST/WPContainer.app"
CLI="$DIST/wp-container"
cp -R "$APP_SRC" "$APP"
cp "$CLI_SRC" "$CLI"

# ---- sign (inside-out; bundle is self-contained: no nested frameworks) -------
# Real identity → secure timestamp; ad-hoc cannot use --timestamp.
TS=(--timestamp)
is_adhoc && TS=(--timestamp=none)

log "Signing CLI binary"
codesign --force --options runtime "${TS[@]}" --sign "$SIGN_IDENTITY" "$CLI"

# Sign the embedded privileged helper BEFORE the app so the app's seal records
# the helper's cdhash (codesign does not recursively sign nested Mach-O in
# Contents/MacOS). Same identity + hardened runtime — required for the app to
# register it as an SMAppService.daemon (§2f-bis, issue #2).
HELPER="$APP/Contents/MacOS/wpc-hosts-helper"
[ -x "$HELPER" ] || die "embedded helper not found at $HELPER (build did not embed it)"
log "Signing embedded privileged helper (wpc-hosts-helper)"
codesign --force --options runtime "${TS[@]}" --sign "$SIGN_IDENTITY" "$HELPER"

log "Signing WPContainer.app"
codesign --force --options runtime "${TS[@]}" --sign "$SIGN_IDENTITY" "$APP"

# ---- verify ------------------------------------------------------------------
log "Verifying signatures"
codesign --verify --deep --strict --verbose=2 "$APP"    || die "app failed codesign --verify"
codesign --verify --strict --verbose=2         "$HELPER" || die "embedded helper failed codesign --verify"
codesign --verify --strict --verbose=2         "$CLI"   || die "cli failed codesign --verify"

log "Gatekeeper assessment (spctl)"
if spctl --assess --type execute --verbose=4 "$APP" 2>&1; then
  log "spctl: accepted"
else
  if is_adhoc; then
    warn "spctl rejected the app — EXPECTED for ad-hoc signing. A Developer ID"
    warn "signed + notarized build is required for Gatekeeper acceptance."
  else
    warn "spctl rejected the app. If this is a fresh Developer ID signature,"
    warn "it will pass only after notarization + stapling (below)."
  fi
fi

# ---- DMG ---------------------------------------------------------------------
log "Building disk image"
cp -R "$APP" "$STAGE/WPContainer.app"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/WPContainer-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "WP Container" -srcfolder "$STAGE" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGE"

# ---- CLI zip -----------------------------------------------------------------
log "Building CLI zip"
CLIZIP_STAGE="$DIST/.clistage"
mkdir -p "$CLIZIP_STAGE"
cp "$CLI" "$CLIZIP_STAGE/wp-container"
cat > "$CLIZIP_STAGE/install.sh" <<'INSTALL'
#!/usr/bin/env bash
# Install the wp-container CLI (+ `wpc` symlink) to /usr/local/bin and write the
# global `wp` router. Mirrors `make install-cli`.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local/bin}"
sudo=""
[ -w "$PREFIX" ] || sudo="sudo"
$sudo install -m 0755 "$HERE/wp-container" "$PREFIX/wp-container"
$sudo ln -sf "$PREFIX/wp-container" "$PREFIX/wpc"
# Writes the global `wp` router binary (no shell edits). Run `wp-container setup
# wp` afterwards to put it first on PATH so plain `wp` inside a site works.
"$PREFIX/wp-container" setup wp --install-binary
echo "Installed wp-container (+ wpc) to $PREFIX."
echo "Run 'wp-container setup wp' to enable the global 'wp' router inside sites."
INSTALL
chmod +x "$CLIZIP_STAGE/install.sh"
cat > "$CLIZIP_STAGE/README.txt" <<README
WP Container CLI $VERSION

Contents:
  wp-container   the CLI binary (Developer ID / ad-hoc signed, hardened runtime)
  install.sh     installs it to /usr/local/bin, adds a 'wpc' symlink, and writes
                 the global 'wp' router (which is generated at install time and
                 points at the installed wp-container).

Install:
  ./install.sh
  wp-container setup wp     # optional: enable plain 'wp' inside site folders

Uninstall:
  rm /usr/local/bin/wp-container /usr/local/bin/wpc
  wp-container setup wp --remove   # before removing, to unwire the router
README
CLIZIP="$DIST/wp-container-cli-$VERSION.zip"
rm -f "$CLIZIP"
( cd "$CLIZIP_STAGE" && zip -q -r "$CLIZIP" . )
rm -rf "$CLIZIP_STAGE"

# ---- notarization ------------------------------------------------------------
notarize_available() {
  [ -n "$NOTARY_PROFILE" ] || \
    { [ -n "${ASC_API_KEY_ID:-}" ] && [ -n "${ASC_API_ISSUER_ID:-}" ] && [ -n "${ASC_API_KEY_PATH:-}" ]; }
}

if is_adhoc; then
  warn "Skipping notarization: ad-hoc signature cannot be notarized."
elif ! notarize_available; then
  warn "Skipping notarization: set NOTARY_PROFILE (or ASC_API_* vars) to enable."
  warn "  See docs/RELEASING.md for 'xcrun notarytool store-credentials'."
else
  log "Notarizing $DMG (this waits for Apple)"
  NOTARY_AUTH=()
  if [ -n "$NOTARY_PROFILE" ]; then
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
  else
    NOTARY_AUTH=(--key "$ASC_API_KEY_PATH" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID")
  fi
  xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait
  # Submitting the DMG notarizes the cdhashes of its contents, so we can staple
  # both the DMG and the standalone app.
  log "Stapling notarization ticket"
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP" || warn "could not staple standalone app (dmg is stapled)"
  # Also notarize the CLI zip so the loose binary is trusted too.
  log "Notarizing CLI zip"
  xcrun notarytool submit "$CLIZIP" "${NOTARY_AUTH[@]}" --wait || \
    warn "CLI zip notarization failed (dmg is done)"
  log "Verifying stapled DMG with Gatekeeper"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG" || \
    warn "spctl open assessment did not pass"
fi

# ---- checksums + summary -----------------------------------------------------
log "Computing checksums"
( cd "$DIST" && shasum -a 256 "WPContainer-$VERSION.dmg" "wp-container-cli-$VERSION.zip" > SHASUMS256.txt )

echo
log "Done. Artifacts in dist/:"
( cd "$DIST" && ls -1 "WPContainer-$VERSION.dmg" "wp-container-cli-$VERSION.zip" SHASUMS256.txt )
echo
cat "$DIST/SHASUMS256.txt"
echo
IDLINE="$(codesign -d --verbose=2 "$APP" 2>&1 | sed -n 's/^Authority=/  authority: /p' | head -3)"
FLAGS="$(codesign -d --verbose=2 "$APP" 2>&1 | sed -n 's/^CodeDirectory .*\(flags=[^ ]*\).*/  \1/p')"
echo "Signed with: ${SIGN_IDENTITY}"
[ -n "$FLAGS" ] && echo "$FLAGS"
if [ -n "$IDLINE" ]; then echo "$IDLINE"; else echo "  (ad-hoc: no certificate authority chain)"; fi
HELPER_TEAM="$(codesign -d --verbose=2 "$APP/Contents/MacOS/wpc-hosts-helper" 2>&1 | sed -n 's/^TeamIdentifier=/  helper team: /p')"
[ -n "$HELPER_TEAM" ] && echo "$HELPER_TEAM" || echo "  embedded helper: signed (ad-hoc)"
exit 0

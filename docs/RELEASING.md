# Releasing WP Container

This document describes how to cut a signed, hardened-runtime, notarized release
of WP Container — a `WPContainer.app` + `.dmg` and a `wp-container` CLI `.zip` —
and how the release pipeline is wired.

Everything is driven by `make release`, which runs `scripts/release.sh`. No
secrets are committed: the signing identity and Team ID come from the
environment, and notarization uses a named keychain credential profile.

---

## TL;DR release flow

```sh
# One-time setup (see below) creates the Developer ID cert and a notary profile.
make release \
  SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  TEAM_ID=TEAMID \
  NOTARY_PROFILE=wpc-notary

# Artifacts land in dist/ (gitignored):
#   dist/WPContainer-<version>.dmg
#   dist/wp-container-cli-<version>.zip
#   dist/SHASUMS256.txt
#   dist/WPContainer.app      (signed, for inspection / re-signing)

# Then publish (done by the release owner, not the pipeline):
gh release create v<version> \
  dist/WPContainer-<version>.dmg \
  dist/wp-container-cli-<version>.zip \
  dist/SHASUMS256.txt \
  --title "WP Container <version>" --notes "…"
```

Running `make release` with **no** `SIGN_IDENTITY` validates the whole pipeline
end-to-end using an **ad-hoc** signature. That build is *not* distributable
(Gatekeeper will reject it and it can't be notarized) — it exists so the
pipeline can be exercised before the Developer ID certificate is available.

---

## Versioning

The marketing version has a single source of truth:
`WPContainerKit/WPContainerVersion.swift` (`WPContainerVersion.marketing`).

- The **app** shows it in the Settings window footer ("WP Container 0.1.0").
- The **CLI** exposes it via `wp-container --version` and reports it as the MCP
  server version.
- `project.yml` sets `MARKETING_VERSION` (0.1.0) and `CURRENT_PROJECT_VERSION`
  (a monotonic integer, currently `1`) on every target.

`make verify-version` (run automatically by `make release`) asserts the Swift
constant and `project.yml`'s `MARKETING_VERSION` match. When bumping the
version, update **both** the Swift constant and `project.yml`, and increment
`CURRENT_PROJECT_VERSION`.

---

## Build configuration (Debug vs Release)

Signing is configured per-build-configuration in `project.yml`:

| Setting                  | Debug (unchanged)     | Release                          |
|--------------------------|-----------------------|----------------------------------|
| `CODE_SIGN_IDENTITY`     | `-` (ad-hoc)          | `-` default; overridden at release time |
| `ENABLE_HARDENED_RUNTIME`| `NO`                  | `YES`                            |
| `DEVELOPMENT_TEAM`       | empty                 | empty; set via `TEAM_ID` env     |
| `CODE_SIGN_STYLE`        | Manual                | Manual                           |

Debug is intentionally left exactly as it always was: ad-hoc, no hardened
runtime, zero signing friction for `make build` and local development.

Release builds succeed with **no certificate** (ad-hoc), so the pipeline is
always runnable. `scripts/release.sh` then re-signs the built `.app` and CLI
binary with `codesign --force --options runtime --timestamp --sign
"$SIGN_IDENTITY"` — a real Developer ID Application identity when one is
provided, otherwise ad-hoc `-` with a loud warning (and `--timestamp=none`,
since ad-hoc can't use a secure timestamp).

The `.app` bundle is self-contained: a single Mach-O executable, no embedded
frameworks, dylibs, or XPC services (WPContainerKit is a **static** library and
the Swift runtime ships with macOS). So signing is a simple two-object pass —
the CLI binary and the app bundle — with no inside-out framework signing.

---

## Entitlements / Hardened Runtime audit

The app runs **unsandboxed** (no `.entitlements` file, no App Sandbox) because
it must shell out to `/usr/local/bin/container` and manage arbitrary site
folders the user chooses. Release builds enable **Hardened Runtime**, which is
required for Developer ID distribution and notarization.

Two things the app does touch hardened-runtime territory:

1. **Spawns subprocesses** (`Foundation.Process`) to run the `container` CLI
   and containerized `wp-cli`.
2. **Binds a local network listener** (BSD sockets / `Network.framework`
   `NWListener`) for the HTTPS reverse proxy.

**Neither requires a hardened-runtime exception.** Hardened Runtime restricts
things like loading unsigned libraries, JIT / writable-executable memory
(`com.apple.security.cs.allow-unsigned-executable-memory`,
`…allow-jit`), DYLD environment variables, and — *only under App Sandbox* —
network access. Spawning a child process and binding a socket are **not** gated
by Hardened Runtime for an unsandboxed app.

This was verified empirically: a throwaway Swift binary that (a) spawns
`container --version` via `Process` and (b) binds a TCP listener was signed with
`codesign --options runtime -s -` (hardened, ad-hoc) and run. Both operations
succeeded. The `container --version` spawn returned `0`, and the socket bound to
an ephemeral port. Running the identical binary **without** the runtime flag
behaved the same, confirming Hardened Runtime changes nothing here. The release
`WPContainer.app` (hardened, ad-hoc) also launches and runs.

Conclusion: **no `com.apple.security.cs.*` exceptions are added.** In particular
`com.apple.security.cs.allow-unsigned-executable-memory` is *not* needed — the
app does not JIT or map writable-executable memory. If a future feature does
require an exception, add the minimal one to a Release-only `.entitlements` file
and document the reason here.

---

## One-time setup

### 1. Create the Developer ID Application certificate

In Xcode: **Settings → Accounts → (your team) → Manage Certificates → +
→ Developer ID Application**. This requires an Apple Developer Program
membership. Once created it appears in:

```sh
security find-identity -v -p codesigning
# 1) ABCD… "Developer ID Application: Your Name (TEAMID)"
```

Use that full string (including the team suffix) as `SIGN_IDENTITY`, and the
10-character team id in the parentheses as `TEAM_ID`.

### 2. Create an app-specific password + notary keychain profile

Notarization needs an **app-specific password** (not your Apple ID password):
create one at <https://appleid.apple.com> → Sign-In and Security → App-Specific
Passwords. Then store it as a reusable notarytool keychain profile:

```sh
xcrun notarytool store-credentials wpc-notary \
  --apple-id "you@example.com" \
  --team-id TEAMID \
  --password "abcd-efgh-ijkl-mnop"   # the app-specific password
```

Pass `NOTARY_PROFILE=wpc-notary` to `make release` to enable notarization +
stapling.

> Alternatively use an App Store Connect **API key** and export
> `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, and `ASC_API_KEY_PATH` (path to the
> `.p8`); the pipeline picks these up if `NOTARY_PROFILE` is unset.

---

## What `make release` does

1. `make verify-version` — assert the version is consistent.
2. `xcodegen generate`.
3. `xcodebuild -configuration Release` (Hardened Runtime ON) for the app and the
   CLI into an **isolated** derived-data path (`build/release/`) so it never
   disturbs your Debug build or a running app instance. `DEVELOPMENT_TEAM` is
   passed from `TEAM_ID` when set.
4. Copy `WPContainer.app` and `wp-container` into `dist/`.
5. `codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY"` the
   CLI binary, then the app bundle. Ad-hoc falls back to `-` with a warning and
   `--timestamp=none`.
6. Verify: `codesign --verify --deep --strict` on both; `spctl --assess` (this
   **fails for ad-hoc** and for an un-notarized Developer ID build — reported,
   not fatal).
7. Build `dist/WPContainer-<version>.dmg` with `hdiutil` — the app plus an
   `/Applications` symlink, volume name **"WP Container"**, compressed `UDZO`.
8. Build `dist/wp-container-cli-<version>.zip` — the CLI binary, an `install.sh`
   (installs to `/usr/local/bin` and adds the `wpc` symlink; the per-user global
   `wp` router is enabled separately by running `wp-container setup wp`), and a
   `README.txt`.
9. If a notary credential is available **and** the identity is real: `xcrun
   notarytool submit --wait` the `.dmg` (which notarizes the cdhashes of its
   contents), then `xcrun stapler staple` the `.dmg` and the standalone `.app`;
   the CLI zip is submitted too. Otherwise a clear "skipped notarization" notice
   is printed (with the reason).
10. Write `dist/SHASUMS256.txt` and print a summary including the signing
    identity and code-signing flags.

---

## Verifying a finished release

```sh
# App / DMG signature and notarization:
codesign --verify --deep --strict --verbose=2 dist/WPContainer.app
spctl --assess --type execute --verbose=4 dist/WPContainer.app        # app
spctl --assess --type open --context context:primary-signature --verbose=4 \
  dist/WPContainer-<version>.dmg                                       # dmg
xcrun stapler validate dist/WPContainer-<version>.dmg                 # ticket present

# CLI binary:
codesign --verify --strict --verbose=2 dist/wp-container
```

A properly signed + notarized + stapled build reports `accepted` /
`source=Notarized Developer ID` from `spctl`, and `stapler validate` succeeds.

---

## If the certificate arrives after an ad-hoc pipeline run

Just re-run the whole pipeline with the identity set — it is idempotent and
cheap:

```sh
make release SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
             TEAM_ID=TEAMID NOTARY_PROFILE=wpc-notary
```

To re-sign **already-built** artifacts in `dist/` without a full rebuild:

```sh
ID="Developer ID Application: Your Name (TEAMID)"
codesign --force --options runtime --timestamp --sign "$ID" dist/wp-container
codesign --force --options runtime --timestamp --sign "$ID" dist/WPContainer.app
# then rebuild the dmg/zip + notarize, or just re-run `make release`.
```

# QEQ — Codex Instructions

Goal: shortest path from request to the exact files, commands, and constraints needed for this Apple project.

## Start Here

| Task | Open First | Usually Validate With |
|---|---|---|
| App UI or lifecycle | `QEQ/App/Sources/` | `./QEQ/scripts/xcodebuild_generated.sh -scheme QEQ -destination 'generic/platform=macOS' build` |
| Core logic | `QEQ/Sources/QEQCore/` | `swift test --package-path QEQ` |
| App support/services | `QEQ/Sources/QEQAppSupport/` | `swift test --package-path QEQ` |
| Project generation or Xcode settings | `QEQ/project.yml`; `QEQ/scripts/` | `./QEQ/scripts/generate_xcodeproj.sh` |
| Full validation / CI | `QEQ/scripts/check.sh`; `.github/workflows/ci.yml` | `./QEQ/scripts/check.sh` |
| Release workflow | `CHANGELOG.md`; `QEQ/scripts/cut_release.sh`; `.github/workflows/` | `swift test --package-path QEQ` |

## Repo Rules

1. Treat `QEQ/project.yml` as the Xcode source of truth.
2. Generate `QEQ/QEQ.xcodeproj` on demand and do not commit it.
3. Keep root `./run.sh` as the single local run entrypoint.
4. Keep private data out of git: certificates, profiles, notary keys, keychains, `.env`, generated archives, and local user state.
5. Before saying work is done or pushing code, run `swift test --package-path QEQ` and ensure it passes locally unless the user asks for a narrower check.

## Quick Commands

```bash
brew bundle
./run.sh
swift test --package-path QEQ
./QEQ/scripts/generate_xcodeproj.sh --open
./QEQ/scripts/xcodebuild_generated.sh -scheme QEQ -destination 'generic/platform=macOS' build
```

## Signed and notarized RCs

Update `QEQ/release.json` and matching release notes before committing. Run `cut_release.sh --prepare` to rebuild and refresh native README screenshots; commit `docs/media/*.png` and `screenshots.json` with the source. CI and tagging reject stale screenshot fingerprints. After local checks, push main and wait for CI. `cut_release.sh --publish` runs local tests and tags that commit; GitHub's Release DMG workflow renders/attaches screenshots and uses the six Apple secrets to sign with Developer ID, notarize and staple both app and DMG, verify Gatekeeper acceptance, then publish the release and a signed Sparkle appcast (RCs remain prereleases). The updater also requires `QEQ_SPARKLE_PRIVATE_ED_KEY` in GitHub and the matching public key in `QEQ/update-signing.json`. Do not publish unnotarized fallbacks or overwrite an existing release. Never commit or print signing secrets. Keep hardware tests enabled locally; only headless CI sets `QEQ_HARDWARE_TESTS=0`.

## Branding and UI captures

The user-facing app and artifacts are QEQ. Modules and directories use QEQ; the legacy `local.AppMixer` bundle identity remains stable for settings and permission compatibility. See `docs/DEVELOPMENT.md` for screenshot generation and diagnostics. Screenshots must use the app-owned renderer, never desktop capture or computer use.

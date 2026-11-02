# Codex Instructions

Goal: shortest path from request to the exact files, commands, and constraints needed for this Apple project.

## Start Here

| Task | Open First | Usually Validate With |
|---|---|---|
| App UI or lifecycle | `AppMixer/App/Sources/` | `./AppMixer/scripts/xcodebuild_generated.sh -scheme AppMixer -destination 'generic/platform=macOS' build` |
| Core logic | `AppMixer/Sources/AppMixerCore/` | `swift test --package-path AppMixer` |
| App support/services | `AppMixer/Sources/AppMixerAppSupport/` | `swift test --package-path AppMixer` |
| Project generation or Xcode settings | `AppMixer/project.yml`; `AppMixer/scripts/` | `./AppMixer/scripts/generate_xcodeproj.sh` |
| Full validation / CI | `AppMixer/scripts/check.sh`; `.github/workflows/ci.yml` | `./AppMixer/scripts/check.sh` |
| Release workflow | `CHANGELOG.md`; `AppMixer/scripts/cut_release.sh`; `.github/workflows/` | `swift test --package-path AppMixer` |

## Repo Rules

1. Treat `AppMixer/project.yml` as the Xcode source of truth.
2. Generate `AppMixer/AppMixer.xcodeproj` on demand and do not commit it.
3. Keep root `./run.sh` as the single local run entrypoint.
4. Keep private data out of git: certificates, profiles, notary keys, keychains, `.env`, generated archives, and local user state.
5. Before saying work is done or pushing code, run `swift test --package-path AppMixer` and ensure it passes locally unless the user asks for a narrower check.

## Quick Commands

```bash
brew bundle
./run.sh
swift test --package-path AppMixer
./AppMixer/scripts/generate_xcodeproj.sh --open
./AppMixer/scripts/xcodebuild_generated.sh -scheme AppMixer -destination 'generic/platform=macOS' build
```

## Internal RCs

Use `AppMixer/release.json` and matching release notes to record each RC before committing. `cut_release.sh --publish` requires clean, pushed main and passing CI, signs locally using `SIGNING_IDENTITY`, and uploads a private prerelease. Never export or upload a signing key. Apple Development RCs are not notarized. Keep hardware tests enabled for local validation; only headless CI sets `APP_MIXER_HARDWARE_TESTS=0`.

# AppMixer

A small, native macOS menu bar mixer with independent app volume, mute, and five-band parametric EQ. Requires macOS 14.4 or newer; built with SwiftUI, Core Audio, and a small C++ DSP kernel. No third-party runtime packages.

## Try it

```sh
./run.sh
```

Click the three-slider menu bar icon. Start playback in Zoom, Spotify, or another app to make it appear in the mixer. Apps that only register an audio client stay hidden until they actually start output or have saved adjustments. Once an app has played, its controls stay visible while its audio clients remain open, including when paused. Open **EQ → Presets → Cut bass** on Zoom, then turn on the mixer. Approve macOS's system-audio permission when requested. Spotify stays untouched unless you change its controls too.

The top-right switch is the global bypass. Switching it off or quitting destroys the taps and private aggregate devices, restoring the original audio paths. Each app’s switch bypasses its volume and EQ while preserving its controls. **Reset app** clears its settings and restores the direct path. Settings are saved by app bundle ID; each launch starts bypassed so relaunching cannot unexpectedly alter audio.

The local app is at `AppMixer/.dist/AppMixer.app`. `./run.sh --no-build` launches it without rebuilding. `./run.sh --clean` rebuilds it. XcodeGen and Xcode are needed to build; the app bundle runs on its own.

## Permissions

Only `NSAudioCaptureUsageDescription` is declared. macOS calls this **system audio recording**, even though AppMixer does not save or transmit audio. Processing happens in memory on the audio callback. There is no microphone capture, ScreenCaptureKit screen recording, Accessibility, Automation, administrator helper, network access, or installed audio driver. Physical microphone/line inputs contributed by an output device are explicitly disabled before starting; if isolation fails, the app refuses to start that route.

Permission is first requested when an adjusted app is intercepted, not at launch. If access is denied, allow AppMixer in **System Settings → Privacy & Security → Screen & System Audio Recording** (the exact panel label varies by macOS), then retry or relaunch. The local build is ad-hoc signed with the stable development identifier `local.AppMixer`; it is not notarized for distribution. macOS may request permission again after a rebuild.

## Latency and scope

- One device-scoped tap and private aggregate per adjusted app. The output device is the clock source; input is processed directly into output within the same Core Audio IOProc.
- No additional application ring buffer, scheduled AVAudioPlayer buffers, FFT window in the playback path, lookahead, or network round trip.
- The realtime C++ callback does not allocate, log, block, or acquire locks. Coefficients are calculated on a serial control queue and transferred using lock-free atomics. Changes ramp over 10 ms to reduce clicks; this does not delay audio by 10 ms.
- The footer reports the hardware **I/O buffer duration**, not measured end-to-end latency. True zero latency is impossible. Bluetooth, device drivers, and Core Audio add their own delay. Use built-in speakers or wired headphones for latency testing.
- Mono/stereo Float32 output devices with a single output stream are supported. Multichannel/multistream devices are rejected explicitly. This version processes the **current system output**; apps explicitly routed to a different output should be set to the system output first.
- EQ: five configurable bands, 20 Hz–20 kHz (limited to 45% of sample rate), ±18 dB. Bell, low/high shelf, and 12 dB/octave low/high cut filters. Bell/cut Q spans 0.1–10; shelf slope spans 0.1–1. Each band can be bypassed. Boosts and resonant cuts reserve conservative headroom. Volume is 0–100%.
- Drag numbered graph handles to change frequency/gain. Click a band, enter exact frequency/gain/Q values, or use the width slider. White is the filter response (EQ dB, before automatic headroom and app volume); a dashed line indicates a preview while bypassed. Teal is the live processed-output spectrum (−90…0 dBFS).
- The optional 2048-sample Hann-window spectrum uses Accelerate off the audio thread at ~15 fps. Atomic snapshots never delay playback. Stereo powers are combined without phase cancellation. Sampling/FFT runs only while an EQ panel is visible and that app already has a processing route. Flat/bypassed apps are not intercepted just to animate the graph.
- Chrome/Electron helper clients resolve to their outer application’s name, icon, and bundle ID. Legacy helper-key settings migrate to that app; existing parent settings take precedence.
- App discovery runs once per second. Helpers nested in a containing app are grouped with it. New audio processes and output changes rebuild affected routes; switching outputs may cause a brief transition. Pause/resume and sleep/wake are handled.
- Some protected/DRM audio may not be available to public process taps. Browser tabs share their browser's app control. No microphone EQ or input processing is provided.

## Build and validate

```sh
brew bundle
swift test --package-path AppMixer
./AppMixer/scripts/build_macos_app.sh --configuration release
./AppMixer/scripts/generate_xcodeproj.sh --open
```

`AppMixer/project.yml` is canonical. Generated Xcode projects, build products, and private signing files are gitignored. Tests cover the plotted response against rendered DSP at three sample rates, parametric Q/bypass, legacy settings migration, spectrum calibration and stereo phase handling, helper identity, filter frequency response, app-state isolation, volume/mute, mono/planar stereo, hardware-input exclusion in the DSP, invalid layouts, saved settings, and read-only live Core Audio discovery. Hardware discovery requires an available mono/stereo output.

## Command-line audio smoke test

Quit the menu bar app first to avoid duplicate taps, start playback in Chrome, then run:

```sh
AppMixer/.dist/AppMixer.app/Contents/MacOS/AppMixer --audio-check=com.google.Chrome
```

This briefly applies a −3 dB bell filter, reports numeric callback/spectrum diagnostics, destroys the route, and checks that the original output and tap list were restored. It uses the normal app permission; it does not bypass macOS privacy controls or save audio. A SILENT result is inconclusive when the source is paused/silent or permission is unavailable.

## Listening checklist

1. Play Zoom's speaker test or a call plus Spotify. Set Zoom's bass to −12 dB. Confirm only Zoom loses bass.
2. Change Zoom's volume and mute. Confirm Spotify is unaffected.
3. Toggle global bypass while both play. Confirm original sound and volume return. Re-enable and confirm saved adjustments return.
4. Reset an app; confirm it returns to the direct system path. Quit AppMixer while processing; confirm original sound continues.
5. Switch built-in speakers / wired headphones, pause and resume playback, restart an app, and sleep/wake the Mac.
6. For latency, compare the same video or call with mixer enabled/bypassed using wired output. The displayed buffer duration is not an acoustic measurement.

## Prior art

The single-callback private aggregate topology builds on [CoreAudioTapKit](https://github.com/CJStanfield/CoreAudioTapKit); its MIT notice is preserved in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Apple documents the underlying [Core Audio process-tap API and permission](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps).

## Repository tooling and releases

The private source repository is [gh123man/app-mixer](https://github.com/gh123man/app-mixer).

- `./AppMixer/scripts/check.sh` checks Swift formatting and script syntax, runs the full test suite, and builds the universal app.
- `xcrun swift-format format --in-place --recursive AppMixer/App/Sources AppMixer/Sources AppMixer/Tests AppMixer/Package.swift` applies the checked-in formatting rules.
- GitHub Actions validates pull requests and pushes to `main` on Intel, complementing local Apple Silicon tests. Headless CI sets `APP_MIXER_HARDWARE_TESTS=0` to skip the two physical-output tests; local tests include them by default.
- `AppMixer/release.json` records each version, build number, bundle identifier, and required signing/notarization policy. Notes live in `AppMixer/ReleaseNotes/`.

Update the release record and notes, run checks, commit and push to main, then wait for CI to pass:

```sh
./AppMixer/scripts/cut_release.sh --publish
```

The command requires clean, pushed main with passing CI and the six configured Apple secrets. It runs local tests and pushes an annotated version tag. Without `--publish`, it validates readiness. The tag starts `.github/workflows/release-dmg.yml`, adapted from OpenSnek: validate the tagged source, import the Developer ID certificate into a temporary Keychain, build/sign the universal app with hardened runtime and a secure timestamp, submit it to Apple, staple its ticket, then package/sign/notarize/staple the DMG. Gatekeeper checks must pass before publishing. The ZIP contains the stapled app too.

The workflow publishes a private prerelease with ZIP, DMG, SHA256SUMS, and a manifest containing the source commit and accepted notarization submission IDs. It refuses to replace an existing release. For a failed run, use GitHub's rerun command, or dispatch the workflow with its existing tag. Signing material is removed in an always-run cleanup step; only release artifacts and notarization diagnostics are uploaded.

Required repository Actions secrets (same names as OpenSnek):

- `APPLE_DEVELOPER_ID_APP_CERT_BASE64` — PKCS#12 certificate and private key, base64 encoded.
- `APPLE_DEVELOPER_ID_APP_CERT_PASSWORD` — PKCS#12 password.
- `APPLE_DEVELOPER_TEAM_ID` — signing team.
- `APPLE_NOTARY_API_KEY_P8`, `APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER_ID` — notarization API credentials.

RC.1 was Apple Development signed and not notarized. RC.2 and subsequent releases require Developer ID signing and notarization. The existing `local.AppMixer` bundle ID preserves preferences; changing signing identity may require approving system-audio access again. No extra privacy entitlements are added. Local `./run.sh` builds remain ad-hoc signed.

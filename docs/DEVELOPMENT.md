# QEQ developer guide

A small, native macOS menu bar mixer with independent app volume, mute, and five-band parametric EQ. Requires macOS 14.4 or newer; built with SwiftUI, Core Audio, and a small C++ DSP kernel. No third-party runtime packages.

## Try it

```sh
./run.sh
```

Click the three-slider menu bar icon. Start playback in Zoom, Spotify, or another app to make it appear in the mixer. Apps that only register an audio client stay hidden until they actually start output or have saved adjustments. Once an app has played, its controls stay visible while its audio clients remain open, including when paused. Open **EQ → Presets → Cut bass** on Zoom, then turn on the mixer. Approve macOS's system-audio permission when requested. Spotify stays untouched unless you change its controls or Global EQ.

The top-right switch is the global bypass. Switching it off or quitting destroys the taps and private aggregate devices, restoring the original audio paths. Each app’s switch bypasses its volume and EQ while preserving its controls. **Reset app** clears its settings. Global EQ still applies to every playing app on the selected output, including apps with their own processing bypassed. The direct path is restored when no EQ/volume changes or visible spectrum need a route. Settings are saved by app bundle ID; the unlabeled master switch defaults to on when no preference exists, then remembers the user’s on/off choice across launches.

The local app is at `QEQ/.dist/QEQ.app`. `./run.sh --no-build` launches it without rebuilding. `./run.sh --clean` rebuilds it. XcodeGen and Xcode are needed to build; the app bundle runs on its own.

## Permissions

Only `NSAudioCaptureUsageDescription` is declared. macOS calls this **system audio recording**, even though QEQ does not save or transmit audio. Processing happens in memory on the audio callback. There is no microphone capture, ScreenCaptureKit screen recording, Accessibility, Automation, administrator helper, network access, or installed audio driver. Physical microphone/line inputs contributed by an output device are explicitly disabled before starting; if isolation fails, the app refuses to start that route.

Permission is first requested when processing or live spectrum needs an app audio tap, not at launch. If access is denied, allow QEQ in **System Settings → Privacy & Security → Screen & System Audio Recording** (the exact panel label varies by macOS), then retry or relaunch. The local build is ad-hoc signed with the stable development identifier `local.AppMixer`; it is not notarized for distribution. macOS may request permission again after a rebuild.

The popup uses AppKit’s popover material for system backdrop blur and the Reduce Transparency fallback. A 55%-opaque system window-color backing softens backdrop visibility while retaining translucency. App cards use subtle translucent fills. Spectrum plots have opaque system backgrounds; plot backgrounds, labels, and response curves adapt to light and dark appearances.

## Latency and scope

- One device-scoped tap and private aggregate per playing app that needs processing or a visible spectrum. App and global EQ use two five-band filter banks in the same callback, before volume and sample-peak protection. The output device is the clock source; input is processed directly into output within the same Core Audio IOProc.
- No additional application ring buffer, scheduled AVAudioPlayer buffers, FFT window in the playback path, lookahead, or network round trip.
- The realtime C++ callback does not allocate, log, block, or acquire locks. Coefficients are calculated on a serial control queue and transferred using lock-free atomics. Changes ramp over 10 ms to reduce clicks; this does not delay audio by 10 ms.
- Diagnostics report the hardware **I/O buffer duration**, not measured end-to-end latency. True zero latency is impossible. Bluetooth, device drivers, and Core Audio add their own delay. Use built-in speakers or wired headphones for latency testing.
- Mono/stereo Float32 output devices with a single output stream are supported. Multichannel/multistream devices are rejected explicitly. This version processes the **current system output**; apps explicitly routed to a different output should be set to the system output first.
- EQ: five configurable bands, 20 Hz–20 kHz (limited to 45% of sample rate), ±18 dB. Bell, low/high shelf, and 12 dB/octave low/high cut filters. Bell/cut Q spans 0.1–10; shelf slope spans 0.1–1. Each band can be bypassed. Boosts raise their selected frequencies without fixed full-band attenuation. Stereo-linked sample-peak protection reduces gain only when output would exceed full scale, then releases over 50 ms; it adds no lookahead or playback buffering. The live “Limiting” indicator shows reduction. Lower app volume when more headroom is needed. This is sample-peak protection, not an oversampled true-peak limiter. Volume is 0–100%.
- Drag numbered graph handles to change frequency/gain. Click a band, enter exact frequency/gain/Q values, or use the width slider. The neutral line is the filter response (EQ dB, before app volume and peak protection); a dashed line indicates a preview while bypassed. The system accent color fills the live processed-output spectrum (−90…0 dBFS). Double-click a numbered handle to restore that band’s defaults.
- Global EQ spans the popup width with its expanded controls attached beneath the graph, above the scrolling app list. Only its visualizer collapses while an app's EQ is expanded; the global header, bypass switch, and EQ button remain available. The visualizer returns when the app editor closes, and global processing stays active throughout. EQ layout updates without geometry animation: the app list fills the remaining space inside a bounded popup, while incoming content slides down 24 points and fades in inside clipped bounds, and chevrons rotate. Reduce Motion disables those decorative animations. The popup fits its content up to 1,000 points or the available screen height; search is omitted to leave more room for apps. Its response line is subdued. Collapsed app rows show live output-peak meters (−60…0 dBFS), after volume, mute, and both EQs. Global bypass releases the taps, so meters show unavailable rather than fabricated activity.
- The minimum band gain is −18 dB, not silence: it leaves about 13% amplitude in the affected range. A logarithmic spectrum still shows that remaining energy; the Gain tooltip explains this amplitude relationship.
- The optional 16,384-sample Hann-window spectrum uses Accelerate off the audio thread at ~15 fps. Atomic snapshots never delay playback. At 48 kHz the analysis window covers about 341 ms of recent sound; this affects visual settling, not playback latency. Frequency bins use interpolated boundaries, and there is no extra peak hold to conceal EQ cuts or mute. Both the EQ-gain (left) and output-dBFS (right) scales are labeled; the frequency axis is logarithmic. Stereo powers are combined without phase cancellation. While the popup is open and the main mixer is enabled, playing apps acquire neutral routes as needed for analysis, even with flat EQ. Closing it releases analysis-only routes. The Global EQ graph overlays up to six app spectra with matching labels. Each trace uses a cached dominant icon hue keyed by app identity, or a deterministic fallback for monochrome/missing icons, so playback and list changes do not reassign colors; its filled envelope is the strongest app in each frequency bin, not a phase-aligned measurement of the final mixed output. Per-app spectra include both app and global processing. Global bypass always releases all routes.
- Chrome/Electron helper clients resolve to their outer application’s name, icon, and bundle ID. Legacy helper-key settings migrate to that app; existing parent settings take precedence.
- App discovery runs once per second. Helpers nested in a containing app are grouped with it. Saved/paused apps remain visible but acquire no route until playing to the selected output. Pausing releases the route. New audio processes and output changes rebuild affected routes; switching outputs may cause a brief transition. Pause/resume and sleep/wake are handled.
- Some protected/DRM audio may not be available to public process taps. Browser tabs share their browser's app control. No microphone EQ or input processing is provided.

## Build and validate

```sh
brew bundle
swift test --package-path QEQ
./QEQ/scripts/build_macos_app.sh --configuration release
./QEQ/scripts/generate_xcodeproj.sh --open
```

`QEQ/project.yml` is canonical. Generated Xcode projects, build products, and private signing files are gitignored. Tests cover the plotted response against rendered DSP at three sample rates, parametric Q/bypass, legacy settings migration, spectrum calibration and stereo phase handling, helper identity, filter frequency response, app-state isolation, volume/mute, mono/planar stereo, hardware-input exclusion in the DSP, invalid layouts, saved settings, and read-only live Core Audio discovery. Hardware discovery requires an available mono/stereo output.

## Command-line audio smoke test

Quit the menu bar app first to avoid duplicate taps, start playback in Chrome, then run:

```sh
QEQ/.dist/QEQ.app/Contents/MacOS/QEQ --audio-check=com.google.Chrome
```

This briefly applies a −3 dB bell filter, reports numeric callback/spectrum diagnostics, destroys the route, and checks that the original output and tap list were restored. It uses the normal app permission; it does not bypass macOS privacy controls or save audio. A SILENT result is inconclusive when the source is paused/silent or permission is unavailable.

## Listening checklist

1. Play Zoom's speaker test or a call plus Spotify. Set Zoom's bass to −12 dB. Confirm only Zoom loses bass.
2. Change Zoom's volume and mute. Confirm Spotify is unaffected.
3. Toggle global bypass while both play. Confirm original sound and volume return. Re-enable and confirm saved adjustments return.
4. Reset an app; confirm it returns to the direct system path. Quit QEQ while processing; confirm original sound continues.
5. Switch built-in speakers / wired headphones, pause and resume playback, restart an app, and sleep/wake the Mac.
6. For latency, compare the same video or call with mixer enabled/bypassed using wired output. The displayed buffer duration is not an acoustic measurement.

## Prior art

The single-callback private aggregate topology builds on [CoreAudioTapKit](https://github.com/CJStanfield/CoreAudioTapKit); its MIT notice is preserved in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). Apple documents the underlying [Core Audio process-tap API and permission](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps).

## Repository tooling and releases

The source repository is [gh123man/QEQ](https://github.com/gh123man/QEQ).

- `./QEQ/scripts/check.sh` checks Swift formatting and script syntax, runs the full test suite, and builds the universal app.
- `xcrun swift-format format --in-place --recursive QEQ/App/Sources QEQ/Sources QEQ/Tests QEQ/Package.swift` applies the checked-in formatting rules.
- GitHub Actions validates pull requests and pushes to `main` on Intel, complementing local Apple Silicon tests. Headless CI sets `QEQ_HARDWARE_TESTS=0` to skip the two physical-output tests; local tests include them by default.
- `QEQ/release.json` records each version, build number, bundle identifier, and required signing/notarization policy. Notes live in `QEQ/ReleaseNotes/`.

Before each release, update the record and notes, then regenerate the README screenshots from the real app:

```sh
./QEQ/scripts/cut_release.sh --prepare
./QEQ/scripts/check.sh
```

Review and commit the application changes, `docs/media/*.png`, and `docs/media/screenshots.json`. Push main and wait for CI, then run:

```sh
./QEQ/scripts/cut_release.sh --publish
```

The command requires clean, pushed main with passing CI, screenshots matching the current UI source, and the Apple and update-signing secrets. It runs local tests and pushes an annotated version tag. Without `--publish`, it validates readiness. The tag starts `.github/workflows/release-dmg.yml`, adapted from OpenSnek: validate the tagged source, import the Developer ID certificate into a temporary Keychain, build/sign the universal app with hardened runtime and a secure timestamp, submit it to Apple, staple its ticket, then package/sign/notarize/staple the DMG. Gatekeeper checks must pass before publishing. The ZIP contains the stapled app too.

The workflow renders screenshots again from the tagged source, checks the layouts, and publishes their ZIP alongside the app ZIP, DMG, SHA256SUMS, and a manifest containing the source commit and accepted notarization submission IDs. It refuses to replace an existing release. For a failed run, use GitHub's rerun command, or dispatch the workflow with its existing tag. Signing material is removed in an always-run cleanup step; only release artifacts and notarization diagnostics are uploaded.

Required repository Actions secrets (same names as OpenSnek):

- `APPLE_DEVELOPER_ID_APP_CERT_BASE64` — PKCS#12 certificate and private key, base64 encoded.
- `APPLE_DEVELOPER_ID_APP_CERT_PASSWORD` — PKCS#12 password.
- `APPLE_DEVELOPER_TEAM_ID` — signing team.
- `APPLE_NOTARY_API_KEY_P8`, `APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER_ID` — notarization API credentials.

RC.1 was Apple Development signed and not notarized. RC.2 and subsequent releases require Developer ID signing and notarization. The existing `local.AppMixer` bundle ID preserves preferences; changing signing identity may require approving system-audio access again. No extra privacy entitlements are added. Local `./run.sh` builds remain ad-hoc signed.

## Route recovery and diagnostics

A stalled app is released independently; other routes keep running. One automatic fresh-route attempt is allowed, then the affected app stays bypassed until Retry, a playback restart, new process IDs, or an output change. “No callbacks” is a route observation, not proof that capture permission is missing. Apps explicitly routed elsewhere show “Playing on another output.”

Use **Settings → General → Diagnostics → Copy diagnostics** for the macOS/app version, output format, app playback/device state, current process IDs, callback frames, and route messages. No audio is recorded. Test USB output with a saved-but-idle app alongside an actively playing app, then pause/resume, reconnect the device, and use global bypass.

## Screenshots and icon

```sh
python3 QEQ/scripts/screenshots.py
python3 QEQ/scripts/screenshots.py --check
./QEQ/scripts/generate_appicon.sh
```

The screenshot command renders the real SwiftUI views with labeled fixture settings in an offscreen app window. It never starts the audio engine, reads saved settings, or captures the screen. It also checks empty, populated, app/global EQ, long-list, smaller-screen and removal layouts. The source and image fingerprints in `docs/media/screenshots.json` prevent stale README screenshots from shipping. CI renders from its just-built app using `--skip-build`; normal preparation builds first. Screenshot fixtures use deterministic synthesized PCM (music harmonics, voiced speech, and noise), measured with a Hann-windowed FFT and labeled as simulated. The displayed EQ and volume are applied to those spectra; no live audio is captured.

The same command produces `desktop-mixer.png` and `desktop-app-equalizer.png` for the README: the actual app UI on an illustrated desktop with a mock menu bar and QEQ’s menu bar icon. The panel composites a blurred, spatially aligned copy of that illustrated wallpaper beneath the real UI, using the live app's shared 55% window-color tint; spectrum plots remain opaque. This approximates native translucency because offscreen bitmap rendering cannot capture WindowServer's behind-window material. The arrow and panel share one continuous backdrop. Both render at 2000 pixels wide; the desktop height grows to fit the panel without cropping. The primary README image expands FaceTime’s EQ with a bass cut while Chrome and Spotify stay collapsed. `DesktopScreenshot.swift` owns the composition, `ScreenshotAudio.swift` generates the audio fixtures, and `ScreenshotControls.swift` supplies clean field borders for offscreen capture only. These images are included in the source/checksum manifest and existing CI/release screenshot artifacts.

The icon was created with the built-in image-generation tool. The source asset and final prompt are in `QEQ/Branding/`. The generator script only creates the standard macOS icon sizes from that source. The package, modules, targets, and scripts use QEQ. The legacy `local.AppMixer` bundle identity is retained so existing settings and permission identity remain available. The menu bar uses a native template drawing of the three staggered slider rails and knobs, without the app icon’s panels or outer border.

Native screenshot rendering is also checked in CI before tagging. It reads fixture app icons directly from bundles to avoid headless IconServices stalls. A 90-second timeout retains a process sample on failure. RC.4 was tagged but not published after exposing that runner issue; RC.5 includes the fix.

For light-appearance screenshot QA, run `QEQ_SCREENSHOT_APPEARANCE=light python3 QEQ/scripts/screenshots.py --skip-build --output /tmp/qeq-light-screenshots`. The default README captures use dark appearance. Offscreen captures validate layout and colors; desktop backdrop blur is visible in the live popover.

## Performance

See [profiling results and commands](PERFORMANCE.md) for Release microbenchmarks and the opt-in `./run.sh --profile <absolute-jsonl-path>` CPU/route recorder.

## Updates and diagnostics

Settings → General includes **Start with macOS**, using `SMAppService.mainApp` without a helper or additional privacy permissions. QEQ registers once on the first normal launch, then respects changes made in QEQ or macOS Login Items. Registration failures are shown in Settings and can be retried with the toggle; approval requests link directly to Login Items. Screenshot and diagnostic CLI modes never register a login item.

The options menu → **Settings…** opens a native settings window. Release builds check QEQ's public GitHub releases at most once daily (also across restarts). Checks only change the **Update available** button; Sparkle is created after an explicit install click. Automatic downloads, unsolicited updater windows, and system-profile reporting are disabled. RCs require the **Include release candidates** toggle, even when the installed version is an RC. Manual checks and errors stay in Settings. Local development builds allow manual discovery and installation of signed releases; automatic checks are off.

Right-click an app → **Exclude** to remove it from the mixer and all processing, including Global EQ and analysis. Settings → **Excluded Apps** lists exclusions with a Remove action. Saved volume/EQ settings remain available when an app is restored. Exclusions persist by bundle identity, including known helper aliases; `com.apple.PowerChime` is excluded by default. Removing that default is remembered across launches.

Updates require both a published `appcast.xml` and the matching app ZIP. The checker compares version numbers numerically and never suggests older builds. Sparkle 2.9.3 verifies signed feeds and Ed25519 archive signatures before extraction, then handles installation and relaunch. QEQ keeps processing during download; normal termination releases audio routes before the updated app starts. Releases predating this mechanism need one manual installation to acquire it.

The release workflow now supports stable and RC tags, signs Sparkle's nested helpers before the app, notarizes/staples both formats, generates/verifies the signed appcast, and includes it in `SHA256SUMS`. Stable releases become GitHub's latest release; RCs remain prereleases. The Sparkle source revision is pinned in `QEQ/XcodePackages.resolved`; its official tool archive is also SHA-256 pinned in the workflow. Update both deliberately when upgrading Sparkle.

Production setup is one-time: with approval to create the repository credential, run `swift QEQ/scripts/setup_update_signing.swift`. It generates a dedicated Ed25519 seed, sends it to `gh secret set QEQ_SPARKLE_PRIVATE_ED_KEY` through stdin, and writes only the public key to `QEQ/update-signing.json`. It refuses to overwrite an existing key or secret. Commit the public key. The private key is never put in command arguments, logs, or a local file. Release builds fail closed without the key/secret or if archive/feed signature verification fails.

The default log level is Warning. Choose Debug before reproducing an issue, then **Save diagnostic log…** to collect current app/device/route state, EQ settings and recent logs in one text file. This file can contain app names and audio-device details; collection never records audio or uploads anything. Logs live in `~/Library/Logs/QEQ` and rotate between two files of at most 1 MB each. Logging runs on a utility queue, never the real-time audio callback. Debug adds a once-per-second state summary; other levels log lifecycle events/errors. **Clear logs** removes both files.

Offline update packaging smoke test, with a disposable in-memory key and no publication:

```sh
python3 QEQ/scripts/smoke_update_artifacts.py \
  --tools QEQ/.dist/sparkle-tools --output QEQ/.dist/update-smoke
```

The tools directory must contain the checksum-verified Sparkle 2.9.3 distribution (same archive/digest as the release workflow). The test signs a copy of the development bundle, generates a signed feed, verifies the archive against its embedded public key, rejects a tampered archive, and removes the disposable artifacts. It does not perform a live app replacement. Native settings and update-available screenshots are generated alongside the existing mixer captures.

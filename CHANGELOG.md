# Changelog

## Unreleased

## 1.0.1 — 2026-11-03

- Prevent popup opening pop-in by preparing its size before presentation and keeping live status and legend layout stable.
- Combine per-app volume sliders with smooth, app-colored activity meters; muted apps show gray source activity.
- Add optional volume boost up to 200%, with an exponential boost range and a clear 100% marker.
- Double spectrum detail to 192 bands and refresh at 30 Hz with short, smooth transitions.

## 1.0.0 — 2026-11-02

- First stable release of QEQ, the per-app mixer and equalizer for macOS.
- Global and per-app five-band parametric EQ, 11 presets, live spectra, independent volume, and quick mute.
- Global and per-app bypass, persistent app exclusions, and optional launch at login.
- Quiet update checks with explicit installation, RC opt-in, and diagnostic settings.
- Keep the translucent panel's tint consistent when opening, resizing, and changing focus.

## 0.1.0-rc.8 — 2026-11-02

- Add persistent app exclusions, default PowerChime exclusion, and a Settings table for restoring apps.
- Fix manual update installation from local builds and add Install update beside Check now.
- Use a native link-style Remove action for excluded apps.
- Move Copy diagnostics into Settings and simplify the main menu.

## 0.1.0-rc.7 — 2026-11-02

- Add Start with macOS, enabled on first launch and configurable in Settings.
- Add quiet update discovery, an Update available button, and explicit Sparkle installation with signed feeds and archives.
- Add concise Settings for automatic checks, RC opt-in, log levels, and local diagnostic-log collection.
- Reduce idle UI work and app-discovery overhead; reuse spectrum-analysis buffers during playback.
- Add opt-in CPU/route profiling and regression coverage for spectrum restart after pause, bypass, and closing the popup.

## 0.1.0-rc.6 — 2026-11-02

- Refine the popup with subtle system translucency, opaque spectrum plots, and light/dark appearance support.
- Simplify labels and menus, remove search and the footer, and give the app list more vertical space.
- Keep global controls visible during app EQ editing and contain slide transitions within the EQ area.
- Use stable, icon-derived spectrum colors and a branded monochrome menu bar icon.
- Enable processing by default and remember the master switch across launches.
- Refresh screenshots and shorten the README; rename the project structure and tooling to QEQ.

## 0.1.0-rc.5 — 2026-11-02

- Pin search above the app list and refresh screenshots with explicitly simulated spectra.

- Pin a full-width Global EQ above search and app controls, soften its response line, and add live output meters to collapsed apps.
- Clarify that a −18 dB band cut leaves about 13% amplitude instead of muting it.

- Add Global EQ above the app list, with an always-visible spectrum and layered app traces.
- Start spectrum analysis on opening the panel, including flat EQ, while preserving global bypass.
- Add 11 EQ presets, double-click band reset, system accent color, prominent app mute buttons, and a power-icon Quit button.
- Show the limiter indicator only while reducing gain.
- Correct low-frequency spectrum positioning and remove peak hold that concealed cuts; label output and EQ scales separately.
- Regenerate and verify README screenshots during release preparation; attach freshly rendered screenshots to releases.

## 0.1.0-rc.3 — 2026-11-02

- Rebrand as QEQ (Quick EQ), with a new app icon, concise README, and screenshots.
- Size the popover to its contents up to a screen-aware maximum.
- Replace automatic full-band boost attenuation with stereo-linked sample-peak protection and live gain-reduction feedback.
- Wait for active playback before routing restored app settings; release paused routes and identify apps on other outputs.
- Isolate stalled routes, bound automatic retries, and add copyable diagnostics.

## 0.1.0-rc.2 — 2026-11-02

- Mirror OpenSnek’s GitHub-hosted Developer ID signing and notarization setup.
- Require accepted Apple submissions, stapled tickets, and Gatekeeper approval for both app and DMG before publishing.

## Unreleased

- Resolve Chrome/helper clients into their parent app’s name and icon; migrate helper settings.
- Add per-app processing switches that preserve volume and EQ while bypassed.
- Add five-band parametric EQ, draggable response graph, precise frequency/gain/Q controls, selectable filter types, band bypass, and presets.
- Show live output spectrum and level while the EQ panel is open, with analysis off the realtime thread.
- Simplify the popover header to output selection information and the global mixer switch.

- Hide audio clients with no observed playback or saved adjustments; keep controls available when a previously playing app pauses.

## 0.1.0 — 2026-11-02

- Initial native macOS menu bar app with per-app volume, mute, bass/mid/treble EQ, and a Cut bass preset.
- Global bypass and per-app reset release Core Audio taps and restore original output.
- Audio-only permission, in-memory DSP, saved app settings, output-change and sleep/wake recovery.
- Single-callback audio path with lock-free parameter handoff, smooth changes, and conservative boost headroom.

# Changelog

## Unreleased

- Show the master switch without a visible label, default it to on, and remember the user's on/off choice across launches.
- Keep global spectrum colors stable per app and derive their hue from each app's icon, with a deterministic fallback for missing or monochrome icons.
- Increase the popup height limit from 720 to 1,000 points, capped to the available screen height, to give scrolling app controls more room.
- Keep expanded Global EQ controls attached to the graph above the app list, and remove search to free vertical space.

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

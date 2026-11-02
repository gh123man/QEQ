# Changelog

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

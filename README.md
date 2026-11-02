<p align="center">
  <img src="AppMixer/Branding/QEQ-icon.png" alt="QEQ app icon" width="160">
</p>

<h1 align="center">QEQ</h1>
<p align="center"><strong>Quick EQ</strong><br>Per-app mixer and equalizer for macOS.</p>
<h2 align="center"><a href="https://github.com/gh123man/app-mixer/releases">Download</a></h2>
<p align="center">macOS 14.4+ · Apple Silicon & Intel · Signed and notarized releases</p>

<p align="center">
  <img src="docs/media/mixer.png" alt="Per-app volume and bypass controls" width="360">
  <img src="docs/media/equalizer.png" alt="Five-band parametric EQ with a bass-cut preview" width="360">
</p>
<p align="center"><sub>Native interface shown with sample app settings.</sub></p>

## Features

- Independent app volume, mute, and five-band parametric EQ.
- Draggable EQ curve, exact controls, presets, and live output spectrum.
- Per-app bypass and one switch to restore system audio.
- A menu bar panel that fits your app list, scrolling only when needed.
- Direct audio processing without added playback buffers or installed drivers.

## Get started

Open the DMG, drag **QEQ** to Applications, and launch it. Start playback, click the sliders in the menu bar, adjust an app, then enable the mixer.

Allow **system-audio capture** when macOS asks. No microphone, Accessibility, or screen capture permission is needed. Every launch starts bypassed.

## Build

Requires Xcode and Homebrew.

```sh
brew bundle
./run.sh
```

[Development, testing & releases](docs/DEVELOPMENT.md) · [Third-party notices](THIRD_PARTY_NOTICES.md)

# QEQ hardware integration plan

> Current production baseline: [V2 peripheral firmware 0.3.0](HARDWARE-PERIPHERAL-BASELINE.md).
> All four pairs and LEDs are exposed, with capability discovery, runtime slider
> calibration and USB media keys. Earlier single-app notes below are historical.

**Current board: hardware V2.** Use `hardware-dev` in both repositories and read
[the V2 baseline](HARDWARE-V2.md) before building or flashing. The model-1 and
prototype wiring sections below describe the existing host integration; V2
four-app control remains separate work.

Status: initial native integration implemented, 2026-11-08. The ESP32-S3 MIDI
build has been flashed and bidirectional QEQ feedback verified. General-purpose
MIDI Learn, arbitrary board profiles, and broader reliability work remain planned.

## Current test-board assignments

| Hardware | Action |
| --- | --- |
| Pot / slider, CC 16 | Selected app volume, with soft takeover |
| Standalone GPIO11 button, CC 19 | Selected app mute |
| Encoder rotation, CC 17 | Current macOS output volume, 1/64 per electrical step |
| Encoder GPIO10 push button, CC 18 | Global QEQ bypass |
| RGB LED | Selected app's spectrum accent color, including while muted/bypassed |

Right-click an app in QEQ and choose **Use hardware controls** to assign the pot
and standalone button. Assignment persists by bundle ID and controller serial.
If the app disappears, its controls become unavailable rather than changing targets.
The encoder continues to control system volume independently of QEQ processing.
Outputs without writable volume controls show `SYSTEM --` on the LCD; no keyboard
emulation or per-app volume fallback is used. The LCD also shows app volume, mute,
global bypass, and pickup status. The LED is off without an available selected app.

Prototype protocol v2 adds RGB and system volume to feedback and intentionally
rejects v1 peers. See `docs/HARDWARE-PROTOCOL.md` and the matching firmware document.

## Direction

Use class-compliant USB MIDI 1.0 for controls and CoreMIDI in QEQ. Add a small,
versioned QEQ SysEx extension for identity, capabilities, and host feedback. The
purpose-built controller should connect and receive its default assignments
automatically; other MIDI controllers should work through saved mappings and MIDI
Learn. Keep the internal control model independent of MIDI.

MIDI provides a common control transport. Custom serial would require separate
device discovery and configuration, while keyboard/media-key HID does not express
per-app targets or rich feedback well. Keep serial for development diagnostics.
Defer BLE, MIDI 2.0, motorized controls, and firmware updating through QEQ.

## Starting point and first risk

- Firmware: ESP32-S3, one analog pot, one quadrature encoder with push switch,
  one additional button, RGB LED, and GC9A01 display. Input decoding is already
  host-testable, but GPIO configuration and demo behavior live in `src/main.cpp`.
  Pot averaging and JSON telemetry currently run at 100 ms intervals.
- Toolchain: PlatformIO Espressif32 6.12.0 / Arduino ESP32 2.0.17. The installed
  board profile selects `ARDUINO_USB_MODE=1` (hardware CDC/JTAG). Its SDK enables
  TinyUSB MIDI, but the Arduino USB library lacks the newer USBMIDI wrapper.
  Native USB serial working does not establish that MIDI works.
- QEQ: `MixerModel.edit` in `QEQ/App/Sources/App.swift` already owns settings edits
  and persistence, and `MixerEngine.update` applies them without changing route
  lifetime. Hardware should enter the same edit path as the UI.

First prove MIDI input/output and recovery on the native USB connector using
USB-OTG/TinyUSB mode. Try a small adapter against the pinned stack first. If that
is brittle, evaluate a pinned newer Arduino stack or ESP-IDF before committing to
the firmware architecture. An Arduino 3 migration also changes the current LEDC
calls and requires RGB/display/input regression checks. Retain the existing bench
firmware environments and a documented BOOT/RESET recovery path.

## Architecture

Firmware pipeline:

`board definition → input drivers → typed control events → MIDI transport`

Host pipeline:

`CoreMIDI → device/profile registry → mappings → QEQ actions → existing model`

Feedback follows the reverse direction from authoritative QEQ state to hardware
LED/display renderers. It must never generate another input event.

- Give every control a stable logical ID and kind: absolute, relative, or button.
  Describe ranges, polarity, encoder resolution, labels, and feedback capabilities
  in board profiles, not app-specific GPIO code. Adding controls should primarily
  extend a profile, with drivers added only for new hardware types.
- Keep sampling, debounce, filtering, rendering, diagnostics, and USB transport
  separate. Use bounded queues; coalesce absolute values, preserve button edges
  and accumulated encoder deltas, and expose overflow diagnostics. A disconnected
  host or slow display must not block input scanning.
- Use standard CC for absolute controls, an explicitly documented relative CC
  encoding for encoders, and press/release messages for buttons. Start with 7-bit
  interoperability, support paired 14-bit CC for QEQ analog controls where useful,
  and specify pair ordering/timeout behavior. Generic relative encodings vary and
  need selectable profiles. Keep raw ADC precision and calibration independent of
  the transport; 14-bit encoding does not create 14-bit sensor precision.
- Define a bounded, versioned SysEx handshake: product/model, firmware and protocol
  versions, persistent device ID, control descriptors, and feedback features.
  Specify framing, 7-bit payload encoding, maximum sizes, timeouts, unknown fields,
  and compatibility behavior before implementing both sides. Use legitimate USB
  identity and MIDI manufacturer-ID arrangements for distribution; prototype IDs
  must be clearly scoped and must not impersonate another product.
- Match QEQ hardware through the handshake and endpoint relationships, not its
  display name alone. Keep separate instances for multiple identical devices.
  Unknown MIDI devices receive no automatic action assignments or proprietary
  messages; users opt into a mapping. Incompatible QEQ firmware gets a clear status.
- Put transport-independent actions, mappings, scaling, and pickup logic in
  `QEQCore`; CoreMIDI discovery, decoding, connection lifecycle, and profile storage
  in `QEQAppSupport`; device settings and MIDI Learn in the app. Update framework
  dependencies in `QEQ/Package.swift` and canonical `QEQ/project.yml` as needed.
- Bind app targets by bundle identity, never changing list position. Model fixed
  app bindings and an explicit hardware-selected target separately. Marshal MIDI
  callbacks onto the appropriate control/model executor. No MIDI work belongs in
  the audio callback, and normal parameter edits must not rebuild audio routes.
- QEQ owns volume/mute/labels while connected. Re-sync feedback after UI edits,
  reconnect, and wake. Do not apply boot snapshots as user gestures or replay stale
  button presses. Absolute controls use soft takeover: after reconnect or target
  changes, movement takes effect only when the control crosses the current value.
  Reuse `VolumeSliderScale` and existing boost limits.

## Delivery milestones

1. **USB proof and protocol contract.** Add a separate MIDI build environment,
   prove bidirectional enumeration on macOS, preserve diagnostics where feasible
   (composite MIDI + CDC), and verify recovery flashing. Document the wire contract
   with shared golden message fixtures in both repos. Exit: one CC and one feedback
   message round-trip, including unplug/replug, without breaking bench inputs.
2. **Firmware framework.** Extract the current board into descriptors and drivers;
   emit absolute values, relative deltas, and both button edges. Add calibration,
   hysteresis, and faster control updates independently of 10 Hz telemetry. Preserve
   the local LED/display demonstration as an explicit bench mode. Exit: host tests
   cover debounce, encoder direction, scaling, queue pressure, and wire fixtures;
   all existing hardware remains usable.
3. **First native QEQ slice.** Add CoreMIDI lifecycle and the QEQ handshake/profile.
   Current test-board defaults are listed above. Initially choose
   a deterministic available app, then preserve the chosen bundle ID; if it exits,
   show unavailable rather than silently redirecting the controls. Show target,
   level, mute, and connection state on the display/LED. Exit: automatic setup,
   safe takeover, UI/hardware synchronization, and operation with the popup closed.
4. **Generic devices and expansion.** Add MIDI Learn, persistent per-device
   mappings, absolute/relative modes, and assignment editing. Extend actions to EQ
   and bypass. Support multiple controls, banks, and controllers without rewriting
   the transport or mixer. Exit: a generic controller and a simulated larger QEQ
   board work through the same action layer.
5. **Reliability and release.** Exercise reconnect, sleep/wake, firmware mismatch,
   unavailable apps, duplicate devices, noisy analog inputs, fast encoder movement,
   malformed/fragmented SysEx, and sustained event bursts. Measure control latency
   separately from audio latency; aim for under 20 ms device-to-host control delivery
   during normal operation, then establish a measured target. Document setup,
   diagnostics, recovery, and supported firmware/protocol versions.

## Validation and repository workflow

- QEQ and firmware work live on `hardware-dev` or feature branches based on it.
  Hardware V2 is the default; see [the V2 baseline](HARDWARE-V2.md).
  Use small milestones and record compatible commit/protocol versions across repos.
- QEQ baseline and each implementation milestone: `swift test --package-path QEQ`
  with local hardware tests enabled. App changes also require the generated macOS
  Xcode build. Add deterministic virtual MIDI tests for parsing/routing/lifecycle
  plus a physical-board acceptance pass; neither substitutes for the other.
- Firmware: `./run.sh test` and `./run.sh build`, extended to the MIDI environment.
  Physical validation must include controls, RGB/display, disconnects, and recovery.
- Avoid coupling initial integration to a firmware updater or a new master-volume
  feature. The existing per-app volume and mute path provides the first useful slice.

## Technical references

- [Espressif USB device stack](https://docs.espressif.com/projects/esp-usb/en/latest/esp32s3/usb_device.html)
- [Espressif Arduino MIDI controller example](https://github.com/espressif/arduino-esp32/blob/master/libraries/USB/examples/MIDI/MidiController/MidiController.ino)
  (newer upstream example, not evidence of compatibility with the pinned 2.0.17 core)
- [Arduino ESP32 2.x to 3.0 migration](https://docs.espressif.com/projects/arduino-esp32/en/latest/migration_guides/2.x_to_3.0.html)
- [Apple CoreMIDI client notifications](https://developer.apple.com/documentation/coremidi/midiclientcreatewithblock(_:_:_:))

## Native display streaming

Display streaming now starts automatically when compatible hardware connects.
QEQ uses native macOS USB APIs, bundled LZ4, and an offscreen Metal renderer;
there is no Python worker or `--display-stream` argument. See
[native display integration](NATIVE-DISPLAY.md) for architecture, CPU measurements,
compatibility, and the remaining physical-device smoke test. The earlier
[prototype measurements](DISPLAY-STREAMING-RESULTS.md) remain historical results.

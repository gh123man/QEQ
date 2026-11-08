# Native QEQ display streaming

QEQ automatically discovers the purpose-built board's vendor display interface
and renders its selected-app screen with Metal. No Python worker, Homebrew USB
library, launch argument, raster file, or helper process is required.
QEQ now targets Apple Silicon only; the renderer uses shared GPU textures and buffers.

## Hardware compatibility and setup

Use the original ESP32-S3 board with the `stream` firmware from vol-firmware's
`codex/usb-display-streaming` branch (`b64dc09` or compatible protocol v1). Connect
its **native USB** connector, then launch QEQ normally with `./run.sh`. CDC/COM is
not used for graphics. The non-streaming `midi` firmware retains its local screen
and still works for controls.

Discovery matches the development VID/PID 303a:1001 and vendor interface FF/51/01.
The native IOUSBHost client exclusively claims that interface only; it never seizes
or resets the composite device, detaches kernel drivers, or opens the MIDI/CDC
interfaces. A validated capabilities exchange selects dimensions, RGB565 format,
orientation, and round/rectangular shape. USB serial `XXXXXXXXXXXX-D1` pairs with
the existing MIDI identity serial `XXXXXXXXXXXX`; each connected board has its own
worker, scene, acknowledged pixel baseline, and reconnect state.

The existing MIDI assignments remain: slider controls the selected app with pickup,
standalone button mutes that app, knob adjusts system volume, and knob push toggles
global bypass. Right-click an app and choose **Use hardware controls** to assign it.
Generic MIDI Learn and four-channel host assignments remain separate work.

## Rendering and scheduling

The main actor supplies immutable scene values and a cached CGImage snapshot for
the selected app's icon. A per-device background queue owns CoreText layer caching,
Metal commands, tile comparison, LZ4, USB writes, and ACK handling. It never blocks
the audio callback or waits on USB/Metal from the main actor.

The display is offscreen, so it uses a Metal compute pipeline rather than a
CAMetalLayer with a Mac window drawable. Metal draws the background/ring, composites
seven cached text/icon layers, and packs RGB565 directly into shared GPU memory.
CoreText rasterizes only changed text layers; unchanged layers are reused. This is
not a promise that font rasterization itself runs on the GPU. The CPU reference
renderer remains solely for fixture and comparison tooling.

IOKit notifications drive connection/disconnection; there is no USB polling loop
or frame-file polling. Updates replace one locked latest-state mailbox. At most
one frame is awaiting ACK; intermediate input states cannot accumulate into a
stale-frame queue. Unchanged scenes submit no GPU command buffers. Connected idle
screens send a 500 ms heartbeat; no board means no render worker or GPU allocation.

Capabilities, messages, tile bounds, compressed lengths, checksums, frame/session
IDs, and ACK tile/byte counts are validated. A successful matching ACK advances the
baseline only after firmware has completed the LCD writes. Any failed exchange
closes the interface and retries with bounded backoff, a fresh nonce, and all tiles.
Sleep/stop cancels work, closes interfaces, and drops pending scenes. Wake/start
re-registers discovery and reopens connected boards. The firmware restores its local
screen when heartbeats stop. Frames remain tile-applied, not atomic/tear-free.

The LZ4 1.10.0 codec is compiled into the app with its BSD license bundled. macOS
IOUSBHost/IOKit and Metal are system frameworks. RGB565 quantization happens before
lossless compression; exactness applies to transmitted pixels, not original RGBA.

## Measured CPU improvement

On the development Mac, an optimized 500-frame volume sweep using the same app
icon and layout measured:

| Warm render stage | Previous CPU rasterizer | Cached Metal renderer |
| --- | ---: | ---: |
| Process CPU per changed frame | 2.225 ms | 0.086 ms |
| Wall time per changed frame | 2.229 ms | 0.229 ms |

That is about **96% less render-stage CPU**, including driver CPU work. It is not a
96% claim for the whole app. USB, encoding, audio processing, and other app UI work
are outside this comparison. No GPU work is scheduled for unchanged content by the
service. Results: [JSON](benchmarks/native-display-rendering-2026-11-08.json).

Reproduce the optimized comparison and app-owned PNG preview:

```sh
swift run -c release --package-path QEQ QEQDisplayBench --compare /tmp/qeq-renderers
```

The earlier physical USB/LCD timings remain in
[the prototype report](DISPLAY-STREAMING-RESULTS.md); they do not measure the new
IOUSBHost transport. The board was unavailable during native integration by user
request, so the native API's physical attach/replug/sleep/wake path and new
end-to-end hardware timing still need a device smoke test. Software validation uses
the actual firmware C++ receiver, not a reimplementation, for exact pixels, raw
fallback, ACK loss, expiry, and full-refresh recovery. Worker tests cover latest-state
coalescing, idle rendering suppression, stop, retry, and discovery lifecycle.

## Device smoke test before release

1. Start QEQ normally, attach the streaming board, and confirm the screen appears.
2. Exercise app volume/mute and system volume/bypass; verify prompt graphics.
3. Unplug/replug, sleep/wake, and quit/relaunch QEQ. Confirm complete recovery and
   the local disconnected screen when QEQ exits.
4. Check **Copy diagnostics** for MIDI and display status. With no controls moving,
   verify low CPU and no repeated reconnection messages.
5. Repeat with two boards if multiple-device support is to be released as verified.

The old Python worker must be stopped before testing; it would already own the
vendor interface. It remains an optional standalone firmware benchmark tool only.

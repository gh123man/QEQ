# Native QEQ display streaming

> Current production baseline: [V2 peripheral firmware 0.3.0](HARDWARE-PERIPHERAL-BASELINE.md).
> All four pairs and LEDs are exposed, with capability discovery, runtime slider
> calibration and USB media keys. Earlier single-app notes below are historical.

Hardware V2 is now the default development board; see [HARDWARE-V2.md](HARDWARE-V2.md).
Use `stream-v2` for the complete four-pair peripheral on V2 pins. The explicit
`stream` firmware and physical setup below apply to the original prototype.
QEQ discovers and assigns each physical pair independently.

QEQ automatically discovers the board's vendor display interface. Both HW1 and
HW2 use the Metal round UI on the display worker. CoreText and Core Graphics only
rasterize cached text/icon sprites; neither board requires a separate host process.
The Metal round UI is the only renderer, including rectangular negotiated outputs.
The retired CPU and seven-layer renderers have been removed from the app and benchmarks.

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
orientation, and round/rectangular shape. USB serial `XXXXXXXXXXXX-D1` or `XXXXXXXXXXXX-D2` pairs with
the existing MIDI identity serial `XXXXXXXXXXXX`; each connected board has its own
worker, scene, acknowledged pixel baseline, and reconnect state.

Both profiles use the existing MIDI messages. With native round display streaming,
knob press opens or selects from the menu on either board. Without that display,
the original prototype retains its bypass mapping.

## Rendering and scheduling

The main actor supplies immutable scene values and a cached CGImage snapshot for
the selected app's icon. A per-device background queue owns CoreText layer caching,
Metal commands, tile comparison, LZ4, USB writes, and ACK handling. It never blocks
the audio callback or waits on USB/Metal from the main actor.

The round display uses an offscreen Metal compute pipeline, not a Mac window
or CAMetalLayer. A bounded 96-slice texture atlas caches text and app icons.
Metal composites the sprites, circular clipping, volume ring, app halo, spectrum
and RGB565 output. Tests and benchmarks use this same production renderer.

The luminous spectrum preserves the horizontal frequency ordering and −90…0 dBFS
normalization of the app. It resamples to 64 points, with fast attack, slower decay,
three fading history traces and restrained per-app traces. Bloom and a continuous
fill extend to the bottom of the circle. All movement follows real audio data;
there are no generated beats or idle particles. The lower fill is anchored to the
screen so it stays unchanged beneath moving peaks. A shared RGB565 luminance
palette compresses the glow; static app gradients use fixed spatial dithering.
Animated spectrum dithering is suppressed to reduce USB bandwidth.

Navigation uses a scene graph: shared app icons interpolate between carousel,
actions, slots and volume positions, while shared rings stay continuous. Other
elements zoom/fade inward or outward according to navigation depth. Carousel
motion is flat and linear, with slightly smaller off-focus icons and a fade at
the circular edge rather than an inner rectangular clip. It takes 250 ms; page
transitions take 340 ms. All display text uses at least 14 logical pixels. Interruptions retarget from the
visible state. Ring and percentage use the same easing, and home volume remains
transient with the existing timeout and inward/outward ring motion. The app icon
and ring remain visible above the smaller action and slot carousels.

The worker still targets 30 fps with at most one SPI-complete frame ACK pending.
Reduce Motion bypasses navigation/spectrum interpolation. A full acknowledged repaint follows settled navigation to clear any residual
partial-update artifacts; it does not reset the USB session or run a periodic
redraw loop. Rendering stops when input and transitions settle. The new UI uses the existing pixel protocol and
needs no firmware change on a compatible `stream` (HW1) or `stream-v2` (HW2) image.

A warmed optimized host-only benchmark of 600 changing luminous-spectrum frames
measured about 0.24 ms/frame on the development Mac before USB transfer. This is
rendering cost, not measured visible panel frame rate. Physical tearing remains
possible because the panel updates are not synchronized to a TE signal.

HW1 comparison (2026-11-09): the same 247-frame native-rendered sequence before
and after the anchored fill / glow-palette changes completed with no rejected
ACKs. Median spectrum transfer-to-ACK time improved from 79.23 ms to 36.54 ms
(about 13 to 27 frames/s); median transition delivery improved from 77.07 ms to
54.31 ms. The sequence is a synthetic workload, not a guarantee of live frame
rate or proof of visible panel correctness. Heavy full-screen transitions remain
transport-limited. Bounded display timing logs separate render, tile preparation,
transfer, and firmware LCD time for further diagnosis. Full repaint on settled
navigation is regression-tested against the actual firmware receiver; visual
artifact clearance still needs confirmation on the physical LCD.

HW2 validation (2026-11-09): the user confirmed the standalone waiting screen,
streamed UI, dial navigation, and slider-overlay click opening app settings.
The deployed firmware retains the original raw/LZ4 tile transport and panel
writer. HW1 remained blank after restoring that same baseline; its display issue
is unresolved and is not evidence of a confirmed hardware failure.

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

The LZ4 1.10.0 codec is compiled into the app with its BSD license bundled. The
host reuses an HC level 9 encoder, resetting its history for every independent
tile rectangle (at most 32×32). Output scratch space uses `LZ4_compressBound`;
raw fallback is retained. A negotiated extension permits smaller changed rectangles
inside each grid cell; older firmware receives full-cell tiles. Unchanged tiles
are compared before copying. macOS
IOUSBHost/IOKit and Metal are system frameworks. RGB565 quantization happens before
lossless compression; exactness applies to transmitted pixels, not original RGBA.

## Historical renderer comparison

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

Those renderers are retired; the historical numbers above do not describe the
current round UI. Generate a fresh workload with the production Metal renderer:

```sh
swift run -c release --package-path QEQ QEQDisplayBench /tmp/qeq-metal-workload
```

The 600-frame workload covers synthetic spectrum motion, menus, app actions,
slots, volume, slider overlays and playback. `workload.json` identifies the
renderer, phase and measured render duration. Its `force_full` field is retained
for reproducing older benchmark boundaries; normal transitions now use deltas.
The `.qras` files contain those exact GPU-rendered RGB565 bytes; there is no CPU
UI fallback or `--compare` path. Use a fresh directory for each workload.
Offline rendering is not a measurement of USB latency or visible frame rate.

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

## V2 carousel transfer measurements

The 2026-11-08 carousel build targets 30 Hz. V2 SPI runs at 40 MHz (the
installed GC9A01 driver's ESP32 default), with ROM IEEE CRC-32 checks and a
32 KiB bounded receive buffer. The initial legacy prototype comparison used
10 MHz; both streaming profiles use 40 MHz as of the later 2026-11-09 update.
The wire protocol, tile checksums, one-frame ACK discipline, and reconnect baseline
are unchanged. Host interoperability fixtures use the equivalent table CRC.

A matching native-rendered animation sequence improved median transfer-to-ACK time
from **92.8 ms to 32.9 ms**, with p95 **127.9 ms to 44.1 ms**. A subsequent run
through the production IOUSBHost implementation validated **624 consecutive frame
ACKs**, median **33.1 ms**, p95 **44.1 ms**, maximum **50.4 ms**. These are transfer
measurements with pre-rendered frames, not a guarantee of 30 visible fps. Heavy
transitions can exceed the 33.3 ms budget. Firmware input polling remained within
3.1 ms during that run. Full pixel completion is still tile-applied, without TE
synchronization; physical artifacts and tearing need visual validation.

The board disappeared from USB after the subsequent app launch, reproducing the
pre-existing intermittent issue. The faster transfer results do not establish
connection stability. See [measurement summary](benchmarks/round-display-transfer-2026-11-08.json).

After reconnecting with QEQ running, a 45-second capture contained 451 consecutive
samples, all with active host feedback, zero MIDI queue/overflows, and constant
303,916-byte free heap. The V2 MIDI endpoint remained online. This is a short smoke
check, not proof that the intermittent disconnect is resolved.

## Disconnect isolation — 2026-11-09

After the user reported another abrupt V1 stop, USB, MIDI and CDC were all absent
while QEQ remained running. With a fresh reconnect and QEQ stopped, 601 telemetry
samples covered 60 seconds with no sequence gaps or heap change. QEQ's temporary
`./run.sh --no-build --hardware-midi-only` diagnostic mode also produced 601 samples
across 60 seconds with host feedback active, no sequence gaps, and stable heap.
That launch flag prevents opening the display vendor interface; normal launches
still enable display streaming.

With MIDI-only QEQ left running, a separate replay through the production native
USB transport completed all 624 frame ACKs (43.65 seconds of transfer time).
CDC telemetry stopped after 227 samples / 22.602 seconds, but the replay continued
and a subsequent independent MIDI observer still received packets. Thus a CDC
stall alone does not establish a whole-board crash. Reopening CDC produced no data
in a four-second check.

Restoring the normal live display path reproduced disappearance of USB, MIDI and
CDC. The independent observer had seen one unchanged MIDI boot identity before
traffic stopped. This points toward the live display path or its interaction with
the USB stack, but the root cause is not established: the replay and live workload
have different timing/content. The app now logs display failure phase, error domain
and code under `local.AppMixer` / `HardwareDisplay`. The instrumented build passed
87 tests and the macOS build.

The instrumented live run then lasted about five minutes with physical controls
before timing out reading ACK for frame 4283 at 09:38:16 local time. Repeated HELLO
attempts subsequently timed out reading capabilities (IOUSBHost code -536870186).
Independent MIDI packets continued with the same boot identity, USB remained
present, and recent heap readings were stable. This captured failure is a stalled
display channel, not evidence of a full reset. A separate endpoint-IN clear-stall
experiment succeeded at the USB control level but did not restore HELLO replies.
No recovery reset or speculative firmware fix is claimed by these tests.

An optional read-only vendor/interface EP0 request (type 0xc1, request 0x51,
value 1, index = display interface) exposes 24 little-endian words, optionally
extended to 40 words / 160 bytes with read-only display, CDC and MIDI
controller registers (the intermediate 128-byte form is also accepted). Old hosts
can request the original 96-byte prefix; new hosts accept either length.
Magic is `QGD1`, version 1. QEQ logs the snapshot after a display failure before
closing the interface; old firmware can reject it without changing the normal
stream protocol. It records uptime, receiver phase/last loop time, USB pump/byte
counters, tiles, replies/drops, queue sizes, scheduled work, minimum free task
stack (ESP-IDF bytes), last reply frame, vendor FIFO size, endpoint busy flags,
maximum input gap and free heap. Phases: 0 startup, 1 waiting, 2 decoding,
3 pixel SPI write, 4 disconnected-screen draw, 5 scheduling USB work, 6 expiry
check. Values are independent samples, not a coherent frame snapshot. This allows
failure diagnosis without opening CDC or resetting the composite MIDI device.


### Captured USB reply stall and synchronization trial

The EP0-instrumented V1 build reproduced a failure without CDC open. At
09:53:28, the receiver's last-loop timestamp matched current uptime; input bytes
were fully consumed, the application receive buffer and reply queue were empty,
and no replies had been dropped. Yet the vendor IN endpoint stayed busy and
its transfer-completion counter stayed at 4 while new HELLO replies accumulated.
The minimum remaining receiver stack was 2,172 bytes and heap stayed constant.
MIDI still worked. This localizes that failure to the USB reply path rather than
a blocked SPI/pixel task. A clear-stall request alone did not help. An experimental
SET_FEATURE(HALT) followed by clear-stall timed out and was followed by a new boot;
this recovery experiment is not part of QEQ or the firmware.

The next V1 trial serializes DWC2 transfer setup and the USB interrupt using one
ESP32 cross-core critical section. The pinned TinyUSB 0.16 implementation changes
shared endpoint/FIFO state from both paths, while Arduino creates its USB task
without core affinity. This is a candidate race fix, not yet a proven root cause.
`usb_dcd_guard.cpp` intercepts only USB interrupt allocation and DCD transfer setup
via linker wrappers; SDK files remain unchanged. The stream and stream-v2 builds
include the guard. Link disassembly confirms the wrappers are used. Firmware host
tests and all nine build profiles passed. QEQ's diagnostic build passed 87 tests
and the macOS build. Physical stress/control validation is recorded below.


The guarded V1 image passed 624 consecutive native frame ACKs (median 77.18 ms,
p95 106.40 ms at the existing 10 MHz LCD clock) with MIDI feedback active,
followed by 12 display-client reopenings / 24 additional validated frames,
including idle-expiry gaps. Maximum reported input polling gap was 3.070 ms.
Starting normal QEQ after the replay produced one malformed reply during handoff,
then automatically negotiated a fresh 240x240 session on the next attempt.
That recovered protocol error is distinct from the persistent busy-IN stall.


The subsequent 180-second live display capture had no repeated timeout after
successful negotiation. The user confirmed that turning/clicking the dial and
scrolling the menu now responded. An independent MIDI capture spanning at least
78.94 seconds recorded 1,304 messages, including 62 rotary and 79 rotary-button
messages, with one unchanged boot identity. The guarded V1 firmware and full QEQ
app are left running for longer use. These are successful short stress/control
checks, not proof that the intermittent issue is eliminated. V2 builds, but this
synchronization change has only been physically tested on V1.

Driver reference for the synchronization hypothesis:
[TinyUSB 0.16 DWC2 transfer setup and interrupt handling](https://github.com/hathach/tinyusb/blob/0.16.0/src/portable/synopsys/dwc2/dcd_dwc2.c).
The wrapper is a local candidate fix; no upstream fix equivalence is claimed.


### Matching V1 and V2 display clocks — 2026-11-09

The user confirmed that V1 and V2 use the same display hardware. Removed the
legacy 10 MHz streaming override; both `stream` and `stream-v2` now use the same
40 MHz setting. Flashed V1 with the existing USB synchronization guard retained.
Firmware host tests, all nine firmware builds, and 87 QEQ tests passed.
The same 624-frame native replay passed every ACK with MIDI active: median
32.56 ms, p95 44.58 ms, maximum 50.64 ms, maximum input polling gap 3.091 ms.
The preceding guarded V1 replay at 10 MHz had a 77.18 ms median. These measurements
verify protocol completion and faster transfers, not tear-free physical output.
The full QEQ integration was relaunched for visual testing.


### USB FIFO mapping correction — 2026-11-09

The earlier interrupt guard did **not** fix the stall: the busy-IN failure recurred
when handing the 40 MHz replay back to QEQ. A FIFO-only trial removed that guard; the combined correction described below
restores it for the actual driver's shared transfer-state race. Inspecting the
linked SDK archive identified Espressif's older
`dcd_esp32sx.c`, rather than the upstream `dcd_dwc2.c` suggested by the TinyUSB
0.16 headers. Its IN-endpoint open function selects transmit FIFOs sequentially,
but programs FIFO memory regions and writes data using endpoint numbers.
The composite CDC/MIDI/display descriptor opens IN endpoints in order 5,4,1,2;
endpoint 5 is the SDK's unused CDC notification special case. The remaining
endpoints incorrectly selected FIFOs 1,2,3 instead of their configured 4,1,2.

On V1, an independent EP0 snapshot confirmed display endpoint 2 selected FIFO 3
and reported 256 free FIFO words, rather than the allocated 47-word region.
`src/usb_dcd_fifo.cpp` now wraps `dcd_edpt_open`: after successful SDK allocation,
it selects the matching endpoint-number FIFO for active IN endpoints 1–4.
The allocation sizes/offsets, OUT endpoints, and notification special case are
unchanged. No SDK files are modified. The correction applies to native TinyUSB
builds, including both streaming profiles. V1 and V2 streaming remain at 40 MHz.

A host regression compiles the production wrapper against simulated SDK
registers using the actual descriptor order. It checks FIFO selection, disjoint
unchanged allocations, unrelated control bits, OUT/notification handling, and
failed opens. Removing the correction makes the regression fail. Firmware tests,
all nine profiles and 87 QEQ tests passed; the macOS app build also passed.
After flashing V1, the physical register snapshot showed endpoint 2 selecting
FIFO 2 with exactly 47 free words. The extended diagnostics include endpoint
control/size/interrupt/FIFO space and global interrupt masks for future failures.

Pinned driver source:
[Espressif dcd_esp32sx.c](https://github.com/espressif/esp32-arduino-lib-builder/blob/3eb9cb06afb534d37f47e98bca9f45e99126f81a/components/arduino_tinyusb/src/dcd_esp32sx.c).
Physical stress validation follows below; V2 still requires a physical run.


The FIFO-only physical trial passed three 624-frame replays and 24 two-frame
reopenings (1,920 ACKs), including idle expiry. However CDC stopped after 49 samples
/ 4.805 seconds of board uptime while MIDI continued. This is not a passing
composite-USB stability check. Inspection of the actual Espressif driver also shows
that its ISR posts completion before finishing access to endpoint transfer state;
a task on the other core can replace that state immediately. The next trial
combines the FIFO mapping correction with a cross-core critical section around
USB interrupt handling and DCD transfer setup. The guard now applies to all native
TinyUSB profiles and specifically documents this driver path; neither the guard
alone nor the FIFO correction alone is claimed as a complete solution.


The combined correction passed the simultaneous stress run: three 624-frame
replays plus 24 two-frame client reopenings, for **1,920 validated frame ACKs**,
with idle expirations between sessions. Replay median was 33.98 ms and p95
45.83 ms at 40 MHz while CDC and MIDI were active; maximum reported input gap was
3.715 ms. CDC delivered **1,200 consecutive samples across 120 seconds**, zero
sequence gaps, unchanged 303,496-byte free heap, and zero MIDI overflows. This
contrasts with the FIFO-only run's CDC stall after 4.805 seconds.

Normal QEQ then connected on the first attempt, with no protocol error during
handoff. The user exercised the dial, menu, buttons and slider and confirmed that
everything kept responding. An independent live MIDI capture spanning at least
80.35 seconds recorded 1,172 messages (including 292 rotary messages) with a
single unchanged boot identity. The combined fixes, rather than either isolated
trial, are the current V1 deployment. Firmware tests/all nine builds and the
87-test QEQ suite/macOS build passed for this implementation. Physical validation
covers V1; V2 uses the same corrected driver but still needs its own device run.


### Metal UI compression and DMA — 2026-11-09

The app and benchmark now use only `MetalRoundDisplayRenderer`. The legacy CPU
renderers, older seven-layer Metal renderer and comparison executable were removed.
A fresh 600-frame workload exercises spectrum, menus, actions, slots, volume,
slider and playback transitions; 462 changed/forced frames reach the wire. The
benchmark preserves the renderer's full-refresh boundaries. Old UI replay results
above are historical and are not evidence for the current renderer.

The host uses LZ4 HC level 9 with reusable state reset for each independent tile,
a compress-bound-sized scratch buffer, and early rejection of unchanged tiles.
The ESP keeps the safe decoder, compiled at `-O3`, and its existing ROM CRC. SPI DMA
uses two owned 2 KiB internal buffers, allowing the next tile's CPU work to overlap
pixel transmission. COMMIT drains DMA before a successful ACK. Protocol, GPIOs,
40 MHz clock, USB FIFO correction and cross-core synchronization are unchanged.
There is no custom SIMD decoder or LZ4 hardware engine in this implementation.

Matched single-pass replay on the attached V2, before → after:

| Current Metal workload | Before | After |
| --- | ---: | ---: |
| Wire bytes | 5,943,424 | 4,579,281 (23% less) |
| All-frame transfer median | 29.84 ms | 24.33 ms (18% less) |
| All-frame transfer p95 | 73.70 ms | 52.31 ms (29% less) |
| Spectrum transfer median / p95 | 32.44 / 38.93 ms | 26.31 / 30.20 ms |
| ESP decode median | 4.24 ms | 2.53 ms |

This is **not a locked 30 fps result**. With real QEQ MIDI feedback active, six
replays plus six reopenings passed **2,784 validated ACKs** over 120 seconds.
Spectrum transfer median/p95 were 27.95/35.52 ms; including host re-encoding and
round-trip verification, 29.06/37.63 ms. Rendering is additional. Heavy transitions
remain slower: the single-pass all-frame p95 was 52.31 ms, before host preparation.
The sustained run delivered 1,194 consecutive CDC samples, no sequence gaps or
MIDI overflows, and continuing MIDI traffic in both directions. Maximum recorded
input-poll gap was 7.145 ms; no physical gesture latency was measured. Heap ranged
293,300–295,364 bytes, including the temporary disconnected-screen canvas.

The LCD setting is **40 MHz SPI**, not a measured 40 Hz panel refresh. A full
240×240 RGB565 transfer alone takes at least 23.04 ms at that clock; partial updates
can be faster. ACK measures completed SPI output, not visible panel scanout. DMA
`lcd_us` counts CPU setup/wait including the final drain; it excludes transmission
time overlapped with other work and must not be read as total physical bus time.

Validation: 100 Swift tests, script tests, release macOS build, app-owned screenshot
refresh, seven firmware C++ test executables, 25 Python tests and all nine firmware
profiles. The user confirmed correct DMA output before the current-UI replay; the
later automated tests do not establish new visual acceptance or optical timing.
The optimized `stream-v2` firmware is installed and normal QEQ was restored.

Detailed measurements: [current Metal benchmark](benchmarks/metal-display-streaming-2026-11-09.json).


### Exact dirty rectangles and live timing — 2026-11-09

Following the HC9/DMA change, the host now bounds the changed pixels inside each
32×32 cell and sends only that rectangle. The framebuffer image is unchanged;
CRC checks cover the exact decoded rectangle, and only an accepted ACK advances
the host's baseline. Page transitions no longer force a redundant full repaint
when they settle. Initial connections and reconnects still send every complete
cell. Firmware retains bounded tile scratch memory, without a full framebuffer.

This is an opt-in wire-v1 extension: HELLO flags=1 requests capability bit 2
(mask 7); old hosts send flags=0 and receive the original mask 3 and tile rules.
The new host retries a rejected extension handshake with flags=0 and a fresh
nonce for older firmware. Physical fallback was exercised on the preceding V2
firmware. Tests cover stale expiry/rejection replies, nonce wrap, lost ACKs,
partial edge cells, duplicate cells, invalid bounds, CRC failure, single-pixel
DMA writes and exact 240×240 Metal transition reconstruction.

Unlike the earlier offline replay figures, the new live benchmark measures
**GPU rendering + planning/compression + native USB transfer + SPI-complete ACK**.
Four alternating baseline/candidate runs used the same firmware and identical
600-frame source workload, paced toward 30 Hz, with real QEQ MIDI feedback and
continuous CDC capture. Baseline preserves the preceding forced-refresh boundaries
and full-cell transfers; candidate uses dirty rectangles and acknowledged deltas.

| Live metric, two runs per mode | Previous behavior | Dirty rectangles |
| --- | ---: | ---: |
| Changed frames / validated ACKs | 924 | 922 |
| Wire bytes | 9,158,562 | 7,764,146 (15.2% less) |
| Render-to-ACK median | 28.83 ms | 26.03 ms |
| Render-to-ACK p95 | 67.29 ms | 52.38 ms (22.2% less) |
| Changed frames over 33.33 ms | 160 | 90 (43.8% fewer) |
| Steady spectrum p95 | 33.41 ms | 30.55 ms |
| Steady spectrum budget misses | 26 / 358 | 0 / 358 |

Steady spectrum means source frames 1–179, excluding the cold initial frame and
later navigation back to Home. Its worst candidate frame was 31.31 ms. This
segment met the 30 fps processing budget in the test; **navigation transitions
still do not sustain 30 fps**. All-frame p95 remains 52.38 ms and the worst frame
82.85 ms. These are processing times, not measured optical FPS, physical gesture
latency, or the production worker's latest-state coalescing under load.

The 120.09-second stress run passed all **1,846 ACKs**, four session openings with
idle expiry, 1,194 consecutive CDC samples, zero sequence gaps and zero MIDI
overflows. MIDI received/sent counters advanced by 12,240/4,920. Heap ranged
293,300–295,364 bytes; maximum cumulative input-poll gap was 9.091 ms in both modes.
Higher HC levels saved less than 1% in sampled tiles at extra CPU cost; byte-plane
shuffling increased traffic. Neither experiment was adopted. HC9, safe decoding,
ROM CRC, SPI DMA, 40 MHz clock and GPIO mappings remain as before.

Validation: 105 Swift tests, full app checks/release build and app-owned screenshots;
firmware regressions and all nine build profiles. Automated pixel reconstruction
and ACK checks passed; physical visual acceptance of the new rectangle path awaits
an in-person check. Normal QEQ is restored after benchmarking.

Detailed measurements: [live dirty-rectangle benchmark](benchmarks/metal-dirty-rectangles-2026-11-09.json).

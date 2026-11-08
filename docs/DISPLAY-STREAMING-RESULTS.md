# USB display streaming prototype — 2026-11-08

Implemented on disposable `codex/usb-display-streaming` branches in both repos.
The original working integration is checkpointed separately: QEQ `a0d6df1`,
firmware `42992ff`. No remote push or release.

**Result:** the current ESP32-S3 is useful for this mostly static control screen
with small volume/status updates. These measurements do not justify a board
replacement for that workload. A High-Speed USB board may help larger or highly
animated screens, but it must also have a faster panel path: this LCD takes roughly
102 ms for a full refresh at the present conservative 10 MHz SPI setting.

## Measured on the connected board

240×240 round GC9A01, RGB565 LE, 32×32 tiles, native Full-Speed USB, MIDI and CDC
present throughout. Mac renders with the same AppKit controller renderer used by
live QEQ; 75 fixture screens cover Music/Safari/Spotify, volume sweeps, mute, bypass,
unavailable state, and system-volume changes. This is not a generic color-fill
benchmark or a capture of the desktop mixer window.

| Metric | Raw tiles | LZ4 | LZ4 HC level 9 |
| --- | ---: | ---: | ---: |
| Encoded / changed raw pixel bytes | 100% | 19.8% | 16.6% |
| Total USB protocol bytes, 75 screens | 1,315,158 | 287,121 | 245,375 |
| Mac tile preparation, median | 0.029 ms | 0.054 ms | 0.314 ms |
| Send → LCD-complete ACK, median | 34.01 ms | 21.84 ms | 21.44 ms |
| Send → LCD-complete ACK, p95 | 48.51 ms | 30.87 ms | 30.89 ms |
| First full refresh, send → ACK | 212.58 ms | 146.02 ms | 143.68 ms |
| ESP raw copy / LZ4 decode, median per frame | 0.053 ms | 1.069 ms | 0.905 ms |
| ESP decoded-pixel CRC, median per frame | 3.628 ms | 3.600 ms | 3.605 ms |
| LCD writes, median per frame | 14.72 ms | 14.56 ms | 14.52 ms |

Mac rendering was 2.45 ms median, 2.71 ms p95 in the optimized fixture renderer;
the first cold render was 35.63 ms. Encoded payload ratios exclude tile/protocol
headers. Changed raw bytes total 1,282,560, versus 8,640,000 bytes if all 75 screens
had been transmitted in full. Ratios and timing depend on the rendered content;
compression has no guaranteed ratio or frame rate. Incompressible tiles use raw.

The bounded USB-only test (no LZ4 or LCD writes) delivered **545,965 bytes/s** end to
end, about 4.37 Mbit/s of application traffic. It includes framing, checksums,
scheduling, and replies; it is not the 12 Mbit/s physical signaling rate. During
actual graphics, USB write time includes LCD backpressure and cannot be read as
isolated bus throughput.

## Live interaction and reconnect

871 changed frames from real knob/slider interaction using LZ4:

- Mac render-start → LCD-complete ACK: **30.95 ms median, 47.29 ms p95**.
- Send → ACK: 17.63 ms median, 22.76 ms p95.
- Largest firmware input-poll gap reported during the run: **3.002 ms**.
- Post-reconnect diagnostics: MIDI host connected, queue empty, zero overflows,
  sent/received counters continuing to advance. User confirmed correct graphics
  and responsive controls, including continued use after reconnect.

This is a software end-to-end measurement from rendering, not physical gesture
latency. The 16 ms QEQ feedback coalescer and preceding input/MIDI time are outside
that start point. ACK marks completion of synchronous SPI writes, not panel scanout
or measured light output. Full reconnect refreshes are excluded from steady
interaction latency; the first cached raster can predate reconnection.

An early build exposed two real integration problems: changing composite endpoint
ordering and calling vendor/MIDI endpoint APIs from different tasks. The experiment
now appends the display interface after MIDI, uses a distinct experimental USB
identity, and keeps vendor and MIDI FIFO operations on TinyUSB's own task. A bounded
buffer hands pixels to the LCD worker. Initial reconnect testing found a MIDI stall;
the corrected build passed continued user interaction after reconnect. This is a
bench result, not yet a long-duration reliability qualification.

## Decision and remaining work

Keep **plain LZ4 as the default**. HC reduced total wire bytes by another 14.5%, but
saved only about 0.4 ms at the median here; it remains a selectable host option.
For this screen, optimize the panel path and CRC implementation before changing
USB hardware. A faster SPI setting needs validation on the actual panel/wiring;
this experiment has not changed it. Larger panels, full-screen animation, and four
simultaneous app channels need their own rendered-scene tests. A future High-Speed
board should be evaluated with a suitable SPI/parallel/RGB panel path too.

The experiment deliberately remains a prototype:

- QEQ opt-in renderer + separate Python/libusb worker, linked through one atomic
  latest-frame file. Shipping integration should move transport/render work off the
  app's main actor and supervise it within QEQ.
- One frame in flight, acknowledged baselines, raw fallback, session negotiation,
  complete reconnect refresh, three-second disconnected screen, bounded buffers.
- Tiles reach the panel before COMMIT. It is not tear-free or atomically presented;
  protocol failure invalidates the baseline and requires a full refresh.
- Capability schema covers resolution, pixel format, orientation, and shape; only
  RGB565 and the current GC9A01 driver were physically tested.
- Four-control hardware test profiles remain available; four-channel host bindings
  are still separate from this display experiment.

Validation: all seven firmware environments built, four C++ test programs and 17
Python tests passed, QEQ's 74 Swift tests passed, and native debug/release app builds
passed. Tests cover exact codec round trips, malformed input, fragmentation, bounds,
frame/ACK sequencing, stale baselines, partial frames, timeout and recovery, and
negotiated raster geometry.

See [machine-readable results](benchmarks/display-streaming-2026-11-08.json).
Run instructions, detailed protocol, and rollback steps live in
`vol-firmware/DISPLAY-STREAMING.md`. The only transport is the board's native USB;
the UART/COM connector is not a bandwidth alternative. ESP32-S3's Full-Speed limit
is documented by [Espressif](https://docs.espressif.com/projects/esp-iot-solution/en/release-v2.0/usb/usb_overview/usb_otg.html).

# V2 peripheral baseline — firmware 0.3.0

The `stream-v2` image exposes four slider/button pairs, four independently driven
RGB LEDs, the rotary encoder and push switch, a 240 × 240 round pixel display,
and a USB HID Consumer Control interface. QEQ owns assignments, pickup, screens,
animations and playback actions. Hardware V1 remains supported by `stream` with
one pair; never flash either profile to the other wiring revision.

## QEQ operation

When hardware is connected, click the slider icon beside an app’s volume control
and choose a numbered slot. Assigned apps show their slot number on that button. Assignments
are saved by controller serial and physical position, from left to right. One app
has one pair per controller; assigning it elsewhere clears its previous pair.
Assigned apps stay in the mixer list when idle, after quitting or restarting,
and across QEQ restarts—even when the controller is disconnected. Saved display
metadata retains their name/icon; live audio clients are never cached for routing.
Click the slot number and choose **Unassign** to release the app’s bindings.
Explicit reassignment replaces only the selected slot and the same app’s old slot.
The chooser stays in the main panel while app rows and audio status update.
Unassigned sliders do not change audio. Each pair has independent pickup and mute
button state. Existing first-slider assignments migrate automatically. The round
UI identifies the correct slider and reuses an already-open matching app view.

The gear beside each slot opens calibration with live raw readings, endpoint capture,
reverse direction, motion threshold, stable-sample count and smoothing. Changes
are volatile on the board and saved by QEQ only after matching readback. QEQ
reapplies saved calibration after each device session. Restore defaults followed
by Apply resets the calibration. A timeout is not success. Calibration re-arms
pickup and establishes a new baseline instead of treating it as slider movement.
Raw readings remain independent of calibration.

Playback sends generic Consumer-page usages: previous 0xB6, play/pause 0xCD, next
0xB5. macOS chooses the media-key recipient. No per-player Apple Events,
Automation permission or Accessibility permission is used by this path. A MIDI
acknowledgment means the firmware accepted a request, not that a particular
player acted on it. Requests expire after 250 ms in the board queue, are bounded
to four queued pulses, and release after at least 25 ms. Duplicate last tokens
are suppressed. Disconnect clears pending HID work; commands are never retried
by QEQ automatically.

## App controls on the round display

Selecting an app with the dial opens a carousel: **Boost, Mute, Volume, Slot,
Back**. The app icon stays prominent above the smaller action and slot carousels,
with its live volume ring and percentage visible throughout. Boost and Mute
toggle immediately and show On/Off. Volume opens a gain
view with one percentage-point step per detent, bounded to 100% or 200% when
Boost is enabled. Clicking returns to the app actions.

Volume remains visible but disabled for an app assigned to any hardware slot,
including saved assignments on disconnected controllers. It shows **Use slider
N**. Both entry and every volume adjustment recheck ownership; assigning the app
from the Mac while its volume view is open returns it to the action carousel.

Slot opens a second carousel of the current controller's numbered slots with
current owners, plus Unassign and Back. Selecting a slot uses the same persistent
assignment/pickup path as the Mac UI. Unassign releases the app's bindings, as on
the Mac. All pages retain the five-second idle return; slider overlays dismiss
to their underlying page. Page changes zoom/fade, and both carousels scroll
horizontally with icons clipped by the round panel. This requires only a QEQ app
update on the V2 firmware baseline.

## Peripheral contract

All messages retain SysEx prefix `F0 7D 51 45 51 02`; bytes after the prefix are
7-bit data, with final `F7`. Maximum length is 64 bytes. Board-directed messages
include the current four-byte boot nonce immediately after the message type.
They require a live host feedback heartbeat. Firmware announces identity and
capabilities once per second; old 0.2 identity fixtures remain supported.

| Type | Payload after boot nonce | Purpose |
| --- | --- | --- |
| 4 | token[4], usage[2] | Generic HID Consumer pulse, usage 1…1023 |
| 5 | schema=1, feature bits, pair count, LED count, encoder ID, encoder button ID, pairs[4 bytes each] | Capability announcement |
| 6 | LED ID, red, green, blue | Independent LED output, channels 0…127 |
| 7 | token[4], pair ID, operation, calibration[8] | Read (0) or apply (1) calibration |
| 8 | token[4], pair ID, status=0, calibration[8], raw[2] | Calibration readback |
| 9 | token[4], request type=4, status | Media acknowledgment: 0 accepted, 1 busy |

Multi-byte integers are little-endian 7-bit groups; tokens are 28-bit. Capability
feature bits are 1 independent LEDs, 2 calibration, 4 Consumer HID, 8 display.
Unknown feature bits are ignored. Unknown schemas, malformed descriptors,
duplicate control IDs/addresses and stale boot nonces are rejected. Identity
contains variable-length `(logical ID, kind, MIDI CC)` descriptors. Pair records
are `(physical pair ID, slider logical ID, button logical ID, LED ID)`; zero LED
means absent. Encoder IDs come from capabilities, not GPIO assumptions.

Calibration bytes are `minimum[2], maximum[2], reversed, threshold, confirmations,
smoothing`. Bounds: minimum 0…2047, maximum ≤4095, span ≥1024, reversed 0/1,
threshold 1…8 MIDI ticks, confirmations 1…10, smoothing 1…4 (EMA divisor 2^value).
The five-sample median and 5 ms scan period remain electrical driver behavior.
QEQ retains its ≥1% UI movement gate independently of device filtering.

LED IDs 1…4 match physical pairs. Channels 0…5 use LEDC and 6…11 use MCPWM's six
outputs, all at 5 kHz, supporting simultaneous independent colors without an
interrupt-driven software PWM loop. Host lease expiry turns every LED off.

USB keeps CDC, MIDI and vendor display endpoints in their existing order and adds
HID IN endpoint 3. Streaming serial suffix changes from `-D1` to `-D2` to avoid
cached descriptors; QEQ pairs either with the stable MIDI serial. The existing
FIFO selector and cross-core USB driver fixes remain in place.

Firmware updates are still needed for electrical/driver bugs, new hardware or
new transport capabilities. Changes within this contract belong in QEQ. GPIOs,
USB descriptors and display transfer timing are deliberately not arbitrary
runtime settings. QEQ must be running for the full UI and application behavior.

## Validation

Run firmware `./run.sh test` and `./run.sh build-all`; run QEQ
`./QEQ/scripts/check.sh`. Flash V2 explicitly with `./run.sh upload PORT stream-v2`.
Host tests cover capabilities, malformed/stale packets, calibration bounds,
independent pickup, HID pulses/releases, and USB FIFO allocation with the added
endpoint. Physical pin pairing, optical LED colors, media-key routing and USB
stability require a connected-board acceptance pass; software checks alone do
not establish those results.

## V2 bench evidence — 2026-11-09

The V2 board `8C5B1427843C` was flashed with `stream-v2` and enumerated as
`8C5B1427843C-D2`. Discovery reported firmware 0.3.0, ten controls, four physical
pairs, four LEDs and all four capability flags. Each slider passed live
calibration read → temporary write → verified readback → restore.

The simultaneous display/MIDI/LED/CDC run passed 624 frame acknowledgments;
median transfer 35.80 ms, p95 48.48 ms, maximum recorded input gap 4.463 ms.
CDC delivered 1,200 consecutive samples over 120 seconds with no sequence gaps,
no MIDI overflows, and constant 304,252-byte free heap. Physical capture recorded
movement from every slider and one press/release from each paired button. Sliders
1–3 reached both raw rails; slider 4 reached raw 309…4095 in this capture, so its
bottom endpoint still needs deliberate capture/confirmation rather than assuming
309 is its true minimum.

The user confirmed physical LED 1 by a white-only identification pattern. Color
cycling established that all V2 modules have reversed red/blue wiring relative to
the original labels. The profile now uses R/G/B groups **14/13/12, 10/9/3,
18/17/16, 7/6/5**. LED 1 did not visibly produce green; the final firmware read back
full green duty on all four PWM channels (0,4095,0 for each RGB group). This
supports checking LED 1's GPIO13 wire/module, but is not an electrical or optical
proof of the fault. That physical issue remains open.

The corrected final firmware accepted two non-playback HID test usages and
reported two presses and two releases. The host enumerated Consumer-page HID;
all LEDs went off after the heartbeat expired. Normal QEQ connected to the
240×240 display. End-user playback routing and V2 rotary behavior are separate
physical acceptance checks, not established by those transport counters.

Validation: six C++ executables, 25 Python firmware tests, all nine firmware
profiles, and QEQ's full check including 96 Swift tests and the release app build.
Local raw captures are development artifacts, not committed test fixtures.

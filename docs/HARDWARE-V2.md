# Hardware V2 development baseline

> Current production baseline: [V2 peripheral firmware 0.3.0](HARDWARE-PERIPHERAL-BASELINE.md).
> All four pairs and LEDs are exposed, with capability discovery, runtime slider
> calibration and USB media keys. Earlier single-app notes below are historical.

Hardware V2 is the default board for future work. Both the QEQ app and the
separate `vol-firmware` repository use `hardware-dev`; feature branches should
start there. The app's existing MIDI/display-streaming implementations remain
available for the original prototype. The `stream-v2` image exposes all four pairs,
independent RGB LEDs, rotary, display and Consumer HID media keys with capability
discovery and runtime calibration. Do not use prototype firmware on V2.

## Physical wiring

Positions are left to right. Firmware `include/board_profiles.h` and `WIRING.md`
are the source of truth; this table mirrors the current V2 profile.

| Position | Slider GPIO | Button GPIO | LED R / G / B GPIOs |
| --- | --- | --- | --- |
| 1 | 11 (ADC2) | 35 | 14 / 13 / 12 |
| 2 | 8 (ADC1) | 36 | 10 / 9 / 3 |
| 3 | 2 (ADC1) | 15 | 18 / 17 / 16 |
| 4 | 1 (ADC1) | 4 | 7 / 6 / 5 |

Rotary A/B/push: **21 / 47 / 48**. Display reset/CS/DC/MOSI/clock:
**38 / 42 / 41 / 40 / 39**. Rotary GPIO21 was explicitly corrected from GPIO12;
GPIO12 belongs to an LED. Buttons and rotary contacts use pull-ups to GND.
Sliders use 3.3 V, common-cathode RGB modules have built-in resistors, and the
240×240 GC9A01 uses SPI without MISO. Both streaming profiles run at 40 MHz;
the standalone validation images retain their 10 MHz bring-up setting.

The confirmed ESP32-S3 has 8 MB quad SPI flash and 2 MB quad SPI PSRAM. Firmware
uses a conservative 4 MB flash layout with PSRAM disabled. GPIO35/36 are allowed
only for buttons on this module; GPIO3 is allowed only for an LED channel.
Preserve GPIO conflict checks and do not generalize these exceptions to other
ESP32-S3 memory variants.

## Build and flash

From the firmware checkout:

```sh
./run.sh test
./run.sh build                  # V2 test-four-manual
./run.sh ports
./run.sh upload PORT            # V2 test-four-manual
./run.sh ports                  # Runtime port can change after ROM flashing
./run.sh hardware-check PORT    # Live serial diagnostics
```

`./run.sh build-all` compiles every firmware environment. Explicit `test-four`
provides automatic LED identification and the guided checker; `test-four-manual`
is the default interactive image. Each button toggles its paired white LED;
each slider sets that LED's brightness. All LEDs start off. Rotary count, button
state/press count, and errors appear at the top of the test display. Both images
are serial-only and cannot change Mac audio.

Use the native USB connector. V2 uses software TinyUSB CDC because hardware
Serial/JTAG CDC stalled during the four-channel bench run. The inspector sets
the appropriate handshake lines. Enter ROM mode with a 1200-baud CDC touch or
BOOT/RESET, enumerate again, then upload. Keep one serial reader open at a time.
No flashing is part of the branch merge itself.

## Evidence and remaining physical checks

On 2026-11-08, one continuous 128.6-second capture contained 1,287 sequential
samples with no gaps. The user swept sliders top-to-bottom and pressed buttons
left-to-right. Every slider reached both rails and midpoint; top reads high.
Each button registered one press and release. Slider order is 11/8/2/1 and button
order is 35/36/15/4.

The first manual image worked for brightness/toggles, but controls 1/2/3/4 drove
physical LEDs 2/3/4/1. The LED groups were corrected to the table above, superseding
the initial automatic-cycle observation. The corrected image has been flashed;
explicit confirmation that the offset is resolved is still pending.

The user confirmed display output but reported physical damage cutting off the
bottom of the LCD. A replacement is needed. Rotary diagnostics were moved into
the upper 90 pixels and flashed. Telemetry showed raw encoder movement without
invalid transitions, but the user has not yet confirmed rotary direction, detent
resolution, or push-button operation. Keep those marked unverified. Stationary
midpoint noise, repeated/long-hold button validation, and individual RGB color
order also remain pending.

Raw captures stay ignored in the firmware repository's `reports/`. The summary
and pin map are tracked so future work does not depend on local report files.

## QEQ integration

Build `stream-v2` and flash with `./run.sh upload PORT stream-v2`. Click the hardware icon beside an app’s volume control and choose Slot 1…4.
Assigned apps show the slot number and stay in the list while idle or closed,
including after app/QEQ restarts. Use **Unassign** in the slot chooser to release
the binding; a closed app never gives up its slot automatically. Each pair has independent
pickup, volume and mute state; its RGB LED follows the assigned app's accent.
The gear beside a slot opens endpoint and filtering configuration with
live raw readings. QEQ saves verified settings per serial/pair and restores them
on reconnect. Unassigned pairs do not change audio. At rest the rotary
adjusts system volume while the display shows the same horizontal spectrum
envelope and colored per-app traces as QEQ, with the fill continuing to the bottom
of the circular panel. The volume ring, speaker icon, and percentage appear
only during adjustment. The ring shrinks inward from beyond the circular edge,
then expands outward and fades two seconds after the last change. Press
the knob to open the menu with Playback selected. Home is immediately to its left,
and apps follow on the right. The menu is a horizontal icon carousel: the selected icon is large,
neighboring icons clip at the circular edge, and the knob animates between them.
All screen changes use the same zoom-and-fade effect: opening the menu, Playback,
app details, or a slider overlay moves inward; returning to a parent screen or
home reverses the effect. Carousel scrolling remains horizontal. The selected
carousel indicator is circular.
The visualizer has no title or menu prompt. Five seconds after the last accepted
hardware interaction, every screen returns to the home visualizer. Audio updates,
host feedback, and rejected slider noise do not restart this timer.
Playback uses a neutral play/pause icon and sends generic USB HID Consumer
previous, play/pause and next keys. macOS chooses the recipient. This replaces
the former player-specific Apple Events implementation and needs no per-player
Automation permission. Playback follows the normal five-second idle return.

Moving any assigned slider shows its assigned app icon, volume, and pickup status,
then returns to the previous screen after three seconds without accepted movement.
The underlying page and menu selection stay intact, so an adjustment from the
visualizer returns directly to the visualizer.
If that app is already open from the carousel, slider changes update the existing
view in place; the five-second idle return still applies. Turning the dial while
viewing the slider-bound app shows **Use slider N** instead of changing volume.
The firmware takes a five-sample median at 5 ms intervals, smooths it, and requires
three consecutive samples beyond the movement threshold before reporting a change.
Changes below 1% of slider travel are ignored relative to the last accepted value;
the 7-bit MIDI range makes this two ticks (about 1.57%). Both ends of travel are
explicit exceptions, so the final one-tick movement can reach exactly 0% or 100%.
Ignored chatter does not alter volume or extend the overlay timeout. Routine
navigation instructions are omitted; Playback uses an icon to return. Click an app’s hardware icon or slot number to select the pair.
Pickup preserves the last known physical slider position when an app becomes
available or the target changes. Repeated stationary snapshots are suppressed
without losing the starting point for the first deliberate movement. A target
at a different saved volume still uses pickup to avoid an unexpected volume jump.
The on-device app list opens **Boost / Mute / Volume / Slot / Back**. Slot opens
a numbered assignment carousel. Dial volume is available only for unmapped apps;
mapped apps show **Use slider N**. Clicking the volume view returns to actions. The complete `v2-peripheral` profile
uses model 2 and ten control descriptors, plus a separate capability description
of physical groups and outputs. Streaming USB serials end in `-D2`; QEQ also
accepts older `-D1` displays. The explicit `stream` firmware remains V1 only.

## Earlier connection investigation (historical)

The `stream-v2` image has been flashed and its QEQ MIDI handshake and feedback
verified. Connection stability remains unresolved: the user reported intermittent
disconnections, including one after slider movement. An initial inspection found
the board absent from USB. After changing the USB connection, a 242.905-second
capture contained 2,430 consecutive samples with no feedback losses after startup,
queue buildup, overflows, or heap decline.

Following a later reported failure, USB/MIDI remained online and firmware uptime
continued past seven minutes with active feedback at 25% volume. This does not
establish a full-board crash; a display-session failure is still a possibility.
See firmware `WIRING.md` for the measurements. Do not treat the short successful
run as proof of long-term stability. Raw bench captures remain local and ignored.

## V1 comparison deployment — 2026-11-09

At the user's request, the current integration was deployed to the original V1
board using firmware environment `stream` and the prototype pin map. The current
host recognizes both `QEQ Test Board Display` (V1) and `QEQ Test Board V2 Display`
as round displays, so both receive the carousel, horizontal spectrum, transient
system-volume overlay, and slider noise threshold. The initial V1 stability
comparison used a 10 MHz LCD clock, versus V2 at 40 MHz. Later on 2026-11-09,
the user confirmed identical display hardware and requested matching rates:
both streaming profiles now use 40 MHz. V2 remains the default unless V1 is
explicitly requested.

V1 was observed absent from USB before the flash/reset attempt, around stopping
QEQ for deployment. Reconnecting restored it and the flash succeeded. The failure
cause is still unknown; this observation does not establish a V2-only fault.

The 60-second startup capture produced only 86 sequential samples spanning 8.501
seconds (uptime 41.715–50.216 s), then no further telemetry. macOS still listed V1
USB and MIDI online afterward. A four-second reopened CDC capture produced 41
samples with active host feedback, zero queued MIDI packets/overflows, and stable
303,816-byte free heap, but uptime was now 24.325–28.326 s. The lower uptime is
consistent with a restart; whether that was an unreported manual reconnect or an
automatic reset is not established. This is not a successful 60-second stability
check. The current dev app and V1 firmware remain deployed for user control tests.

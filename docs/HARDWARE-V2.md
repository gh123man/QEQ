# Hardware V2 development baseline

Hardware V2 is the default board for future work. Both the QEQ app and the
separate `vol-firmware` repository use `hardware-dev`; feature branches should
start there. The app's existing MIDI/display-streaming implementations remain
available for the original prototype. The `stream-v2` image now uses those existing
single-app controls and native graphics streaming on V2 pins. It does not provide
four-app bindings. Do not use prototype firmware on V2.

## Physical wiring

Positions are left to right. Firmware `include/board_profiles.h` and `WIRING.md`
are the source of truth; this table mirrors the current V2 profile.

| Position | Slider GPIO | Button GPIO | LED R / G / B GPIOs |
| --- | --- | --- | --- |
| 1 | 11 (ADC2) | 35 | 12 / 13 / 14 |
| 2 | 8 (ADC1) | 36 | 3 / 9 / 10 |
| 3 | 2 (ADC1) | 15 | 16 / 17 / 18 |
| 4 | 1 (ADC1) | 4 | 5 / 6 / 7 |

Rotary A/B/push: **21 / 47 / 48**. Display reset/CS/DC/MOSI/clock:
**38 / 42 / 41 / 40 / 39**. Rotary GPIO21 was explicitly corrected from GPIO12;
GPIO12 belongs to an LED. Buttons and rotary contacts use pull-ups to GND.
Sliders use 3.3 V, common-cathode RGB modules have built-in resistors, and the
240×240 GC9A01 uses SPI at 10 MHz without MISO.

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

## Single-app QEQ integration

The user selected the existing single-app behavior for V2. From the firmware repo,
run `./run.sh build stream-v2` and `./run.sh upload PORT stream-v2`. The leftmost
slider (GPIO11) controls selected-app volume with pickup, its button (GPIO35)
toggles mute, and LED1 (GPIO12/13/14) shows the app accent. Rotary GPIO21/47 adjusts
system output volume; its GPIO48 push toggles global bypass. The existing native
USB display interface streams QEQ graphics to the V2 SPI pin map. Right-click an
app and choose **Use hardware controls** to select the target. Other slider/button
pairs are inactive and their LEDs remain off.

The firmware `v2-single-app` compatibility profile advertises the existing model-1
logical handshake with one slider/button pair while retaining V2 wiring policy.
No QEQ host protocol change is required. USB product is **QEQ Test Board V2 Display**;
the display serial retains the host's `-D1` convention. This is distinct from the
full model-2 four-slot profile, which remains `testOnly` and is used by validation
images. Future four-app integration still requires per-slot bindings and feedback.
The explicit legacy `stream` firmware continues to use the prototype pin map.

## Connection validation status

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

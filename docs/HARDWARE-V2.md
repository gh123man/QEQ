# Hardware V2 development baseline

Hardware V2 is the default board for future work. Both the QEQ app and the
separate `vol-firmware` repository use `hardware-dev`; feature branches should
start there. The app's existing MIDI/display-streaming implementations remain
available for the original prototype. They do not yet provide V2 four-app
bindings or V2 graphics streaming. Do not use prototype firmware on V2.

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

## Host integration boundary

V2 profile model 2 has four slider/button pairs. It remains `testOnly`, so a
`midi-four` build does not activate its GPIOs/MIDI. QEQ's existing profile is for
the original model-1 controller. Future V2 integration must explicitly add
per-slot app bindings, feedback, and the intended rotary behavior before claiming
normal-operation support. Native display-streaming code is preserved on
`hardware-dev`, but the existing `stream` firmware environment is explicitly for
the original prototype's pin map.

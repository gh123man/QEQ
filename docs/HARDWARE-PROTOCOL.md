# QEQ prototype MIDI protocol v2

Development protocol for the current ESP32-S3 test board. Uses USB MIDI 1.0,
cable 0, channel 16 (`BF` Control Change status). IDs are logical controls; GPIOs
remain firmware details. The QEQ profile is currently fixed to these four controls:

| ID | Kind | CC | Encoding | QEQ action |
| --- | --- | --- | --- | --- |
| 1 | Absolute (0) | 16 | 0–127 | Selected-app volume |
| 2 | Relative (1) | 17 | 1–63 positive; 65–127 negative (`value - 128`); 0/64 ignored | System volume |
| 3 | Button (2) | 18 | 0 released / 127 pressed | Toggle global bypass |
| 4 | Button (2) | 19 | 0 released / 127 pressed | Toggle selected-app mute |

Button actions occur only on released→pressed edges. Initial held states and
duplicates do nothing. Four encoder quadrature edges produce one step; clockwise
is positive on the measured wiring. Analog values use filtering and hysteresis;
QEQ waits for movement across the current app volume before applying changes.

Every SysEx starts `F0 7D 51 45 51 02`, then command and payload, and ends `F7`.
All interior bytes are seven-bit. `7D` is the noncommercial development ID, not a
production manufacturer allocation. Maximum frame size is 64 bytes. Unknown
versions/profiles are not automatically bound. USB identity still uses the
framework's development VID/PID; production identifiers remain future work.

## Identity: command 02, exactly 41 bytes including framing

Payload: model (1), firmware major/minor/patch (0,2,0), four-byte boot nonce,
12 uppercase ASCII hex serial characters, control count (4), then four triples
`logical ID, kind, CC` matching the table. Firmware announces once per second,
followed by current absolute/button baselines so new hosts can synchronize.
The nonce changes on reboot. QEQ pairs source/destination within one CoreMIDI
entity, verifies the identity, and maintains separate device sessions.

## Feedback: command 03, 20–44 bytes including framing

Payload: boot nonce (4), flags, normalized app slider position, app volume percent
low/high seven-bit bytes (0–200), RGB (three 0–127 components), system volume
percent (0–100; 127 means unavailable), then 0–24 printable ASCII label bytes.
Unicode labels use `?` for unsupported characters. Flag bits: 0 app available,
1 app muted, 2 global QEQ enabled, 3 pickup pending. Other bits are rejected.
RGB is sampled from the same cached app accent as the QEQ UI, converted to sRGB.
Firmware scales it to a maximum PWM duty of 700/4095 while preserving proportions.

QEQ coalesces changed feedback into 16 ms updates after controller gestures, UI
edits, or target changes; identical values are suppressed. A 500 ms heartbeat
keeps the connection alive and refreshes externally changed system volume.
Firmware marks the host disconnected after
2.5 seconds without valid feedback. Wrong boot nonces and invalid fields are
rejected. QEQ expires identities after three seconds. Feedback is state, never
an input event. The physical controls do not directly modify host state on boot.

Both repositories carry matching `HardwareMIDI.txt` golden fixtures and tests.
Changes to wire layout or incompatible control semantics require a protocol bump.

## Prepared four-channel model

Model 2 extends the identity descriptor list to ten controls (59 bytes total).
The first four descriptors retain their IDs and CCs. Additional slider/button
pairs are `(5,0,20)/(6,2,21)`, `(7,0,22)/(8,2,23)`, and `(9,0,24)/(10,2,25)`.
Each pair has independent input state and filtering. The current QEQ host only
accepts model 1; model 2 is reserved for the upcoming per-slot assignment and
display-feedback integration. Hardware-test builds expose no MIDI interface.

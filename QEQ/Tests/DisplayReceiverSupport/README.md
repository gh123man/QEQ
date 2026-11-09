# Firmware interoperability fixture

`firmware/display_stream.{h,cpp}` track vol-firmware's bounded receiver, originally from commit
`b64dc09` (`codex/usb-display-streaming`), with the 2026-11-08 ROM/table CRC
optimization synchronized from the V2 carousel work. The wrapper supplies an in-memory panel
and USB pipe so Swift's native sender can be tested against the actual bounded C++
receiver and LZ4 decoder without hardware. Keep the snapshots in sync when changing
the wire protocol. This target is linked only into tests, never the shipping app.

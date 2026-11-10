# Firmware interoperability fixture

`firmware/display_stream.{h,cpp}` mirror vol-firmware `0e5ab48`, including the DMA
completion barrier and negotiated partial-tile rectangles. The wrapper supplies an in-memory panel
and USB pipe so Swift's native sender can be tested against the actual bounded C++
receiver and LZ4 decoder without hardware. Keep the snapshots in sync when changing
the wire protocol. This target is linked only into tests, never the shipping app.

# Firmware interoperability fixture

`firmware/display_stream.{h,cpp}` mirror vol-firmware `bf31f26`, including the DMA
completion barrier in `Sink::flush()`. The wrapper supplies an in-memory panel
and USB pipe so Swift's native sender can be tested against the actual bounded C++
receiver and LZ4 decoder without hardware. Keep the snapshots in sync when changing
the wire protocol. This target is linked only into tests, never the shipping app.

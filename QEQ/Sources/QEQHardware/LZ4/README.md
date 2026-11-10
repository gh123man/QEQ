# Bundled LZ4

Upstream LZ4 **v1.10.0**, BSD 2-Clause license (see `LICENSE` and file headers):
https://github.com/lz4/lz4/tree/v1.10.0/lib

`lz4.c` / `lz4.h` provide the independent block decoder and fast compressor.
`lz4hc.c` / `lz4hc.h` provide the host-side HC encoder. All four are unmodified
upstream sources. `../Codec.c` owns QEQ's reusable encoder state and resets history
before each tile so firmware needs no dictionary or protocol change.

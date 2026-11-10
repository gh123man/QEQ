#pragma once
#include <stdint.h>
#include <stddef.h>

namespace stream {
constexpr size_t headerSize = 28, maxPayload = 2064, tileEdge = 32;
enum Type : uint8_t { hello=1, capabilities=2, begin=3, tile=4, commit=5, ack=6, ping=7, pong=8, probe=9, probeEnd=10 };
enum Status : uint32_t { ok=0, malformed=1, sequence=2, bounds=3, compression=4, incomplete=5, expired=6 };
struct Capabilities {
  uint16_t width, height;
  uint8_t format, orientation, shape; // 1=RGB565 little-endian, clockwise quarter-turns, 0=rect/1=circle
  uint32_t spiHz, boot;
};
uint16_t u16(const uint8_t* p);
uint32_t u32(const uint8_t* p);
void put16(uint8_t* p, uint16_t v);
void put32(uint8_t* p, uint32_t v);
uint32_t crc32(const uint8_t* p, size_t size, uint32_t seed=0);
size_t message(uint8_t* out, Type type, uint16_t flags, uint32_t session, uint32_t frame,
               uint32_t base, const uint8_t* payload, size_t size);
class Sink {
public:
  virtual ~Sink() {}
  virtual Capabilities caps() const = 0;
  virtual uint32_t microsNow() const = 0;
  virtual void pixels(uint16_t x, uint16_t y, uint16_t w, uint16_t h, const uint16_t* rgb565) = 0;
  // Complete any queued panel writes before acknowledging a frame.
  virtual void flush() {}
  virtual void disconnected() = 0;
  virtual void reply(const uint8_t* data, size_t size) = 0;
  virtual uint32_t inputGapUs() const = 0;
};
// Single owner/task. No unbounded frame queue or frame buffer; flush completes tiles before ACK.
class Receiver {
public:
  explicit Receiver(Sink& sink): sink_(sink) {}
  void feed(const uint8_t* bytes, size_t size);
  void tick();
  void disconnect();
  uint32_t acknowledged() const { return acknowledged_; }
private:
  Sink& sink_;
  uint8_t packet_[headerSize + maxPayload] = {};
  alignas(4) uint16_t pixels_[tileEdge * tileEdge] = {};
  size_t used_=0, expected_=headerSize;
  uint32_t session_=0, frame_=0, acknowledged_=0, lastActivity_=0, started_=0;
  uint32_t decodeUs_=0, lcdUs_=0, wireBytes_=0, verifyUs_=0;
  uint16_t wanted_=0, received_=0;
  bool active_=false, full_=false, hasBaseline_=false, probing_=false, partialTiles_=false;
  uint8_t seen_[128] = {}; // Up to 1024 tiles; negotiated dimensions validated on HELLO.
  void process();
  void respond(Type type, Status status);
  void fail(Status status);
};
}

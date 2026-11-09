#include "display_stream.h"
#include "lz4.h"
#include <string.h>
#ifdef ESP32
#include "esp_rom_crc.h"
#endif

namespace stream {
uint16_t u16(const uint8_t* p) { return uint16_t(p[0]) | uint16_t(p[1]) << 8; }
uint32_t u32(const uint8_t* p) { return uint32_t(u16(p)) | uint32_t(u16(p+2)) << 16; }
void put16(uint8_t* p, uint16_t v) { p[0]=v; p[1]=v>>8; }
void put32(uint8_t* p, uint32_t v) { put16(p,v); put16(p+2,v>>16); }
uint32_t crc32(const uint8_t* p, size_t size, uint32_t seed) {
#ifdef ESP32
  // ROM uses the same reflected IEEE polynomial and complemented seed/result.
  return esp_rom_crc32_le(seed,p,size);
#else
  // IEEE CRC-32, same seeded wire checksum, one table lookup per byte.
  // Constructed once on the receiver task; no per-frame allocation.
  struct Table {
    uint32_t values[256];
    Table() {
      for(uint32_t i=0;i<256;++i) {
        uint32_t c=i;
        for(int bit=0;bit<8;++bit) c=(c>>1) ^ (0xEDB88320u & (0u-(c&1)));
        values[i]=c;
      }
    }
  };
  static const Table table;
  uint32_t crc=~seed;
  while(size--) crc=table.values[(crc^*p++)&255] ^ (crc>>8);
  return ~crc;
#endif
}
size_t message(uint8_t* out, Type type, uint16_t flags, uint32_t session, uint32_t frame,
               uint32_t base, const uint8_t* payload, size_t size) {
  memcpy(out,"QDSP",4); out[4]=1; out[5]=type; put16(out+6,flags);
  put32(out+8,session); put32(out+12,frame); put32(out+16,base); put32(out+20,size);
  if(size) memcpy(out+headerSize,payload,size);
  put32(out+24,crc32(out+headerSize,size,crc32(out,24))); return headerSize+size;
}
void Receiver::respond(Type type, Status status) {
  uint8_t payload[32], output[headerSize+sizeof(payload)];
  put32(payload,status); put32(payload+4,decodeUs_); put32(payload+8,lcdUs_);
  put32(payload+12,(active_ || probing_) ? uint32_t(sink_.microsNow()-started_) : 0);
  put32(payload+16,received_); put32(payload+20,wireBytes_); put32(payload+24,sink_.inputGapUs()); put32(payload+28,verifyUs_);
  sink_.reply(output,message(output,type,0,session_,frame_,acknowledged_,payload,sizeof(payload)));
}
void Receiver::fail(Status status) {
  respond(ack,status); active_=false; probing_=false; hasBaseline_=false; session_=0;
  sink_.disconnected();
}
void Receiver::disconnect() {
  active_=false; probing_=false; hasBaseline_=false; session_=0; acknowledged_=0;
  used_=0; expected_=headerSize; sink_.disconnected();
}
void Receiver::tick() {
  if(session_ && uint32_t(sink_.microsNow()-lastActivity_)>3000000) { fail(expired); used_=0; expected_=headerSize; }
}
void Receiver::feed(const uint8_t* bytes, size_t size) {
  while(size--) {
    const uint8_t b=*bytes++;
    if(used_<4 && b!=uint8_t("QDSP"[used_])) { used_=b=='Q'?1:0; packet_[0]='Q'; continue; }
    packet_[used_++]=b;
    if(used_==headerSize) {
      const uint32_t length=u32(packet_+20);
      if(packet_[4]!=1 || length>maxPayload) { fail(malformed); used_=0; expected_=headerSize; continue; }
      expected_=headerSize+length;
    }
    if(used_==expected_) {
      if(u32(packet_+24)!=crc32(packet_+headerSize,expected_-headerSize,crc32(packet_,24))) fail(malformed);
      else process();
      used_=0; expected_=headerSize;
    }
  }
}
void Receiver::process() {
  const uint8_t type=packet_[5]; const uint16_t flags=u16(packet_+6);
  const uint32_t session=u32(packet_+8), frame=u32(packet_+12), base=u32(packet_+16);
  const size_t length=u32(packet_+20); const uint8_t* data=packet_+headerSize;
  const auto caps=sink_.caps();
  const uint16_t columns=(caps.width+tileEdge-1)/tileEdge, rows=(caps.height+tileEdge-1)/tileEdge;
  if(type==hello) {
    if(!session || frame || base || flags || length || !columns || !rows || uint32_t(columns)*rows>1024 || caps.format!=1) { fail(malformed); return; }
    active_=false; probing_=false; hasBaseline_=false; acknowledged_=0; frame_=0; session_=session;
    lastActivity_=sink_.microsNow(); sink_.disconnected();
    uint8_t payload[24]={}, output[headerSize+24];
    put16(payload,caps.width); put16(payload+2,caps.height); put16(payload+4,tileEdge); put16(payload+6,tileEdge);
    payload[8]=caps.format; payload[9]=caps.orientation; payload[10]=caps.shape; payload[11]=3; // raw + LZ4 block
    put32(payload+12,maxPayload); put32(payload+16,caps.spiHz); put32(payload+20,caps.boot);
    sink_.reply(output,message(output,capabilities,0,session_,0,0,payload,sizeof(payload))); return;
  }
  if(!session_ || session!=session_) { fail(sequence); return; }
  lastActivity_=sink_.microsNow();
  if(type==probe || type==probeEnd) {
    if(active_ || frame!=acknowledged_ || base!=acknowledged_ || flags>1) { fail(sequence); return; }
    if(type==probe && flags==1) {
      if(probing_) { fail(sequence); return; }
      probing_=true; started_=sink_.microsNow(); decodeUs_=lcdUs_=wireBytes_=verifyUs_=0; received_=0;
    }
    if(!probing_ || (type==probeEnd && (flags || length))) { fail(sequence); return; }
    wireBytes_+=headerSize+length;
    if(wireBytes_>524288) { fail(bounds); return; }
    if(type==probeEnd) { respond(probeEnd,ok); probing_=false; }
    return;
  }
  if(probing_) { fail(sequence); return; }
  if(type==ping) {
    if(active_ || flags || length || frame!=acknowledged_ || base!=acknowledged_) { fail(sequence); return; }
    respond(pong,ok); return;
  }
  if(type==begin) {
    if(active_ || length!=2 || flags>1 || !frame || frame!=acknowledged_+1 || base!=(flags?0:acknowledged_) || (!flags&&!hasBaseline_)) { fail(sequence); return; }
    wanted_=u16(data); full_=flags==1;
    if(wanted_>columns*rows || (full_ && wanted_!=columns*rows)) { fail(incomplete); return; }
    frame_=frame; received_=0; decodeUs_=lcdUs_=verifyUs_=0; wireBytes_=headerSize+length;
    memset(seen_,0,sizeof(seen_)); active_=true; started_=sink_.microsNow(); return;
  }
  if(!active_ || frame!=frame_ || base!=(full_?0:acknowledged_) || flags) { fail(sequence); return; }
  wireBytes_+=headerSize+length;
  if(type==tile) {
    if(length<16 || received_>=wanted_) { fail(bounds); return; }
    const uint16_t x=u16(data), y=u16(data+2), w=u16(data+4), h=u16(data+6), decoded=u16(data+10);
    if(x>=caps.width || y>=caps.height || x%tileEdge || y%tileEdge || data[9] ||
       w!=(caps.width-x<tileEdge?caps.width-x:tileEdge) || h!=(caps.height-y<tileEdge?caps.height-y:tileEdge) || decoded!=w*h*2) { fail(bounds); return; }
    const size_t index=(y/tileEdge)*columns+x/tileEdge;
    if(seen_[index/8] & (1u<<(index%8))) { fail(sequence); return; }
    const uint32_t start=sink_.microsNow();
    if(data[8]==0 && length-16==decoded) memcpy(pixels_,data+16,decoded);
    else if(data[8]==1 && length-16<decoded) {
      if(LZ4_decompress_safe(reinterpret_cast<const char*>(data+16),reinterpret_cast<char*>(pixels_),length-16,decoded)!=decoded) { fail(compression); return; }
    } else { fail(compression); return; }
    decodeUs_+=uint32_t(sink_.microsNow()-start);
    const uint32_t verifyStart=sink_.microsNow();
    if(crc32(reinterpret_cast<const uint8_t*>(pixels_),decoded)!=u32(data+12)) { fail(compression); return; }
    verifyUs_+=uint32_t(sink_.microsNow()-verifyStart);
    const uint32_t lcdStart=sink_.microsNow(); sink_.pixels(x,y,w,h,pixels_); lcdUs_+=uint32_t(sink_.microsNow()-lcdStart);
    seen_[index/8]|=1u<<(index%8); ++received_; return;
  }
  if(type==commit && !length && received_==wanted_) {
    acknowledged_=frame_; hasBaseline_=true; respond(ack,ok); active_=false; return;
  }
  fail(incomplete);
}
}

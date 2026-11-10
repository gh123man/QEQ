#include "DisplayReceiverTestSupport.h"
#include "firmware/display_stream.h"
#include <vector>
#include <cstring>
#include <algorithm>
struct TestSink : stream::Sink {
    uint32_t now = 100;
    uint16_t width, height;
    std::vector<uint16_t> pixels_;
    TestSink(uint16_t w=64,uint16_t h=32):width(w),height(h),pixels_(size_t(w)*h){}
    std::vector<uint8_t> replies;
    stream::Capabilities caps() const override { return {width,height,1,0,uint8_t(width==height),10000000,42}; }
    uint32_t microsNow() const override { return now; }
    uint32_t inputGapUs() const override { return 1000; }
    void pixels(uint16_t x, uint16_t y, uint16_t w, uint16_t h, const uint16_t *p) override {
        for (size_t row = 0; row < h; ++row) memcpy(pixels_.data() + (row + y) * width + x, p + row * w, w * 2);
        now += 200;
    }
    void disconnected() override { std::fill(pixels_.begin(),pixels_.end(),0); }
    void reply(const uint8_t *p, size_t count) override { if (replies.size() + count <= 8192) replies.insert(replies.end(), p, p + count); }
};
struct QEQTestReceiver { TestSink sink; stream::Receiver receiver; QEQTestReceiver(uint16_t w=64,uint16_t h=32):sink(w,h),receiver(sink){} };
QEQTestReceiver *qeq_test_receiver_create() { return new QEQTestReceiver(); }
QEQTestReceiver *qeq_test_receiver_create_display(uint16_t w,uint16_t h) { return new QEQTestReceiver(w,h); }
void qeq_test_receiver_destroy(QEQTestReceiver *r) { delete r; }
void qeq_test_receiver_feed(QEQTestReceiver *r, const uint8_t *p, size_t n) { r->receiver.feed(p,n); }
size_t qeq_test_receiver_read(QEQTestReceiver *r, uint8_t *p, size_t n) {
    n=std::min(n,r->sink.replies.size()); std::copy_n(r->sink.replies.begin(),n,p);
    r->sink.replies.erase(r->sink.replies.begin(),r->sink.replies.begin()+n); return n;
}
uint32_t qeq_test_receiver_pixels_crc(QEQTestReceiver *r) { return stream::crc32(reinterpret_cast<uint8_t*>(r->sink.pixels_.data()),r->sink.pixels_.size()*2); }
uint32_t qeq_test_receiver_acknowledged(QEQTestReceiver *r) { return r->receiver.acknowledged(); }
void qeq_test_receiver_expire(QEQTestReceiver *r) { r->sink.now+=3000001; r->receiver.tick(); }

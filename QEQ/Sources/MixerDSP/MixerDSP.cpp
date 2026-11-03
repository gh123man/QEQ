#include "MixerDSP.h"
#include <atomic>
#include <algorithm>
#include <cmath>
#include <cstring>

namespace {
struct Coeff { double b0=1, b1=0, b2=0, a1=0, a2=0; };
struct State { double z1=0, z2=0; };
static_assert(std::atomic<double>::is_always_lock_free);
static_assert(std::atomic<float>::is_always_lock_free);
static_assert(std::atomic<bool>::is_always_lock_free);
static_assert(std::atomic<uint64_t>::is_always_lock_free);
constexpr int bandCount=10, paramCount=1+bandCount*5, analysisCount=MixerAnalysisFrameCount;
Coeff filter(double rate, double hz, double db, double q, int kind) {
    if (kind<3 && std::abs(db)<0.00001) return {};
    const double A=std::pow(10., db/40.), w=2*M_PI*std::min(hz, rate*.45)/rate;
    const double c=std::cos(w), s=std::sin(w);
    const double alpha=(kind==0||kind==2) ? s/2*std::sqrt((A+1/A)*(1/q-1)+2) : s/(2*q);
    const double t=2*std::sqrt(A)*alpha;
    double b0,b1,b2,a0,a1,a2;
    if(kind==0) {
        b0=A*((A+1)-(A-1)*c+t); b1=2*A*((A-1)-(A+1)*c); b2=A*((A+1)-(A-1)*c-t);
        a0=(A+1)+(A-1)*c+t; a1=-2*((A-1)+(A+1)*c); a2=(A+1)+(A-1)*c-t;
    } else if(kind==2) {
        b0=A*((A+1)+(A-1)*c+t); b1=-2*A*((A-1)+(A+1)*c); b2=A*((A+1)+(A-1)*c-t);
        a0=(A+1)-(A-1)*c+t; a1=2*((A-1)-(A+1)*c); a2=(A+1)-(A-1)*c-t;
    } else if(kind==3||kind==4) {
        b0=kind==3?(1+c)/2:(1-c)/2; b1=kind==3?-(1+c):1-c; b2=b0;
        a0=1+alpha; a1=-2*c; a2=1-alpha;
    } else {
        b0=1+alpha*A; b1=-2*c; b2=1-alpha*A; a0=1+alpha/A; a1=-2*c; a2=1-alpha/A;
    }
    return {b0/a0,b1/a0,b2/a0,a1/a0,a2/a0};
}
MixerEQBand sanitized(MixerEQBand b) {
    auto safe=[](float v,float lo,float hi,float fallback) { return std::isfinite(v)?std::clamp(v,lo,hi):fallback; };
    b.type=std::min(b.type,4u);
    b.frequency=safe(b.frequency,20,20000,1000); b.gain=safe(b.gain,-18,18,0);
    b.q=safe(b.q,.1,(b.type==0||b.type==2)?1:10,.70710678);
    return b;
}
Coeff coefficients(double rate, MixerEQBand b) {
    b=sanitized(b); return b.enabled?filter(rate,b.frequency,b.gain,b.q,b.type):Coeff{};
}

}
struct MixerDSP {
    double rate;
    uint32_t channels, tapBuffers;
    std::atomic<uint64_t> version{0}, frames{0}, faults{0};
    std::atomic<double> parameters[paramCount];
    std::atomic<float> peak{0}, sourcePeak{0}, limitingDB{0};
    double limiterGain=1, limiterRelease;
    double target[paramCount]{}, current[paramCount]{};
    State state[2][bandCount];
    std::atomic<bool> analyze{false};
    std::atomic<uint64_t> analysisVersion{0}, analysisFrames{0};
    std::atomic<float> analysis[2][analysisCount]{};
    uint64_t analysisPosition=0;
    uint32_t remaining=0;
    uint64_t applied=0;
    MixerDSP(double r, uint32_t c, uint32_t b): rate(r),channels(c),tapBuffers(b),limiterRelease(std::exp(-1./(.05*r))) {
        current[0]=target[0]=1;
        for (int band=0;band<bandCount;band++) current[1+band*5]=target[1+band*5]=1;
        for(int i=0;i<paramCount;i++) parameters[i].store(current[i],std::memory_order_relaxed);
    }
};
MixerDSP *MixerDSPCreate(double rate,uint32_t channels,uint32_t buffers) {
    if(!std::isfinite(rate)||rate<8000||rate>384000||channels<1||channels>2||buffers<1||buffers>2) return nullptr;
    return new MixerDSP(rate,channels,buffers);
}
void MixerDSPDestroy(MixerDSP *dsp) { delete dsp; }
double MixerEQResponse(const MixerEQBand *bands,uint32_t count,double rate,double hz) {
    if(!std::isfinite(rate)||rate<8000||!std::isfinite(hz)) return 0;
    const double w=2*M_PI*std::clamp(hz,1.,rate*.499)/rate;
    double power=1;
    for(uint32_t i=0;bands && i<std::min(count,(uint32_t)bandCount);i++) {
        const auto c=coefficients(rate,bands[i]);
        const double nr=c.b0+c.b1*std::cos(w)+c.b2*std::cos(2*w), ni=-c.b1*std::sin(w)-c.b2*std::sin(2*w);
        const double dr=1+c.a1*std::cos(w)+c.a2*std::cos(2*w), di=-c.a1*std::sin(w)-c.a2*std::sin(2*w);
        power*=std::max(1e-20,(nr*nr+ni*ni)/std::max(1e-20,dr*dr+di*di));
    }
    return 10*std::log10(std::max(1e-20,power));
}
void MixerDSPConfigure(MixerDSP *d,float volume,bool muted,const MixerEQBand *bands,uint32_t count) {
    if(!d) return;
    volume=std::isfinite(volume)?std::clamp(volume,0.f,2.f):1.f;
    Coeff filters[bandCount];
    for(uint32_t i=0;bands && i<std::min(count,(uint32_t)bandCount);i++) filters[i]=coefficients(d->rate,bands[i]);
    d->version.fetch_add(1);
    d->parameters[0].store(muted?0:volume);
    for(int b=0;b<bandCount;b++) {
        const double values[]={filters[b].b0,filters[b].b1,filters[b].b2,filters[b].a1,filters[b].a2};
        for(int j=0;j<5;j++) d->parameters[1+b*5+j].store(values[j]);
    }
    d->version.fetch_add(1);
}
void MixerDSPSet(MixerDSP *d,float volume,float bass,float mid,float treble,bool muted) {
    const MixerEQBand bands[]={{0,180,bass,1,true},{1,1000,mid,.70710678f,true},{2,5000,treble,1,true}};
    MixerDSPConfigure(d,volume,muted,bands,3);
}
void MixerDSPEnableAnalysis(MixerDSP *d,bool enabled) { if(d) d->analyze.store(enabled); }
bool MixerDSPReadAnalysis(const MixerDSP *d,float *left,float *right,uint32_t count) {
    if(!d || !left || !right || count!=analysisCount || !d->analyze.load()) return false;
    const auto v=d->analysisVersion.load();
    if(v&1) return false;
    const auto end=d->analysisFrames.load();
    if(end<analysisCount) return false;
    for(uint32_t i=0;i<count;i++) {
        const auto slot=(end-count+i)%analysisCount;
        left[i]=d->analysis[0][slot].load(); right[i]=d->analysis[1][slot].load();
    }
    return v==d->analysisVersion.load();
}
void MixerDSPProcess(MixerDSP *d,const AudioBufferList *input,AudioBufferList *output) {
    for(uint32_t b=0;b<output->mNumberBuffers;b++) if(output->mBuffers[b].mData) std::memset(output->mBuffers[b].mData,0,output->mBuffers[b].mDataByteSize);
    if(!d) return;
    if(input->mNumberBuffers<d->tapBuffers) { d->faults.fetch_add(1,std::memory_order_relaxed); return; }
    const uint32_t start=input->mNumberBuffers-d->tapBuffers;
    const float *in[2]{}; float *out[2]{}; uint32_t inStride[2]{},outStride[2]{};
    uint32_t frames=UINT32_MAX,ci=0,co=0;
    for(uint32_t b=start;b<input->mNumberBuffers && ci<d->channels;b++) {
        const auto &buf=input->mBuffers[b];
        if(!buf.mData||!buf.mNumberChannels) { d->faults.fetch_add(1,std::memory_order_relaxed); return; }
        frames=std::min(frames,buf.mDataByteSize/(4*buf.mNumberChannels));
        for(uint32_t c=0;c<buf.mNumberChannels && ci<d->channels;c++,ci++) { in[ci]=(const float*)buf.mData+c; inStride[ci]=buf.mNumberChannels; }
    }
    for(uint32_t b=0;b<output->mNumberBuffers && co<d->channels;b++) {
        auto &buf=output->mBuffers[b];
        if(!buf.mData||!buf.mNumberChannels) { d->faults.fetch_add(1,std::memory_order_relaxed); return; }
        frames=std::min(frames,buf.mDataByteSize/(4*buf.mNumberChannels));
        for(uint32_t c=0;c<buf.mNumberChannels && co<d->channels;c++,co++) { out[co]=(float*)buf.mData+c; outStride[co]=buf.mNumberChannels; }
    }
    if(ci!=d->channels||co!=d->channels||frames==UINT32_MAX) { d->faults.fetch_add(1,std::memory_order_relaxed); return; }
    const auto version=d->version.load();
    if(!(version&1) && version!=d->applied) {
        double snapshot[paramCount];
        for(int i=0;i<paramCount;i++) snapshot[i]=d->parameters[i].load();
        if(d->version.load()==version) {
            std::copy(snapshot,snapshot+paramCount,d->target); d->applied=version;
            d->remaining=(uint32_t)(d->rate*.01); // 10 ms dezippering, no audio queue
        }
    }
    const bool analyze=d->analyze.load(std::memory_order_relaxed);
    if(analyze) d->analysisVersion.fetch_add(1);
    float peak=0, sourcePeak=0;
    double minimumGain=1;
    for(uint32_t f=0;f<frames;f++) {
        if(d->remaining) {
            for(int i=0;i<paramCount;i++) d->current[i]+=(d->target[i]-d->current[i])/d->remaining;
            d->remaining--;
        }
        double processed[2]{}, framePeak=0;
        for(uint32_t c=0;c<d->channels;c++) {
            double x=in[c][f*inStride[c]];
            // Observe only the app tap, before EQ/gain/mute. No extra buffer or
            // FFT is needed to show source activity while its output is muted.
            if(std::isfinite(x)) sourcePeak=std::max(sourcePeak,(float)std::abs(x));
            for(int b=0;b<bandCount;b++) {
                const double *v=d->current+1+b*5; auto &s=d->state[c][b];
                double y=v[0]*x+s.z1;
                s.z1=v[1]*x-v[3]*y+s.z2; s.z2=v[2]*x-v[4]*y;
                if(std::abs(s.z1)<1e-25) s.z1=0;
                if(std::abs(s.z2)<1e-25) s.z2=0;
                x=y;
            }
            x*=d->current[0];
            if(!std::isfinite(x)) { x=0; for(auto &s:d->state[c]) s={}; }
            processed[c]=x; framePeak=std::max(framePeak,std::abs(x));
        }
        // Stereo-linked sample-peak protection: instantaneous attack, 50 ms
        // release. No lookahead, extra buffer, or fixed attenuation for EQ boosts.
        const double required=framePeak>1 ? 1/framePeak : 1;
        const double recovering=1-(1-d->limiterGain)*d->limiterRelease;
        d->limiterGain=std::min(required,recovering);
        minimumGain=std::min(minimumGain,d->limiterGain);
        for(uint32_t c=0;c<d->channels;c++) {
            const float sample=(float)std::clamp(processed[c]*d->limiterGain,-1.,1.);
            if(analyze) d->analysis[c][d->analysisPosition%analysisCount].store(sample);
            out[c][f*outStride[c]]=sample; peak=std::max(peak,std::abs(sample));
        }
        if(analyze) {
            if(d->channels==1) d->analysis[1][d->analysisPosition%analysisCount].store(d->analysis[0][d->analysisPosition%analysisCount].load());
            d->analysisPosition++;
        }
    }
    if(analyze) { d->analysisFrames.store(d->analysisPosition); d->analysisVersion.fetch_add(1); }
    d->peak.store(peak,std::memory_order_relaxed);
    d->sourcePeak.store(sourcePeak,std::memory_order_relaxed);
    d->limitingDB.store((float)(-20*std::log10(std::max(1e-20,minimumGain))),std::memory_order_relaxed);
    d->frames.fetch_add(frames,std::memory_order_relaxed);
}
OSStatus MixerDSPCallback(AudioObjectID,const AudioTimeStamp*,const AudioBufferList *in,const AudioTimeStamp*,AudioBufferList *out,const AudioTimeStamp*,void *context) {
    MixerDSPProcess(static_cast<MixerDSP*>(context),in,out); return noErr;
}
float MixerDSPPeak(const MixerDSP *d) { return d->peak.load(std::memory_order_relaxed); }
float MixerDSPSourcePeak(const MixerDSP *d) { return d->sourcePeak.load(std::memory_order_relaxed); }
float MixerDSPLimitingDB(const MixerDSP *d) { return d->limitingDB.load(std::memory_order_relaxed); }
uint64_t MixerDSPFrames(const MixerDSP *d) { return d->frames.load(std::memory_order_relaxed); }
uint64_t MixerDSPFaults(const MixerDSP *d) { return d->faults.load(std::memory_order_relaxed); }

OSStatus MixerDSPRegister(AudioObjectID device, MixerDSP *dsp, AudioDeviceIOProcID *proc) {
    return AudioDeviceCreateIOProcID(device, MixerDSPCallback, dsp, proc);
}

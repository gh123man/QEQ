#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct MixerDSP MixerDSP;
typedef struct { uint32_t type; float frequency, gain, q; bool enabled; } MixerEQBand;
void MixerDSPConfigure(MixerDSP *dsp, float volume, bool muted, const MixerEQBand *bands, uint32_t count);
double MixerEQResponse(const MixerEQBand *bands, uint32_t count, double rate, double frequency);
// Analysis observes a copy; it never queues or delays playback.
enum { MixerAnalysisFrameCount = 16384 };
void MixerDSPEnableAnalysis(MixerDSP *dsp, bool enabled);
bool MixerDSPReadAnalysis(const MixerDSP *dsp, float *left, float *right, uint32_t count);
MixerDSP *MixerDSPCreate(double sampleRate, uint32_t channels, uint32_t tapBuffers);
void MixerDSPDestroy(MixerDSP *dsp);
// One control-thread writer; realtime reader never waits or allocates.
void MixerDSPSet(MixerDSP *dsp, float volume, float bassDB, float midDB, float trebleDB, bool muted);
void MixerDSPProcess(MixerDSP *dsp, const AudioBufferList *input, AudioBufferList *output);
OSStatus MixerDSPCallback(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
 const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *context);
OSStatus MixerDSPRegister(AudioObjectID device, MixerDSP *dsp, AudioDeviceIOProcID *proc);
float MixerDSPPeak(const MixerDSP *dsp);
// Maximum stereo-linked gain reduction in the latest callback, in dB.
float MixerDSPLimitingDB(const MixerDSP *dsp);
uint64_t MixerDSPFrames(const MixerDSP *dsp);
uint64_t MixerDSPFaults(const MixerDSP *dsp);
#ifdef __cplusplus
}
#endif

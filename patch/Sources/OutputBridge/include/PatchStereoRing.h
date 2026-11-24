#pragma once
#include <stdint.h>
#include <AudioToolbox/AudioToolbox.h>
// Bounded native-rate PCM SPSC queue. Conversion happens outside hardware callbacks.
typedef struct PatchStereoRing PatchStereoRing;
PatchStereoRing *PatchStereoCreate(void);
void PatchStereoDestroy(PatchStereoRing *ring);
void PatchStereoWrite(PatchStereoRing *ring, const float *interleaved, uint32_t frames);
void PatchStereoCapture(PatchStereoRing *ring, const AudioBufferList *list, uint32_t frames, uint32_t x, uint32_t y);
void PatchStereoRead(PatchStereoRing *ring, float *interleaved, uint32_t frames);
void PatchStereoRender(PatchStereoRing *ring, AudioBufferList *list, uint32_t frames, uint32_t x, uint32_t y);
uint64_t PatchStereoDrops(PatchStereoRing *ring);

uint64_t PatchStereoWritten(PatchStereoRing *ring);
uint64_t PatchStereoRequested(PatchStereoRing *ring);
uint64_t PatchStereoUnderruns(PatchStereoRing *ring);
uint64_t PatchStereoTrims(PatchStereoRing *ring);

uint32_t PatchStereoDrain(PatchStereoRing *ring, float *interleaved, uint32_t capacity);

void PatchStereoPlaybackRate(PatchStereoRing *ring,double sampleRate);

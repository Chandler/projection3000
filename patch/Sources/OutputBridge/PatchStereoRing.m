#include "PatchStereoRing.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#define CAPACITY 32768
struct PatchStereoRing {
    _Atomic uint64_t read, write, drops, requested, underruns, trims;
    float samples[CAPACITY][2];
    int primed;
    uint32_t prefill, maxLatency;
};
PatchStereoRing *PatchStereoCreate(void) { PatchStereoRing *r=calloc(1,sizeof(PatchStereoRing));if(r){r->prefill=960;r->maxLatency=4800;}return r; }
void PatchStereoPlaybackRate(PatchStereoRing *r,double rate) { r->prefill=(uint32_t)(rate*0.02);r->maxLatency=(uint32_t)(rate*0.1); }
void PatchStereoDestroy(PatchStereoRing *r) { free(r); }
static float clean(float v) { return isfinite(v) ? fminf(1,fmaxf(-1,v)):0; }
void PatchStereoWrite(PatchStereoRing *r,const float *data,uint32_t n) {
    uint64_t w=atomic_load_explicit(&r->write,memory_order_relaxed), rd=atomic_load_explicit(&r->read,memory_order_acquire);
    if(w-rd+n>=CAPACITY) { atomic_fetch_add(&r->drops,1); return; }
    for(uint32_t i=0;i<n;i++) { r->samples[(w+i)%CAPACITY][0]=clean(data[i*2]);r->samples[(w+i)%CAPACITY][1]=clean(data[i*2+1]); }
    atomic_store_explicit(&r->write,w+n,memory_order_release);
}
void PatchStereoCapture(PatchStereoRing *r,const AudioBufferList *list,uint32_t n,uint32_t x,uint32_t y) {
    if(x>=list->mNumberBuffers || y>=list->mNumberBuffers) return;
    const float *a=list->mBuffers[x].mData,*b=list->mBuffers[y].mData;
    if(!a || !b) return;
    uint64_t w=atomic_load_explicit(&r->write,memory_order_relaxed),rd=atomic_load_explicit(&r->read,memory_order_acquire);
    if(w-rd+n>=CAPACITY) { atomic_fetch_add(&r->drops,1);return; }
    for(uint32_t i=0;i<n;i++) { r->samples[(w+i)%CAPACITY][0]=clean(a[i]);r->samples[(w+i)%CAPACITY][1]=clean(b[i]); }
    atomic_store_explicit(&r->write,w+n,memory_order_release);
}
static void readFrames(PatchStereoRing *r,float *a,float *b,uint32_t stride,uint32_t n) {
    atomic_fetch_add_explicit(&r->requested,n,memory_order_relaxed);
    uint64_t rd=atomic_load_explicit(&r->read,memory_order_relaxed),w=atomic_load_explicit(&r->write,memory_order_acquire);
    // Bound latency after scheduling stalls; only the consumer advances read.
    if(w-rd>(uint64_t)r->maxLatency) { rd=w-(uint64_t)r->prefill;atomic_fetch_add(&r->drops,1);atomic_fetch_add(&r->trims,1); }
    // Bridge hardware callback timing and 10 ms graph blocks without recurring gaps.
    if(!r->primed) { if(w-rd<r->prefill) return; r->primed=1; }
    uint32_t i=0;
    for(;i<n && rd+i<w;i++) {
        const float *p=r->samples[(rd+i)%CAPACITY];
        a[i*stride]=p[0];b[i*stride]=p[1];
    }
    rd+=i;
    if(i<n) { r->primed=0;atomic_fetch_add(&r->drops,1);atomic_fetch_add(&r->underruns,1); }
    atomic_store_explicit(&r->read,rd,memory_order_release);
}
void PatchStereoRead(PatchStereoRing *r,float *data,uint32_t n) { memset(data,0,n*2*sizeof(float));readFrames(r,data,data+1,2,n); }
void PatchStereoRender(PatchStereoRing *r,AudioBufferList *list,uint32_t n,uint32_t x,uint32_t y) {
    for(uint32_t i=0;i<list->mNumberBuffers;i++) if(list->mBuffers[i].mData) memset(list->mBuffers[i].mData,0,list->mBuffers[i].mDataByteSize);
    if(x>=list->mNumberBuffers || y>=list->mNumberBuffers) return;
    float *a=list->mBuffers[x].mData,*b=list->mBuffers[y].mData;
    if(a && b) readFrames(r,a,b,1,n);
}
uint64_t PatchStereoDrops(PatchStereoRing *r) { return atomic_load(&r->drops); }

uint64_t PatchStereoWritten(PatchStereoRing *r) { return atomic_load(&r->write); }
uint64_t PatchStereoRequested(PatchStereoRing *r) { return atomic_load(&r->requested); }
uint64_t PatchStereoUnderruns(PatchStereoRing *r) { return atomic_load(&r->underruns); }
uint64_t PatchStereoTrims(PatchStereoRing *r) { return atomic_load(&r->trims); }

// Native capture history: drain actual samples without resampling or zero padding.
uint32_t PatchStereoDrain(PatchStereoRing *r,float *data,uint32_t capacity) {
    uint64_t rd=atomic_load_explicit(&r->read,memory_order_relaxed),w=atomic_load_explicit(&r->write,memory_order_acquire);
    uint32_t count=(uint32_t)(w-rd);if(count>capacity)count=capacity;
    for(uint32_t i=0;i<count;i++) { data[i*2]=r->samples[(rd+i)%CAPACITY][0];data[i*2+1]=r->samples[(rd+i)%CAPACITY][1]; }
    atomic_store_explicit(&r->read,rd+count,memory_order_release);return count;
}

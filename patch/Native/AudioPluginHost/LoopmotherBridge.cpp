#include "Loopmother/SynthEngine.h"
#include <algorithm>
#include <cmath>
struct LoopmotherHandle { loop2::SynthEngine synth; juce::AudioBuffer<float> buffer; double rate=0; };
extern "C" {
void* lm_create() { try { return new LoopmotherHandle; } catch (...) { return nullptr; } }
void lm_destroy(void* p) { delete static_cast<LoopmotherHandle*>(p); }
void lm_reset(void* p) { static_cast<LoopmotherHandle*>(p)->synth.allNotesOff(); }
void lm_note(void* p, int note, float velocity) {
    auto& s=static_cast<LoopmotherHandle*>(p)->synth;
    if (velocity>0) s.noteOn(note,velocity); else s.noteOff(note);
}
void lm_set(void* p, int key, float v) {
    if (!std::isfinite(v)) return;
    auto& h=*static_cast<LoopmotherHandle*>(p); constexpr int feet[]={32,16,8,4,2};
    switch(key) {
        case 0: h.synth.setOsc1Waveform(static_cast<loop2::SynthEngine::Waveform>(static_cast<int>(v)+1)); break;
        case 1: h.synth.setOsc2Waveform(static_cast<loop2::SynthEngine::Waveform>(static_cast<int>(v)+1)); break;
        case 2: h.synth.setOsc1Octave(feet[std::clamp(static_cast<int>(v),0,4)]); break;
        case 3: h.synth.setOsc2Octave(feet[std::clamp(static_cast<int>(v),0,4)]); break;
        case 4: h.synth.setOsc2Detune(v); break;
        case 5: h.synth.setOsc1Level(v); break;
        case 6: h.synth.setOsc2Level(v); break;
        case 7: h.synth.setNoiseLevel(v); break;
        case 8: h.synth.setCutoff(v); break;
        case 9: h.synth.setResonance(v); break;
        case 10: h.synth.setEnvelopeAmount(v); break;
        case 11: h.synth.setKeyboardTracking(v); break;
        case 12: h.synth.setLfoRate(v); break;
        case 13: h.synth.setLfoWaveform(static_cast<loop2::SynthEngine::Waveform>(static_cast<int>(v)+1)); break;
        case 14: h.synth.setLfoPitchAmount(v); break;
        case 15: h.synth.setLfoCutoffAmount(v); break;
        case 16: h.synth.setAttack(v); break;
        case 17: h.synth.setDecay(v); break;
        case 18: h.synth.setSustain(v); break;
        case 19: h.synth.setRelease(v); break;
        case 20: h.synth.setGlide(v); break;
        case 21: h.synth.setVcaMode(static_cast<loop2::SynthEngine::VcaMode>(static_cast<int>(v)+1)); break;
        case 22: h.synth.setPolyMode(v > 0.5f); break;
        case 23: h.synth.setReverbMix(v); break;
        case 24: h.synth.setVolume(v); break;
        case 25: h.synth.setInstrumentLevel(v); break;
    }
}
// in: optional interleaved stereo Instrument In block of the same length.
int lm_render_input(void* p,const float* in,float* out,int frames,double rate) {
    if (!p || !out || frames<1 || frames>8192 || !std::isfinite(rate) || rate<8000 || rate>192000) return 0;
    try {
        auto& h=*static_cast<LoopmotherHandle*>(p);
        if (h.rate!=rate) { h.synth.prepare(rate);h.rate=rate; }
        h.buffer.setSize(2,frames,false,false,true);h.buffer.clear();
        h.synth.render(h.buffer,0,frames,in);
        for (int i=0;i<frames;++i) for (int c=0;c<2;++c) out[i*2+c]=h.buffer.getSample(c,i);
        return 1;
    } catch (...) { std::fill(out,out+frames*2,0);return 0; }
}
int lm_render(void* p,float* out,int frames,double rate) { return lm_render_input(p,nullptr,out,frames,rate); }
}

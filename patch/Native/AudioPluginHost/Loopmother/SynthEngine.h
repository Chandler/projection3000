#pragma once
#include <juce_audio_basics/juce_audio_basics.h>
#include <array>
#include <atomic>
#include <vector>
#include "RealtimeQueue.h"

namespace loop2
{
class SynthEngine final
{
public:
    enum class Waveform { sine = 1, saw, square, triangle, pulse };
    enum class ArpDirection { up = 1, down, asPlayed };
    enum class VcaMode { envelope = 1, drone };

    void prepare(double sampleRate);
    void setTempo(double bpm);
    void noteOn(int midiNote, float velocity, int sampleOffset = 0);
    void noteOff(int midiNote, int sampleOffset = 0);
    void allNotesOff();
    bool isNoteHeld(int midiNote) const;
    void toggleArpNote(int midiNote, float velocity);
    void clearArpNotes();
    std::vector<int> getHeldNotes() const;
    int getActiveArpNote() const;
    void setEnabled(bool shouldEnable);
    void setWaveform(Waveform waveform);
    void setOsc1Waveform(Waveform waveform);
    void setOsc2Waveform(Waveform waveform);
    void setOsc1Octave(int octaveFeet);
    void setOsc2Octave(int octaveFeet);
    void setOsc2Detune(float cents);
    void setOsc1Level(float gain);
    void setOsc2Level(float gain);
    void setNoiseLevel(float gain);
    void setInstrumentLevel(float gain);
    void setCutoff(float hz);
    void setResonance(float amount);
    void setEnvelopeAmount(float amount);
    void setKeyboardTracking(float amount);
    void setLfoRate(float hz);
    void setLfoWaveform(Waveform waveform);
    void setLfoPitchAmount(float semitones);
    void setLfoCutoffAmount(float amount);
    void setAttack(float seconds);
    void setDecay(float seconds);
    void setSustain(float level);
    void setRelease(float seconds);
    void setGlide(float seconds);
    void setVcaMode(VcaMode mode);
    void setPolyMode(bool shouldBePoly);
    void setReverbMix(float mix);
    void setVolume(float gain);
    void setArpEnabled(bool shouldEnable);
    void setArpRateDivisor(float divisor);
    void setArpOctaves(int octaves);
    void setArpDirection(ArpDirection direction);
    void setTransportPlaying(bool shouldPlay);
    // instrument: optional interleaved stereo input (numSamples frames) summed
    // into the mixer ahead of the filter, like the Grandmother's Instrument In.
    void render(juce::AudioBuffer<float>& buffer, int startSample, int numSamples, const float* instrument = nullptr);

private:
    struct Voice
    {
        void start(int midiNote, float velocity, double sampleRate, double startFrequency, float glideTimeSeconds);
        void legato(int midiNote, float glideTimeSeconds);
        void release();
        float render(Waveform osc1Waveform,
                     Waveform osc2Waveform,
                     float osc1OctaveMultiplier,
                     float osc2OctaveMultiplier,
                     float osc2DetuneMultiplier,
                     float osc1Gain,
                     float osc2Gain,
                     float noiseGain,
                     float attackTime,
                     float decayTime,
                     float sustainAmount,
                     float releaseTime,
                     float lfoPitchSemitones,
                     bool droneMode,
                     float& envelopeOut,
                     float& noteFrequencyOut);

        int note = -1;
        float velocity = 0.0f;
        double phase1 = 0.0;
        double phase2 = 0.0;
        double currentFrequency = 440.0;
        double targetFrequency = 440.0;
        float glideCoefficient = 1.0f;
        float envelope = 0.0f;
        bool decaying = false;
        bool active = false;
        bool releasing = false;
        double sampleRate = 44100.0;
        uint32_t noiseState = 0x12345678;
    };

    enum class NoteAction { on, off, toggle };
    struct NoteCommand { NoteAction action; int note; float velocity; uint64_t epoch; int sampleOffset; };
    RealtimeQueue<NoteCommand, 512> commands;
    std::atomic<uint64_t> resetEpoch { 0 };
    uint64_t appliedEpoch = 0;
    std::array<std::atomic<uint64_t>, 2> heldSnapshot { uint64_t{0}, uint64_t{0} };
    bool appliedArp = false, appliedPoly = true, appliedTransport = false;
    int appliedOctaves = 1, appliedDirection = static_cast<int>(ArpDirection::up);
    void enqueue(NoteAction action, int note, float velocity = 0.0f, int sampleOffset = 0);
    void consumeCommands(int numSamples);
    void applyCommand(const NoteCommand& command);
    std::array<NoteCommand, 512> blockCommands {};
    int blockCommandCount = 0;
    void publishHeldNotes();
    void resetVoices();
    void applyNoteOn(int midiNote, float velocity);
    void applyNoteOff(int midiNote);
    void applyToggleArpNote(int midiNote, float velocity);
    std::array<Voice, 8> voices;
    std::vector<int> heldNotes;
    std::vector<int> arpNotes;
    double sampleRate = 44100.0;
    std::atomic<bool> enabled { true };
    std::atomic<int> osc1Waveform { static_cast<int>(Waveform::saw) };
    std::atomic<int> osc2Waveform { static_cast<int>(Waveform::square) };
    std::atomic<int> osc1OctaveFeet { 8 };
    std::atomic<int> osc2OctaveFeet { 8 };
    std::atomic<float> osc2DetuneCents { -7.0f };
    std::atomic<float> osc1Level { 0.82f };
    std::atomic<float> osc2Level { 0.58f };
    std::atomic<float> noiseLevel { 0.02f };
    std::atomic<float> instrumentLevel { 1.0f };
    std::atomic<bool> arpEnabled { false };
    std::atomic<bool> transportPlaying { false };
    std::atomic<float> arpRateDivisor { 16.0f };
    std::atomic<int> arpOctaves { 1 };
    std::atomic<int> arpDirection { static_cast<int>(ArpDirection::up) };
    std::atomic<double> tempoBpm { 132.0 };
    std::atomic<float> cutoffHz { 3500.0f };
    std::atomic<float> resonance { 0.22f };
    std::atomic<float> envelopeAmount { 0.36f };
    std::atomic<float> keyboardTracking { 0.35f };
    std::atomic<float> lfoRateHz { 4.2f };
    std::atomic<int> lfoWaveform { static_cast<int>(Waveform::sine) };
    std::atomic<float> lfoPitchAmount { 0.02f };
    std::atomic<float> lfoCutoffAmount { 0.10f };
    std::atomic<float> attackSeconds { 0.01f };
    std::atomic<float> decaySeconds { 0.12f };
    std::atomic<float> sustainLevel { 0.75f };
    std::atomic<float> releaseSeconds { 0.18f };
    std::atomic<float> glideSeconds { 0.0f };
    std::atomic<int> vcaMode { static_cast<int>(VcaMode::envelope) };
    std::atomic<bool> polyMode { true };
    std::atomic<float> reverbMix { 0.12f };
    std::atomic<float> volume { 0.35f };
    std::atomic<int> activeArpNote { -1 };
    float smoothedCutoff = 3500.0f;
    float filterL1 = 0.0f;
    float filterL2 = 0.0f;
    float filterL3 = 0.0f;
    float filterL4 = 0.0f;
    float filterR1 = 0.0f;
    float filterR2 = 0.0f;
    float filterR3 = 0.0f;
    float filterR4 = 0.0f;
    float lfoPhase = 0.0f;
    std::array<std::vector<float>, 3> springBuffers;
    std::array<int, 3> springPositions {};
    std::array<float, 3> springDamping {};
    double lastNoteFrequency = 261.625565;
    int arpIndex = 0;
    int arpSamplesUntilNext = 0;
    void rebuildArpNotes();
};

}

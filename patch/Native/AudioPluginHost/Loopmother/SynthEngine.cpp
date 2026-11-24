#include "SynthEngine.h"
#include "SynthTuning.h"
#include <algorithm>
#include <cmath>

namespace loop2
{
namespace
{
    // PolyBLEP residual: smooths the discontinuities of saw/square/pulse edges
    // so they do not alias. phase and increment are normalized (0..1 per cycle).
    float polyBlep(double phase, double increment)
    {
        if (increment <= 0.0)
            return 0.0f;

        if (phase < increment)
        {
            const auto x = phase / increment;
            return static_cast<float>(x + x - x * x - 1.0);
        }

        if (phase > 1.0 - increment)
        {
            const auto x = (phase - 1.0) / increment;
            return static_cast<float>(x * x + x + x + 1.0);
        }

        return 0.0f;
    }

    float waveformSample(int waveform, double phase, double increment)
    {
        switch (waveform)
        {
            case 1: // sine
                return std::sin(static_cast<float>(phase * juce::MathConstants<double>::twoPi));
            case 3: // square
            {
                auto value = phase < 0.5 ? 1.0f : -1.0f;
                value += polyBlep(phase, increment);
                value -= polyBlep(std::fmod(phase + 0.5, 1.0), increment);
                return value;
            }
            case 4: // triangle
                return static_cast<float>(1.0 - 4.0 * std::abs(phase - 0.5));
            case 5: // pulse (25% width, like a narrow Moog pulse)
            {
                constexpr auto width = 0.25;
                auto value = phase < width ? 1.0f : -1.0f;
                value += polyBlep(phase, increment);
                value -= polyBlep(std::fmod(phase + 1.0 - width, 1.0), increment);
                return (value - static_cast<float>(2.0 * width - 1.0)) * 0.8f;
            }
            case 2: // saw
            default:
            {
                auto value = static_cast<float>(phase * 2.0 - 1.0);
                value -= polyBlep(phase, increment);
                return value;
            }
        }
    }

    float octaveMultiplierForFeet(int feet)
    {
        switch (feet)
        {
            case 32: return 0.25f;
            case 16: return 0.5f;
            case 4: return 2.0f;
            case 2: return 4.0f;
            case 8:
            default: return 1.0f;
        }
    }

}

void SynthEngine::Voice::start(int midiNote, float newVelocity, double newSampleRate, double startFrequency, float glideTimeSeconds)
{
    note = midiNote;
    velocity = juce::jlimit(0.0f, 1.0f, newVelocity);
    sampleRate = newSampleRate;
    targetFrequency = juce::MidiMessage::getMidiNoteInHertz(midiNote);
    currentFrequency = glideTimeSeconds > 0.001f ? juce::jlimit(12.0, 18000.0, startFrequency) : targetFrequency;
    glideCoefficient = glideTimeSeconds > 0.001f
        ? 1.0f - std::exp(-1.0f / (glideTimeSeconds * static_cast<float>(sampleRate)))
        : 1.0f;
    // The envelope retriggers from its current level (like an analog ADSR)
    // so fast retriggers do not click.
    decaying = false;
    active = true;
    releasing = false;
    noiseState = 0x12345678u + static_cast<uint32_t>(midiNote) * 2654435761u;
}

void SynthEngine::Voice::legato(int midiNote, float glideTimeSeconds)
{
    note = midiNote;
    targetFrequency = juce::MidiMessage::getMidiNoteInHertz(midiNote);
    glideCoefficient = glideTimeSeconds > 0.001f
        ? 1.0f - std::exp(-1.0f / (glideTimeSeconds * static_cast<float>(sampleRate)))
        : 1.0f;
    releasing = false;
}

void SynthEngine::Voice::release()
{
    releasing = true;
}

float SynthEngine::Voice::render(Waveform osc1WaveformIn,
                                                Waveform osc2WaveformIn,
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
                                                float& noteFrequencyOut)
{
    envelopeOut = 0.0f;
    noteFrequencyOut = 0.0f;
    if (! active)
        return 0.0f;

    const auto attackStep = 1.0f / juce::jmax(1.0f, attackTime * static_cast<float>(sampleRate));
    const auto decayStep = 1.0f / juce::jmax(1.0f, decayTime * static_cast<float>(sampleRate));
    const auto releaseStep = 1.0f / juce::jmax(1.0f, releaseTime * static_cast<float>(sampleRate));

    if (droneMode)
    {
        envelope = 1.0f;
    }
    else if (releasing)
    {
        envelope -= releaseStep;
        if (envelope <= 0.0f)
        {
            active = false;
            envelope = 0.0f;
            return 0.0f;
        }
    }
    else
    {
        if (! decaying)
        {
            envelope = juce::jmin(1.0f, envelope + attackStep);
            if (envelope >= 1.0f)
                decaying = true;
        }
        else if (envelope > sustainAmount)
        {
            envelope = juce::jmax(sustainAmount, envelope - decayStep);
        }
    }

    currentFrequency += (targetFrequency - currentFrequency) * glideCoefficient;
    const auto pitchMultiplier = std::pow(2.0, static_cast<double>(lfoPitchSemitones) / 12.0);
    const auto osc1Frequency = currentFrequency * static_cast<double>(osc1OctaveMultiplier) * pitchMultiplier;
    const auto osc2Frequency = currentFrequency * static_cast<double>(osc2OctaveMultiplier) * static_cast<double>(osc2DetuneMultiplier) * pitchMultiplier;

    noiseState = noiseState * 1664525u + 1013904223u;
    const auto noise = (static_cast<float>((noiseState >> 9) & 0x7fffff) / 4194304.0f) - 1.0f;

    const auto increment1 = juce::jlimit(0.0, 0.5, osc1Frequency / sampleRate);
    const auto increment2 = juce::jlimit(0.0, 0.5, osc2Frequency / sampleRate);
    const auto sample = waveformSample(static_cast<int>(osc1WaveformIn), phase1, increment1) * osc1Gain
        + waveformSample(static_cast<int>(osc2WaveformIn), phase2, increment2) * osc2Gain
        + noise * noiseGain;

    phase1 += increment1;
    phase2 += increment2;
    while (phase1 >= 1.0)
        phase1 -= 1.0;
    while (phase2 >= 1.0)
        phase2 -= 1.0;

    envelopeOut = envelope;
    noteFrequencyOut = static_cast<float>(currentFrequency);
    return std::tanh(sample * 0.74f) * envelope * velocity;
}

void SynthEngine::prepare(double newSampleRate)
{
    sampleRate = newSampleRate > 0.0 ? newSampleRate : 44100.0;
    filterL1 = filterL2 = filterL3 = filterL4 = 0.0f;
    filterR1 = filterR2 = filterR3 = filterR4 = 0.0f;
    lfoPhase = 0.0f;
    smoothedCutoff = cutoffHz.load();
    arpSamplesUntilNext = 0;

    constexpr std::array<double, 3> springDelaysSeconds { 0.0297, 0.0371, 0.0434 };
    for (size_t i = 0; i < springBuffers.size(); ++i)
    {
        springBuffers[i].assign(static_cast<size_t>(juce::jmax(1, juce::roundToInt(sampleRate * springDelaysSeconds[i]))), 0.0f);
        springPositions[i] = 0;
        springDamping[i] = 0.0f;
    }

    heldNotes.reserve(128);
    arpNotes.reserve(512);
    resetVoices();
    publishHeldNotes();
}

void SynthEngine::setTempo(double newBpm)
{
    tempoBpm.store(juce::jlimit(20.0, 300.0, newBpm));
}

void SynthEngine::applyNoteOn(int midiNote, float velocity)
{
    if (! enabled.load())
        return;

    if (arpEnabled.load())
    {
        heldNotes.erase(std::remove(heldNotes.begin(), heldNotes.end(), midiNote), heldNotes.end());
        heldNotes.push_back(midiNote);
        rebuildArpNotes();
        return;
    }

    heldNotes.erase(std::remove(heldNotes.begin(), heldNotes.end(), midiNote), heldNotes.end());
    heldNotes.push_back(midiNote);

    if (polyMode.load())
    {
        // Paraphonic: free voice if available, otherwise steal the quietest.
        Voice* chosen = nullptr;
        for (auto& voice : voices)
        {
            if (! voice.active)
            {
                chosen = &voice;
                break;
            }
        }
        if (chosen == nullptr)
        {
            chosen = &voices[0];
            for (auto& voice : voices)
                if (voice.envelope < chosen->envelope)
                    chosen = &voice;
        }
        chosen->start(midiNote, velocity, sampleRate, lastNoteFrequency, glideSeconds.load());
        lastNoteFrequency = juce::MidiMessage::getMidiNoteInHertz(midiNote);
        return;
    }

    // Monophonic, last-note priority. A new note while another is held plays
    // legato (glide, no envelope retrigger), like the hardware.
    auto& voice = voices[0];
    for (size_t i = 1; i < voices.size(); ++i)
        if (voices[i].active)
            voices[i].release();

    if (voice.active && ! voice.releasing && heldNotes.size() > 1)
        voice.legato(midiNote, glideSeconds.load());
    else
        voice.start(midiNote, velocity, sampleRate, lastNoteFrequency, glideSeconds.load());

    lastNoteFrequency = juce::MidiMessage::getMidiNoteInHertz(midiNote);
}

void SynthEngine::applyNoteOff(int midiNote)
{
    if (arpEnabled.load())
        return;

    heldNotes.erase(std::remove(heldNotes.begin(), heldNotes.end(), midiNote), heldNotes.end());
    arpNotes.erase(std::remove(arpNotes.begin(), arpNotes.end(), midiNote), arpNotes.end());

    if (polyMode.load())
    {
        for (auto& voice : voices)
            if (voice.active && voice.note == midiNote)
                voice.release();

        if (activeArpNote.load() == midiNote)
            activeArpNote.store(-1);
        return;
    }

    auto& voice = voices[0];
    if (voice.active && voice.note == midiNote)
    {
        // Last-note priority: fall back to the most recent note still held.
        if (! heldNotes.empty())
        {
            voice.legato(heldNotes.back(), glideSeconds.load());
            lastNoteFrequency = juce::MidiMessage::getMidiNoteInHertz(heldNotes.back());
        }
        else
        {
            voice.release();
        }
    }

    for (size_t i = 1; i < voices.size(); ++i)
        if (voices[i].active && voices[i].note == midiNote)
            voices[i].release();

    if (activeArpNote.load() == midiNote)
        activeArpNote.store(-1);
}

void SynthEngine::resetVoices()
{
    for (auto& voice : voices)
        voice.active = false;
    heldNotes.clear();
    arpNotes.clear();
    arpIndex = 0;
    arpSamplesUntilNext = 0;
    activeArpNote.store(-1);
}

bool SynthEngine::isNoteHeld(int midiNote) const
{
    return midiNote >= 0 && midiNote < 128
        && (heldSnapshot[static_cast<size_t>(midiNote / 64)].load() & (uint64_t{1} << (midiNote % 64))) != 0;
}

void SynthEngine::applyToggleArpNote(int midiNote, float velocity)
{
    if (! enabled.load())
        return;

    const auto existing = std::find(heldNotes.begin(), heldNotes.end(), midiNote);
    if (existing != heldNotes.end())
    {
        heldNotes.erase(existing);
        for (auto& voice : voices)
            if (voice.active && voice.note == midiNote)
                voice.release();
        if (activeArpNote.load() == midiNote)
            activeArpNote.store(-1);
    }
    else
    {
        heldNotes.push_back(midiNote);
        if (! arpEnabled.load())
        {
            voices[0].start(midiNote, velocity, sampleRate, lastNoteFrequency, glideSeconds.load());
            lastNoteFrequency = juce::MidiMessage::getMidiNoteInHertz(midiNote);
        }
    }

    rebuildArpNotes();
    arpSamplesUntilNext = 0;
}

void SynthEngine::clearArpNotes() { allNotesOff(); }

std::vector<int> SynthEngine::getHeldNotes() const
{
    std::vector<int> result;
    for (int group = 0; group < 2; ++group)
    {
        const auto notes = heldSnapshot[static_cast<size_t>(group)].load();
        for (int bit = 0; bit < 64; ++bit)
            if ((notes & (uint64_t{1} << bit)) != 0) result.push_back(group * 64 + bit);
    }
    return result;
}

int SynthEngine::getActiveArpNote() const
{
    return activeArpNote.load();
}

void SynthEngine::setEnabled(bool shouldEnable) { enabled.store(shouldEnable); if (! shouldEnable) allNotesOff(); }
void SynthEngine::setWaveform(Waveform newWaveform) { setOsc1Waveform(newWaveform); setOsc2Waveform(newWaveform); }
void SynthEngine::setOsc1Waveform(Waveform newWaveform) { osc1Waveform.store(static_cast<int>(newWaveform)); }
void SynthEngine::setOsc2Waveform(Waveform newWaveform) { osc2Waveform.store(static_cast<int>(newWaveform)); }
void SynthEngine::setOsc1Octave(int octaveFeet) { osc1OctaveFeet.store(octaveFeet); }
void SynthEngine::setOsc2Octave(int octaveFeet) { osc2OctaveFeet.store(octaveFeet); }
void SynthEngine::setOsc2Detune(float cents) { osc2DetuneCents.store(juce::jlimit(-50.0f, 50.0f, cents)); }
void SynthEngine::setOsc1Level(float gain) { osc1Level.store(juce::jlimit(0.0f, 1.25f, gain)); }
void SynthEngine::setOsc2Level(float gain) { osc2Level.store(juce::jlimit(0.0f, 1.25f, gain)); }
void SynthEngine::setNoiseLevel(float gain) { noiseLevel.store(juce::jlimit(0.0f, 1.0f, gain)); }
void SynthEngine::setInstrumentLevel(float gain) { instrumentLevel.store(juce::jlimit(0.0f, 2.0f, gain)); }
void SynthEngine::setLfoWaveform(Waveform waveform) { lfoWaveform.store(static_cast<int>(waveform)); }

void SynthEngine::setPolyMode(bool value) { polyMode.store(value); }
void SynthEngine::setCutoff(float hz) { cutoffHz.store(juce::jlimit(50.0f, 18000.0f, hz)); }
void SynthEngine::setResonance(float amount) { resonance.store(juce::jlimit(0.0f, 0.92f, amount)); }
void SynthEngine::setEnvelopeAmount(float amount) { envelopeAmount.store(juce::jlimit(-1.0f, 1.0f, amount)); }
void SynthEngine::setKeyboardTracking(float amount) { keyboardTracking.store(juce::jlimit(0.0f, 1.0f, amount)); }
void SynthEngine::setLfoRate(float hz) { lfoRateHz.store(juce::jlimit(0.05f, 24.0f, hz)); }
void SynthEngine::setLfoPitchAmount(float semitones) { lfoPitchAmount.store(juce::jlimit(-12.0f, 12.0f, semitones)); }
void SynthEngine::setLfoCutoffAmount(float amount) { lfoCutoffAmount.store(juce::jlimit(-1.0f, 1.0f, amount)); }
void SynthEngine::setAttack(float seconds) { attackSeconds.store(juce::jlimit(0.001f, 1.5f, seconds)); }
void SynthEngine::setDecay(float seconds) { decaySeconds.store(juce::jlimit(0.01f, 3.0f, seconds)); }
void SynthEngine::setSustain(float level) { sustainLevel.store(juce::jlimit(0.0f, 1.0f, level)); }
void SynthEngine::setRelease(float seconds) { releaseSeconds.store(juce::jlimit(0.01f, 3.0f, seconds)); }
void SynthEngine::setGlide(float seconds) { glideSeconds.store(juce::jlimit(0.0f, 2.0f, seconds)); }
void SynthEngine::setVcaMode(VcaMode mode) { vcaMode.store(static_cast<int>(mode)); }
void SynthEngine::setReverbMix(float mix) { reverbMix.store(juce::jlimit(0.0f, 0.85f, mix)); }
void SynthEngine::setVolume(float gain) { volume.store(juce::jlimit(0.0f, 1.0f, gain)); }
void SynthEngine::setArpEnabled(bool value) { arpEnabled.store(value); }
void SynthEngine::setArpRateDivisor(float value) { arpRateDivisor.store(juce::jlimit(4.0f, 128.0f, value)); }
void SynthEngine::setArpOctaves(int value) { arpOctaves.store(juce::jlimit(1, 4, value)); }
void SynthEngine::setArpDirection(ArpDirection value) { arpDirection.store(static_cast<int>(value)); }
void SynthEngine::setTransportPlaying(bool value) { transportPlaying.store(value); }

void SynthEngine::enqueue(NoteAction action, int note, float velocity, int sampleOffset)
{
    if (note < 0 || note > 127) return;
    if (! commands.push({ action, note, velocity, resetEpoch.load(), juce::jmax(0, sampleOffset) }))
        allNotesOff(); // Overflow invalidates old events, including delayed note-ons.
}
void SynthEngine::noteOn(int note, float velocity, int offset) { enqueue(NoteAction::on, note, velocity, offset); }
void SynthEngine::noteOff(int note, int offset) { enqueue(NoteAction::off, note, 0.0f, offset); }
void SynthEngine::toggleArpNote(int note, float velocity) { enqueue(NoteAction::toggle, note, velocity); }
void SynthEngine::allNotesOff() { resetEpoch.fetch_add(1); }

void SynthEngine::publishHeldNotes()
{
    std::array<uint64_t, 2> masks {};
    for (const auto note : heldNotes)
        masks[static_cast<size_t>(note / 64)] |= uint64_t{1} << (note % 64);
    for (size_t i = 0; i < masks.size(); ++i) heldSnapshot[i].store(masks[i]);
}

void SynthEngine::consumeCommands(int numSamples)
{
    const auto newArp = arpEnabled.load();
    const auto newPoly = polyMode.load();
    const auto newOctaves = arpOctaves.load();
    const auto newDirection = arpDirection.load();
    const auto newTransport = transportPlaying.load();
    if (newArp != appliedArp)
    {
        if (! newArp) resetVoices();
        else for (auto& voice : voices) voice.release();
        arpSamplesUntilNext = 0;
    }
    if (! newPoly && appliedPoly)
        for (size_t i = 1; i < voices.size(); ++i) voices[i].release();
    if (newArp != appliedArp || newOctaves != appliedOctaves || newDirection != appliedDirection)
    {
        rebuildArpNotes();
        arpIndex = 0;
        arpSamplesUntilNext = 0;
    }
    if (newTransport != appliedTransport)
    {
        arpSamplesUntilNext = 0;
        activeArpNote.store(-1);
        if (! newTransport && newArp)
            for (auto& voice : voices) voice.active = false;
    }
    appliedArp = newArp; appliedPoly = newPoly;
    appliedOctaves = newOctaves; appliedDirection = newDirection; appliedTransport = newTransport;

    auto applyReset = [this]
    {
        const auto epoch = resetEpoch.load();
        if (epoch != appliedEpoch) { resetVoices(); appliedEpoch = epoch; }
    };
    applyReset();
    blockCommandCount = 0;
    NoteCommand command {};
    for (int count = 0; count < 512 && commands.pop(command); ++count)
    {
        applyReset();
        if (command.epoch != appliedEpoch) continue;
        command.sampleOffset = juce::jlimit(0, juce::jmax(0, numSamples - 1), command.sampleOffset);
        // Stable bounded insertion: preserve note-on/off ordering at the same offset.
        int index = blockCommandCount++;
        while (index > 0 && blockCommands[static_cast<size_t>(index - 1)].sampleOffset > command.sampleOffset)
        {
            blockCommands[static_cast<size_t>(index)] = blockCommands[static_cast<size_t>(index - 1)];
            --index;
        }
        blockCommands[static_cast<size_t>(index)] = command;
    }
    applyReset();
}

void SynthEngine::applyCommand(const NoteCommand& command)
{
    const auto epoch = resetEpoch.load();
    if (epoch != appliedEpoch) { resetVoices(); appliedEpoch = epoch; }
    if (command.epoch != appliedEpoch) return;
    switch (command.action)
    {
        case NoteAction::on: applyNoteOn(command.note, command.velocity); break;
        case NoteAction::off: applyNoteOff(command.note); break;
        case NoteAction::toggle: applyToggleArpNote(command.note, command.velocity); break;
    }
}

void SynthEngine::rebuildArpNotes()
{
    arpNotes.clear();
    const auto octaveCount = juce::jlimit(1, 4, arpOctaves.load());
    for (int octave = 0; octave < octaveCount; ++octave)
    {
        for (const auto note : heldNotes)
        {
            const auto expandedNote = note + octave * 12;
            if (expandedNote <= 127)
                arpNotes.push_back(expandedNote);
        }
    }

    const auto direction = static_cast<ArpDirection>(arpDirection.load());
    if (direction == ArpDirection::up)
        std::sort(arpNotes.begin(), arpNotes.end());
    else if (direction == ArpDirection::down)
        std::sort(arpNotes.begin(), arpNotes.end(), std::greater<int>());

    if (arpIndex >= static_cast<int>(arpNotes.size()))
        arpIndex = 0;
}

void SynthEngine::render(juce::AudioBuffer<float>& buffer, int startSample, int numSamples, const float* instrument)
{
    const juce::ScopedNoDenormals noDenormals;
    buffer.clear(startSample, numSamples);
    consumeCommands(numSamples);

    const auto attack = attackSeconds.load();
    const auto decay = decaySeconds.load();
    const auto sustain = sustainLevel.load();
    const auto release = releaseSeconds.load();
    const auto gain = volume.load();
    const auto currentArpEnabled = arpEnabled.load();
    const auto canRunArp = currentArpEnabled && transportPlaying.load();
    // Block-rate controls: avoid recomputing octave/detune for every sample.
    const auto osc1Mult = octaveMultiplierForFeet(osc1OctaveFeet.load());
    const auto osc2Mult = octaveMultiplierForFeet(osc2OctaveFeet.load());
    const auto osc2Detune = std::pow(2.0f, osc2DetuneCents.load() / 1200.0f);
    const auto wave1 = static_cast<Waveform>(osc1Waveform.load());
    const auto wave2 = static_cast<Waveform>(osc2Waveform.load());
    const auto osc1Gain = osc1Level.load();
    const auto osc2Gain = osc2Level.load();
    const auto noiseGain = noiseLevel.load();
    const auto instrumentGain = instrumentLevel.load();
    const auto droneMode = static_cast<VcaMode>(vcaMode.load()) == VcaMode::drone;
    const auto baseCutoff = cutoffHz.load();
    const auto tracking = keyboardTracking.load();
    const auto filterEnvelope = envelopeAmount.load();
    const auto filterModulation = lfoCutoffAmount.load();
    const auto filterResonance = resonance.load();
    const auto cutoffSmoothing = 1.0f - std::exp(-1.0f / (0.005f * static_cast<float>(sampleRate)));

    auto* left = buffer.getWritePointer(0, startSample);
    auto* right = buffer.getNumChannels() > 1 ? buffer.getWritePointer(1, startSample) : left;

    if (currentArpEnabled && ! canRunArp)
    {
        for (auto& voice : voices)
            voice.active = false;
        activeArpNote.store(-1);
    }

    int commandIndex = 0;
    const bool muted = ! enabled.load() || (currentArpEnabled && ! canRunArp);
    // A drone needs no key: with nothing sounding, hold the last note played
    // (middle C before any note arrives), as the hardware does with its VCA open.
    if (droneMode && ! muted && std::none_of(voices.begin(), voices.end(), [](const Voice& voice) { return voice.active; }))
    {
        const auto note = juce::jlimit(0, 127, juce::roundToInt(69.0 + 12.0 * std::log2(lastNoteFrequency / 440.0)));
        voices[0].start(note, 1.0f, sampleRate, lastNoteFrequency, 0.0f);
    }
    for (int sample = 0; sample < numSamples; ++sample)
    {
        while (commandIndex < blockCommandCount && blockCommands[static_cast<size_t>(commandIndex)].sampleOffset <= sample)
            applyCommand(blockCommands[static_cast<size_t>(commandIndex++)]);
        if (muted) continue;
        if (canRunArp && ! arpNotes.empty())
        {
            if (arpSamplesUntilNext <= 0)
            {
                for (auto& voice : voices)
                    voice.release();

                if (arpIndex >= static_cast<int>(arpNotes.size()))
                    arpIndex = 0;

                const auto note = arpNotes[static_cast<size_t>(arpIndex)];
                voices[0].envelope = 0.0f; // arp steps re-trigger from zero for articulation
                voices[0].start(note, 1.0f, sampleRate, lastNoteFrequency, glideSeconds.load());
                lastNoteFrequency = juce::MidiMessage::getMidiNoteInHertz(note);
                activeArpNote.store(note);
                ++arpIndex;

                const auto secondsPerBeat = 60.0 / juce::jlimit(20.0, 300.0, tempoBpm.load());
                const auto stepSeconds = secondsPerBeat * 4.0 / static_cast<double>(arpRateDivisor.load());
                arpSamplesUntilNext = juce::jmax(1, juce::roundToInt(stepSeconds * sampleRate));
            }

            --arpSamplesUntilNext;
        }

        const auto lfoT = lfoPhase / juce::MathConstants<float>::twoPi;
        float lfo;
        switch (static_cast<Waveform>(lfoWaveform.load()))
        {
            case Waveform::saw:      lfo = 1.0f - 2.0f * lfoT; break;             // falling
            case Waveform::square:   lfo = lfoT < 0.5f ? 1.0f : -1.0f; break;
            case Waveform::triangle: lfo = 1.0f - 4.0f * std::abs(lfoT - 0.5f); break;
            case Waveform::sine:
            default:                 lfo = std::sin(lfoPhase); break;
        }
        lfoPhase += juce::MathConstants<float>::twoPi * lfoRateHz.load() / static_cast<float>(sampleRate);
        if (lfoPhase >= juce::MathConstants<float>::twoPi)
            lfoPhase -= juce::MathConstants<float>::twoPi;

        float mixed = 0.0f;
        float envelopeSum = 0.0f;
        float noteFrequencySum = 0.0f;
        int activeCount = 0;
        for (auto& voice : voices)
        {
            float env = 0.0f;
            float noteHz = 0.0f;
            mixed += voice.render(wave1,
                                  wave2,
                                  osc1Mult,
                                  osc2Mult,
                                  osc2Detune,
                                  osc1Gain,
                                  osc2Gain,
                                  noiseGain,
                                  attack,
                                  decay,
                                  sustain,
                                  release,
                                  lfo * lfoPitchAmount.load(),
                                  droneMode,
                                  env,
                                  noteHz);
            if (env > 0.0f)
            {
                envelopeSum += env;
                noteFrequencySum += noteHz;
                ++activeCount;
            }
        }

        const auto envelope = activeCount > 0 ? envelopeSum / static_cast<float>(activeCount) : 0.0f;
        const auto noteHz = activeCount > 0 ? noteFrequencySum / static_cast<float>(activeCount) : 261.6256f;
        const auto envCutoff = filterEnvelope * envelope * 7600.0f;
        const auto keyCutoff = trackedCutoff(baseCutoff, noteHz, tracking);
        const auto lfoCutoff = lfo * filterModulation * 4200.0f;
        const auto targetCutoff = juce::jlimit(45.0f, juce::jmin(18000.0f, static_cast<float>(sampleRate) * 0.45f),
                                              keyCutoff + envCutoff + lfoCutoff);
        smoothedCutoff += cutoffSmoothing * (targetCutoff - smoothedCutoff);
        const auto cutoff = smoothedCutoff;
        const auto alpha = juce::jlimit(0.001f,
                                        0.96f,
                                        1.0f - std::exp(-2.0f * juce::MathConstants<float>::pi * cutoff / static_cast<float>(sampleRate)));
        const auto resonanceFeedback = filterResonance * 3.55f;

        // CP3-style mixer: gentle asymmetric clipping adds even harmonics
        // when the oscillator levels are pushed.
        mixed *= 0.42f;
        // Instrument In joins the oscillators in the mixer, so it is driven,
        // filtered and gated by the VCA with them. Its two channels keep
        // separate ladders; without it the synth stays mono.
        const auto instrumentVca = instrumentGain * (droneMode ? 1.0f : envelope);
        const auto mixedL = mixed + (instrument != nullptr ? instrument[sample * 2] * instrumentVca : 0.0f);
        const auto driven = std::tanh(mixedL + 0.10f * mixedL * mixedL);
        const auto input = std::tanh(driven - filterL4 * resonanceFeedback);
        filterL1 += alpha * (input - filterL1);
        filterL2 += alpha * (filterL1 - filterL2);
        filterL3 += alpha * (filterL2 - filterL3);
        filterL4 += alpha * (filterL3 - filterL4);

        // Compensate the passband loss a resonant ladder filter exhibits.
        const auto filteredL = filterL4 * (1.0f + filterResonance * 0.55f);
        auto filteredR = filteredL;
        if (instrument != nullptr)
        {
            const auto mixedR = mixed + instrument[sample * 2 + 1] * instrumentVca;
            const auto drivenR = std::tanh(mixedR + 0.10f * mixedR * mixedR);
            const auto inputR = std::tanh(drivenR - filterR4 * resonanceFeedback);
            filterR1 += alpha * (inputR - filterR1);
            filterR2 += alpha * (filterR1 - filterR2);
            filterR3 += alpha * (filterR2 - filterR3);
            filterR4 += alpha * (filterR3 - filterR4);
            filteredR = filterR4 * (1.0f + filterResonance * 0.55f);
        }
        const auto filtered = 0.5f * (filteredL + filteredR);

        // Spring-style reverb: three short feedback delay lines with damping,
        // tapped with different signs for a wide, boingy wet signal.
        float wetL = 0.0f;
        float wetR = 0.0f;
        constexpr std::array<float, 3> springFeedback { 0.66f, 0.61f, 0.57f };
        constexpr std::array<float, 3> springLeftTap { 0.9f, -0.6f, 0.45f };
        constexpr std::array<float, 3> springRightTap { -0.55f, 0.85f, 0.5f };
        for (size_t i = 0; i < springBuffers.size(); ++i)
        {
            auto& buffer = springBuffers[i];
            if (buffer.empty())
                continue;

            const auto read = buffer[static_cast<size_t>(springPositions[i])];
            springDamping[i] = springDamping[i] * 0.35f + read * 0.65f;
            buffer[static_cast<size_t>(springPositions[i])] = filtered * 0.55f + springDamping[i] * springFeedback[i];
            springPositions[i] = (springPositions[i] + 1) % static_cast<int>(buffer.size());
            wetL += read * springLeftTap[i];
            wetR += read * springRightTap[i];
        }

        const auto verb = reverbMix.load();
        const auto outL = juce::jlimit(-1.0f, 1.0f, filteredL * (1.0f - verb * 0.45f) + wetL * verb * 0.6f);
        const auto outR = juce::jlimit(-1.0f, 1.0f, filteredR * (1.0f - verb * 0.45f) + wetR * verb * 0.6f);
        left[sample] += outL * gain;
        right[sample] += outR * gain;
    }
    publishHeldNotes();
}

}

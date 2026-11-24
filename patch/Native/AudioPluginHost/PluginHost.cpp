#include <juce_audio_processors/juce_audio_processors.h>
#include <mutex>
#include <atomic>
#include <cstdlib>
using namespace juce;
namespace {
std::unique_ptr<ScopedJuceInitialiser_GUI> gui;
String lastError;
struct EditorWindow final : DocumentWindow {
    EditorWindow(AudioPluginInstance& p) : DocumentWindow(p.getName(), Colours::darkgrey, DocumentWindow::allButtons) {
        setUsingNativeTitleBar(true);
        auto* editor = p.createEditorAndMakeActive();
        if (editor == nullptr) editor = new GenericAudioProcessorEditor(p);
        setContentOwned(editor, true);
        setResizable(editor->isResizable(), false);
        centreWithSize(getWidth(), getHeight());
        setVisible(true);
    }
    void closeButtonPressed() override { setVisible(false); }
};
struct Host final : AudioProcessorListener {
    std::unique_ptr<AudioPluginInstance> plugin;
    std::unique_ptr<EditorWindow> window;
    std::recursive_mutex mutex;
    std::atomic<bool> dirty {true};
    AudioBuffer<float> buffer;
    MidiBuffer midi;
    double rate = 0;
    int capacity = 0;
    std::atomic<double> requestedRate {48000};
    void prepare() {
        const double requested=requestedRate.load();
        if (rate==requested) return;
        plugin->releaseResources();
        capacity=8192; rate=requested;
        plugin->setRateAndBufferSizeDetails(rate,capacity);
        plugin->prepareToPlay(rate,capacity);
        buffer.setSize(2,capacity);
    }
    Array<var> definitions;
    ~Host() { window.reset(); if (plugin) { plugin->removeListener(this); plugin->releaseResources(); } }
    void audioProcessorParameterChanged(AudioProcessor*, int, float) override { dirty.store(true); }
    void audioProcessorChanged(AudioProcessor*, const ChangeDetails&) override { dirty.store(true); }
    void audioProcessorParameterChangeGestureBegin(AudioProcessor*, int) override {}
    void audioProcessorParameterChangeGestureEnd(AudioProcessor*, int) override {}
};
var object() { return var(new DynamicObject()); }
void put(var& v, const Identifier& key, const var& value) { v.getDynamicObject()->setProperty(key, value); }
char* encode(const var& v) { return ::strdup(JSON::toString(v, true).toRawUTF8()); }
}
extern "C" {
const char* pp_error() { return lastError.toRawUTF8(); }
void pp_free(void* p) { std::free(p); }
void* pp_create(const char* path, const char* identifier) {
    try {
        if (!gui) gui = std::make_unique<ScopedJuceInitialiser_GUI>();
        VST3PluginFormat format;
        OwnedArray<PluginDescription> types;
        format.findAllTypesForFile(types, path);
        PluginDescription* selected = nullptr;
        for (auto* type : types) {
            if (type->isInstrument) continue;
            if (identifier && *identifier && type->createIdentifierString() != identifier) continue;
            selected = type; break;
        }
        if (!selected) { lastError = "No compatible VST3 audio effect found (check the plugin's architecture)."; return nullptr; }
        auto host = std::make_unique<Host>();
        host->plugin = format.createInstanceFromDescription(*selected, 48000, 480, lastError);
        if (!host->plugin) return nullptr;
        auto layout = host->plugin->getBusesLayout();
        for (int i=0; i<layout.inputBuses.size(); ++i) layout.inputBuses.getReference(i) = i==0 ? AudioChannelSet::stereo() : AudioChannelSet::disabled();
        for (int i=0; i<layout.outputBuses.size(); ++i) layout.outputBuses.getReference(i) = i==0 ? AudioChannelSet::stereo() : AudioChannelSet::disabled();
        if (!host->plugin->setBusesLayout(layout) || host->plugin->getTotalNumInputChannels()!=2 || host->plugin->getTotalNumOutputChannels()!=2) {
            lastError = "This node requires a stereo-in/stereo-out VST3 effect."; return nullptr;
        }
        host->plugin->addListener(host.get());
        host->prepare();
        return host.release();
    } catch (const std::exception& e) { lastError=e.what(); return nullptr; }
}
void pp_destroy(void* p) { delete static_cast<Host*>(p); }
int pp_dirty(void* p) { auto& h=*static_cast<Host*>(p); return h.dirty.load() || h.requestedRate.load()!=h.rate ? 1 : 0; }
// Main-thread calls. Never serialize state or construct editors on the audio queue.
char* pp_command(void* p, const char* request) {
    auto& h=*static_cast<Host*>(p);
    std::lock_guard<std::recursive_mutex> lock(h.mutex);
    try {
        h.prepare();
        const auto command=JSON::parse(request);
        const auto op=command["op"].toString();
        if (op=="editor") {
            if (!h.window) h.window=std::make_unique<EditorWindow>(*h.plugin);
            h.window->setVisible(true); h.window->toFront(true);
        } else if (op=="parse") {
            int index=command["index"];
            if (!isPositiveAndBelow(index,h.plugin->getParameters().size())) throw std::runtime_error("Unknown parameter");
            auto result=object(); put(result,"value",h.plugin->getParameters()[index]->getValueForText(command["text"].toString()));
            return encode(result);
        } else if (op=="restore") {
            MemoryBlock data;
            if (data.fromBase64Encoding(command["state"].toString()) && data.getSize())
                h.plugin->setStateInformation(data.getData(), (int)data.getSize());
            h.dirty.store(true);
        } else if (op=="set") {
            if (auto* values=command["values"].getArray()) for (const auto& item:*values) {
                int index=item["index"];
                if (!isPositiveAndBelow(index,h.plugin->getParameters().size())) continue;
                auto* parameter=h.plugin->getParameters()[index];
                auto value=jlimit(0.0f,1.0f,(float)item["value"]);
                if (std::abs(parameter->getValue()-value)<0.000001f) continue;
                parameter->beginChangeGesture(); parameter->setValueNotifyingHost(value); parameter->endChangeGesture();
            }
        }
        auto result=object();
        if (op=="snapshot" || op=="describe") {
            h.dirty.store(false);
            PluginDescription desc; h.plugin->fillInPluginDescription(desc);
            put(result,"name",desc.name); put(result,"identifier",desc.createIdentifierString());
            put(result,"manufacturer",desc.manufacturerName); put(result,"latency",h.plugin->getLatencySamples());
            Array<var> parameters;
            if (h.definitions.isEmpty()) {
            for (int i=0;i<h.plugin->getParameters().size();++i) {
                auto* param=h.plugin->getParameters()[i];
                auto entry=object();
                put(entry,"index",i);
                auto* hosted=dynamic_cast<HostedAudioProcessorParameter*>(param);
                put(entry,"key","plugin."+(hosted ? hosted->getParameterID():String(i)));
                put(entry,"name",param->getName(128)); put(entry,"value",param->getValue());
                put(entry,"initial",param->getDefaultValue()); put(entry,"text",param->getText(param->getValue(),128));
                put(entry,"unit",param->getLabel()); put(entry,"automatable",param->isAutomatable());
                const int steps=param->getNumSteps();
                bool discrete=param->isDiscrete() && steps>1 && steps<100000;
                put(entry,"steps",discrete ? steps : 0);
                put(entry,"bipolar",param->getText(0,128).getDoubleValue()<0 && param->getText(1,128).getDoubleValue()>=0);
                Array<var> choices;
                if (discrete && steps<=64) for(int s=0;s<steps;++s) choices.add(param->getText((float)s/(steps-1),128));
                const auto name=param->getName(128).toLowerCase();
                if (choices.isEmpty() && (name.endsWith("mode") || name=="color" || name=="algorithm")) {
                    StringArray labels;
                    for(int sample=0;sample<=1024;++sample) labels.addIfNotAlreadyThere(param->getText((float)sample/1024,128));
                    if(labels.size()>1 && labels.size()<=64) {
                        for(const auto& label:labels) choices.add(label);
                        put(entry,"steps",labels.size());
                    }
                }
                put(entry,"choices",choices); parameters.add(entry);
            }
            h.definitions=parameters;
            }
            parameters.clear();
            for (const auto& definition:h.definitions) {
                auto entry=var(definition.getDynamicObject()->clone().release());
                auto* parameter=h.plugin->getParameters()[(int)entry["index"]];
                put(entry,"value",parameter->getValue());
                put(entry,"text",parameter->getText(parameter->getValue(),128));
                parameters.add(entry);
            }
            put(result,"parameters",parameters);
            MemoryBlock state; h.plugin->getStateInformation(state); put(result,"state",state.toBase64Encoding());
        }
        put(result,"ok",true); return encode(result);
    } catch (const std::exception& e) { auto result=object(); put(result,"error",e.what()); return encode(result); }
}
// The graph is serial. UI operations may briefly hold the mutex; return dry audio then.
int pp_process(void* p, const float* input, float* output, int frames, double rate,
               const int* indices, const float* values, int count) {
    auto& h=*static_cast<Host*>(p);
    std::unique_lock<std::recursive_mutex> lock(h.mutex,std::try_to_lock);
    if (!lock.owns_lock()) return 1;
    try {
        ScopedNoDenormals noDenormals;
        if (h.rate!=rate || frames>h.capacity) {
            h.requestedRate.store(rate);
            return 2; // Message thread prepares the next format; audio bypasses meanwhile.
        }
        for (int i=0;i<count;++i) if (isPositiveAndBelow(indices[i],h.plugin->getParameters().size()))
            h.plugin->getParameters()[indices[i]]->setValue(jlimit(0.0f,1.0f,values[i]));
        h.buffer.setSize(2,frames,false,false,true);
        for(int i=0;i<frames;++i) { h.buffer.setSample(0,i,input[i*2]);h.buffer.setSample(1,i,input[i*2+1]); }
        h.midi.clear();
        h.plugin->processBlock(h.buffer,h.midi);
        for(int i=0;i<frames;++i) for(int c=0;c<2;++c) {
            auto v=h.buffer.getSample(c,i); output[i*2+c]=std::isfinite(v) ? v : 0.0f;
        }
        return 0;
    } catch (...) { return -1; }
}
}

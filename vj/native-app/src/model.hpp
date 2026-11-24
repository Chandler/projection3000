#pragma once
#include <nlohmann/json.hpp>
#include <filesystem>
#include <mutex>
#include <map>
#include <vector>
#include <chrono>
#include "media_library.hpp"
#include "live_sources.hpp"
#include "text_source.hpp"
#include "module_registry.hpp"
#include "frame_transport.hpp"
#include "calibration_model.hpp"
#include "ndi_clients.hpp"
#include <optional>
#include <array>
#include <atomic>
#include <memory>
#include <thread>
#include <condition_variable>
namespace vj {
using Json=nlohmann::json;
struct Reply {std::optional<uint64_t> committedRevision;int status;Json body;std::optional<std::string> rawBody;std::string contentType;std::map<std::string,std::string> headers;Reply(int status=200,Json body=Json(),std::optional<std::string> rawBody=std::nullopt,std::string contentType="application/json",std::map<std::string,std::string> headers={}):status(status),body(std::move(body)),rawBody(std::move(rawBody)),contentType(std::move(contentType)),headers(std::move(headers)) {}};
struct MediaHttpAsset;
class Model {
public:
    explicit Model(std::filesystem::path directory);
    ~Model();
    void setRestoreDevices(bool enabled) {restoreDevices_=enabled;}
    void setPlaybackRuntime(const Json& sources);
    Json playbackRuntime() const;
    void setPaletteSources(const Json& sources);
    Json paletteSources() const;
    void setPatchOutputs(Json sources);
    Json patchOutputs() const;
    Json patchReferences() const;
    void setPatchReferences(Json ids);
    void requestPatchPoster(const std::string& id);
    void setApiPort(unsigned short port) {apiPort_=port;}
    Reply request(const std::string& method,const std::string& path,const Json& body=Json::object());
    Json snapshot() const;
    Json midiSnapshot() const; // Control state only: no media resolution or composition derivation.
    std::optional<double> crossfadeValue(const std::string& bus) const;
    std::optional<double> hardwareFaderValue() const;
    bool receiveChannelFader(int channel,double value);
    std::array<double,8> hardwareChannelFaders() const;
    bool receivePatchAPC(int status,int number,int value);
    std::vector<std::array<int,3>> takePatchAPCMessages();
    bool patchAPCOwned() const { return patchAPCOwned_.load(); }
    void setPatchCrossfaderFollow(bool enabled) { patchCrossfaderFollow_.store(enabled); }
    void setPatchAPCOwned(bool enabled) { patchAPCOwned_.store(enabled); }
    void setPatchChannelFaderFollow(bool enabled) {patchChannelFaderFollow_.store(enabled);}
    std::shared_ptr<const Json> renderSnapshotShared() const;
    Json fixtureSnapshot() const;
    Json renderSnapshot() const; // Reuse stable derived state; API snapshots remain fresh.
    uint64_t revision() const;
    std::shared_ptr<const Json> presentationSnapshotShared() const;
    Json presentationSnapshot() const; // Last completed snapshot, never waits for render/I/O.
    FrameTransport& frames() {return frames_;}
    CalibrationModel& calibration() {return calibration_;}
    std::filesystem::path stateRoot() const {return directory_;}
    void setOutputRuntime(const Json& runtime);
    void setLinkClock(const Json& clock);
    void setControlRuntime(const std::string& kind,const Json& runtime);
    static Json initial();
    static Json catalog();
    Json effectCatalog() const;
    std::optional<MediaHttpAsset> mediaAsset(const std::string& path,const Json& query) const;
private:
    std::array<std::atomic<double>,8> channelFaders_{{-1,-1,-1,-1,-1,-1,-1,-1}};
    std::atomic<bool> patchAPCOwned_{false};
    std::atomic<bool> patchCrossfaderFollow_{false};
    std::mutex patchAPCMutex_;
    std::map<std::pair<int,int>,int> patchAPCMessages_;
    std::atomic<bool> patchChannelFaderFollow_{false};
    mutable std::mutex mutex_;
    mutable std::shared_ptr<const Json> presentation_;
    mutable std::shared_ptr<const Json> renderSnapshot_;
    mutable uint64_t renderDocumentRevision_=UINT64_MAX,renderRuntimeRevision_=UINT64_MAX,renderClockRevision_=UINT64_MAX,renderPreviewRevision_=UINT64_MAX,renderProcessingRevision_=UINT64_MAX;
    mutable double renderSnapshotAt_=0;
    uint64_t renderTelemetryRevision_=0;
    std::mutex migrationStoreMutex_;
    std::filesystem::path directory_;
    MediaLibrary media_;
    LiveSourceDiscovery liveSources_;
    TextSource textSource_;
    ModuleRegistry modules_;
    FrameTransport frames_;
    mutable CalibrationModel calibration_;
    std::mutex calibrationRequestMutex_;
    std::string calibrationInstance_;
    std::optional<Reply> calibrationRequest(const std::string& method,const std::string& path,const Json& body);
    void reconcileUploaded(Json& document) const;
    Json document_;
    bool recoveredBackup_=false;
    bool restoreDevices_=false;
    mutable std::mutex paletteMutex_;
    Json paletteSources_=Json::array();
    mutable std::mutex patchMutex_;
    Json patchOutputs_=Json::array();
    std::chrono::steady_clock::time_point patchAt_;
    Json patchReferencesCache_=Json::array();
    std::map<std::string,std::chrono::steady_clock::time_point> patchPosterDemand_;
    std::chrono::steady_clock::time_point palettesAt_;
    mutable std::mutex playbackMutex_;
    Json playback_=Json::array();
    std::chrono::steady_clock::time_point playbackAt_;
    Json outputRuntime_=Json::object();
    Json controlRuntime_=Json::object();
    Json externalClock_=Json::object();
    uint64_t clockRevision_=0;
    Json effectiveClock(const Json& document,double now) const;
    uint64_t runtimeRevision_=0;
    struct History {
        std::vector<Json> undo,redo;
        Json last=Json();
        std::string mergeKey;
        std::chrono::steady_clock::time_point edited;
    };
    std::map<std::string,History> histories_;
    std::map<std::string,History> mappingHistories_;
    Json selection_=Json::object();
    Json editorVisibility_=Json::object();uint64_t editorVisibilityRevision_=0;
    mutable Json cachedMappings_,cachedGrid_;
    mutable Json cachedMetaMapping_,cachedMetaGeometry_;
    mutable uint64_t metaGeometryRevision_=UINT64_MAX;
    mutable uint64_t mappingsRevision_=UINT64_MAX,gridRevision_=UINT64_MAX,gridProcessingRevision_=UINT64_MAX,assetRevision_=0;
    mutable double gridResolvedAt_=-1e9;
    std::atomic<unsigned short> apiPort_{0};
    NetworkDiagnostics network_;
    NdiClients ndiClients_;
    mutable bool faderSavePending_=false;
    std::chrono::steady_clock::time_point faderEdited_;
    std::condition_variable faderSaveWake_;
    std::jthread faderSaver_;
    uint64_t faderRevision_=0,faderHistoryRevision_=UINT64_MAX;
    mutable uint64_t renderFaderRevision_=0;
    void persist(const Json& value) const;
    void saveFaderLoop(std::stop_token stop);
    void applyFaderUnlocked(double value,const std::optional<std::string>& bus,bool hardware);
    Json gridCommand(Json& document,const Json& command);
    void refreshGridUnlocked(double snapshotTime) const;
    Json snapshotUnlocked() const;
    std::shared_ptr<const Json> snapshotSharedUnlocked() const;
    void appendMappingPreviewsUnlocked(Json& snapshot) const;
};
}

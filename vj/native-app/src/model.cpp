#include "calibration_debug.hpp"
#include "model.hpp"
#include "meta_mapping.hpp"
#include "patch_catalog.hpp"
#include "media_http.hpp"
#include "mapping_model.hpp"
#include "mapping_geometry.hpp"
#include "mapping_compat.hpp"
#include "api_error.hpp"
#include "control_model.hpp"
#include "midi_runtime.hpp"
#include "live_sources.hpp"
#include "collection_rendering.hpp"
#include "output_model.hpp"
#include "trace_model.hpp"
#include "composition_api.hpp"
#include "fixture_output.hpp"
#include "room_model.hpp"
#include "link_runtime.hpp"
#include "api_compat.hpp"
#include "calibration_capture.hpp"
#include "calibration_scan.hpp"
#include <thread>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <chrono>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <fcntl.h>
#include <unistd.h>
namespace vj {
namespace {
using Error=ApiError;
const auto processStarted=std::chrono::steady_clock::now();
void check(bool value,const std::string& message){if(!value)throw Error(400,message);}
std::string id(const std::string& prefix){static std::atomic<unsigned long> counter{0};return prefix+"_"+std::to_string(getpid())+"_"+std::to_string(std::chrono::system_clock::now().time_since_epoch().count())+"_"+std::to_string(++counter);}
std::string label(const Json& j,const std::string& key,const std::string& fallback){if(!j.contains(key))return fallback;check(j[key].is_string(),key+" must be text");auto s=j[key].get<std::string>();check(!s.empty()&&s.size()<=100,"Name must contain 1–100 bytes");return s;}
Json& byId(Json& items,const std::string& value){for(auto& item:items)if(item.value("id","")==value)return item;throw Error(400,"Unknown object: "+value);}
void removeId(Json& items,const std::string& value){byId(items,value);items.erase(std::remove_if(items.begin(),items.end(),[&](const Json& j){return j.value("id","")==value;}),items.end());}
std::vector<std::string> parts(const std::string& path){std::vector<std::string> result;std::stringstream in(path);std::string s;while(std::getline(in,s,'/'))if(!s.empty())result.push_back(s);return result;}
std::string bus(const Json& g,const Json& c){auto b=c.value("bus",std::string("out1"));if(b=="out1")b="program";check(g["running"].contains(b),"Unknown or inactive output");return b;}
double number(const Json& c,const std::string& key,double lo,double hi){check(c.contains(key)&&c[key].is_number(),key+" must be numeric");double v=c[key];check(std::isfinite(v)&&v>=lo&&v<=hi,key+" outside range");return v;}
void blend(const Json& value){check(value.is_string(),"Blend must be text");static const std::vector<Json> allowed={"normal","add","screen","multiply","subtract"};check(std::find(allowed.begin(),allowed.end(),value)!=allowed.end(),"Unknown blend");}
Json content(const Json& g){Json result=g;for(const auto* key:{"shows","active_show","control_focus","history","controller_lights","fader_sync","fader_position"})result.erase(key);return result;}
void cleanSelections(Json& g,const std::string& row,const std::string& column=""){for(const auto* key:{"selections","selections_b"})for(auto& selections:g[key])if(selections.contains(row)&&(column.empty()||selections[row]==column))selections.erase(row);}
void reconcileGrid(Json& d){
    auto& g=d["grid"];const int count=d.value("outputCount",static_cast<int>(g["running"].size()));
    for(const auto* key:{"running","selections","selections_b","crossfade"}){
        Json values=Json::object();for(int i=1;i<=count;++i){const auto b=i==1?"program":"out"+std::to_string(i);Json fallback=std::string(key)=="running"?Json(true):std::string(key)=="crossfade"?Json(0.0):Json::object();values[b]=g[key].value(b,fallback);}g[key]=values;
    }
    auto& focus=g["control_focus"];if(!focus.is_object())focus=Json::object();
    if(!g["running"].contains(focus.value("bus",std::string{})))focus["bus"]="program";
    for(const auto* key:{"row","column"}){
        const auto& items=g[std::string(key)=="row"?"rows":"columns"];
        const auto wanted=focus.value(key,std::string{});
        if(std::none_of(items.begin(),items.end(),[&](const Json& item){return item["id"]==wanted;})){if(items.empty())focus.erase(key);else focus[key]=items[0]["id"];}
    }
}
void validateParams(const std::string& effect,const Json& params,const Json& effects){check(params.is_object(),"params must be an object");auto found=std::find_if(effects.begin(),effects.end(),[&](const Json& j){return j["name"]==effect;});check(found!=effects.end(),"Effect not yet supported in native development app");for(auto it=params.begin();it!=params.end();++it){const auto& specs=(*found)["params"];check(specs.contains(it.key()),"Unknown parameter: "+it.key());const auto& spec=specs[it.key()];if(spec.value("mediaFile",false)||spec["type"]=="text"){check(it.value().is_string(),"Expected text");if((effect=="ndi"||effect=="syphon")&&it.key()=="source"&&it.value()!="")check(!normalizeLiveSelection(effect,it.value()).empty(),"Invalid live source selection");if(it.key()=="subtitle_track"){const auto track=it.value().get<std::string>();check(track.size()<=9&&track.find_first_not_of("0123456789")==std::string::npos,"Invalid subtitle stream index");}}
else if(spec["type"]=="media_list"){validateMediaItems(it.value());}
else if(spec["type"]=="color"){auto s=it.value().get<std::string>();check(s.size()==7&&s[0]=='#'&&s.find_first_not_of("0123456789abcdefABCDEF",1)==std::string::npos,"Expected #RRGGBB color");}else if(spec["type"]=="bool"){check(it.value().is_boolean(),"Expected boolean");}
else if(spec["type"]=="choice"){check(std::find(spec["choices"].begin(),spec["choices"].end(),it.value())!=spec["choices"].end(),"Invalid choice");}
else{Json one={{it.key(),it.value()}};double v=number(one,it.key(),spec["min"],spec["max"]);if(spec["type"]=="int")check(std::floor(v)==v,"Expected integer");}}}
}
Json Model::catalog(){
    static const Json builtin=[] {
    Json entries=Json::array();
    for(const auto& entry:mediaEffectCatalog())entries.push_back(entry);
    for(const auto& entry:liveSourceCatalog())entries.push_back(entry);
    for(const auto& entry:patchEffectCatalog())entries.push_back(entry);
    entries.push_back(textSourceCatalog());
    for(auto& entry:entries){entry["title"]=entry["label"];entry["params"]=Json::object();for(const auto& parameter:entry["parameters"]){auto spec=parameter;spec["type"]=spec["kind"];entry["params"][parameter["name"].get<std::string>()]=spec;}}
    return entries;
    }();
    return builtin;
}
Json Model::effectCatalog()const{
    auto entries=catalog();for(auto entry:modules_.catalog()){entry["title"]=entry["label"];entry["params"]=Json::object();for(auto parameter:entry["parameters"]){parameter["type"]=parameter["kind"];entry["params"][parameter["name"].get<std::string>()]=parameter;}entries.push_back(std::move(entry));}return entries;
}
void Model::reconcileUploaded(Json& document)const{
    std::set<std::string> effects;for(const auto& effect:modules_.catalog())effects.insert(effect["name"]);
    auto normalize=[&](Json& grid){if(!grid.contains("rows"))return;for(auto& row:grid["rows"])for(auto& clip:row["clips"]){auto effect=clip.value("gen",std::string{});if(effects.contains(effect)){clip["params"]=modules_.normalize(effect,clip.value("params",Json::object()));clip.erase("nativeImportUnsupported");}}};
    normalize(document["grid"]);for(auto& show:document["showContents"])normalize(show);
}
Json Model::initial(){
    Json columns=Json::array();for(int i=0;i<6;i++)columns.push_back({{"id","column_"+std::to_string(i)},{"name",std::to_string(i+1)}});
    Json grid={{"version",2},{"columns",columns},{"rows",Json::array({{{"id","row_0"},{"name","Layer"},{"blend","normal"},{"enabled",true},{"clips",Json::object()}}})},
      {"selections",{{"program",Json::object()}}},{"selections_b",{{"program",Json::object()}}},{"running",{{"program",true}}},{"crossfade",{{"program",0.0}}},
      {"active_show","show_0"},{"shows",Json::array({{{"id","show_0"},{"name","Set 1"}}})},{"control_focus",{{"bus","program"},{"row","row_0"},{"column","column_0"}}},{"fader_sync",false},{"controller_lights","full"}};
    Json mappings=Json::object();for(int i=1;i<=4;i++){auto mid=std::to_string(i);mappings[mid]={{"mappingId",mid},{"type","mapping_snapshot"},{"schema",2},{"revision",0},{"layout",nullptr},{"project",{{"rects",Json::array({{{"id","rect-1"},{"name","Surface 1"},{"kind","surface"},{"source","out1"},{"mode","grid"},{"corners",Json::array({{.1,.1},{.9,.1},{.9,.9},{.1,.9}})},{"uvs",Json::array({{0,1},{1,1},{1,0},{0,0}})},{"cornerRadius",0.0},{"blend","normal"},{"fit","stretch"}}})},{"traces",Json::array()},{"collections",Json::array()},{"groups",Json::array()},{"output",{{"rotation",0},{"enabled",true},{"boundsGrid",false}}}}}};}
    return {{"format","vj-native-development/1"},{"revision",0},{"outputCount",1},{"grid",grid},{"showContents",{{"show_0",content(grid)}}},{"mappings",mappings}};
}
Model::Model(std::filesystem::path directory):directory_(std::move(directory)),media_(directory_/"media"),textSource_(directory_/"text-cache"),modules_(directory_/"vector-modules"),calibration_(directory_),calibrationInstance_(id("native-calibration")),network_(directory_),ndiClients_(directory_/"ndi-clients.json"){
    check(!directory_.empty(),"Explicit state directory required");std::filesystem::create_directories(directory_);
    auto path=directory_/"native-state.json";
    if(std::filesystem::exists(directory_/"mapper-visibility.json")){std::ifstream in(directory_/"mapper-visibility.json");auto saved=Json::parse(in,nullptr,false);if(saved.is_object()&&saved.value("format",std::string{})=="vj-mapper-visibility/1"&&saved.value("mappings",Json()).is_object())editorVisibility_=saved["mappings"];}
    auto read=[&](const std::filesystem::path& source){std::ifstream in(source);Json value;in>>value;check(value.value("format","")=="vj-native-development/1","Unsupported native state format");check(value.contains("grid")&&value["grid"].is_object()&&value.contains("mappings")&&value["mappings"].is_object(),"Invalid native state document");return value;};
    if(std::filesystem::exists(path)){
        try{document_=read(path);}
        catch(const std::exception&){const auto backup=directory_/"native-state.json.bak";if(!std::filesystem::exists(backup))throw;document_=read(backup);recoveredBackup_=true;}
    }else if(std::filesystem::exists(directory_/"native-state.json.bak")){document_=read(directory_/"native-state.json.bak");recoveredBackup_=true;}
    else{document_=initial();persist(document_);}
    if(!document_.contains("outputCount"))document_["outputCount"]=document_["grid"]["running"].size();
    if(!document_.contains("layouts"))document_["layouts"]=Json::object();
    if(!document_.contains("layoutsRevision"))document_["layoutsRevision"]=0;
    resetControlRuntime(document_);
    initializeOutputSettings(document_);initializeFixtureOutput(document_);initializeRoom(document_);initializeLink(document_);
    for(auto& mapping:document_["mappings"])normalizeMappingTraces(mapping["project"]);
    reconcileMappingTraceFixtures(document_);
    reconcileGrid(document_);reconcileUploaded(document_);frames_.setActiveOutputs(document_["outputCount"]);frames_.setStreamHD(document_["controls"].value("stream_hd",false));
    const auto now=controlNow();reconcileCompositionApi(document_,now,controlClock(document_,now)["beat"],true);
    ndiClients_.setSourceProvider([this](const std::string& mid,bool enable)->std::optional<std::string>{
        if(mid!="1"&&mid!="2"&&mid!="3"&&mid!="4")throw ApiError(400,"Unknown projector");
        auto settings=request("GET","/api/v1/ndi/projectors").body;auto projectors=settings.at("projectors");
        const bool enabled=projectors.value(mid,Json::object()).value("enabled",false);
        if(enable&&!enabled){projectors[mid]["enabled"]=true;auto changed=request("PUT","/api/v1/ndi/projectors",projectors);if(changed.status>=400)throw ApiError(changed.status,changed.body.value("error",std::string("Unable to enable projector")));settings=request("GET","/api/v1/ndi/projectors").body;}
        else if(!enabled)return std::string{};
        const auto status=settings.value("status",Json::object()).value(mid,Json::object());auto source=status.value("source_name",std::string{});
        if(!status.value("active",false)||source.empty())return std::nullopt;
        return Json{{"name",source},{"url",""},{"extra_ips",""}}.dump();
    });
    faderSaver_=std::jthread([this](std::stop_token stop){saveFaderLoop(stop);});
}
Model::~Model(){
    ndiClients_.stop();faderSaver_.request_stop();faderSaveWake_.notify_all();
    if(faderSaver_.joinable())faderSaver_.join();
    std::lock_guard lock(mutex_);
    if(faderSavePending_)try{persist(document_);}catch(const std::exception& e){std::fprintf(stderr,"Final fader save failed: %s\n",e.what());}
}
void Model::saveFaderLoop(std::stop_token stop){
    std::unique_lock lock(mutex_);
    while(!stop.stop_requested()){
        faderSaveWake_.wait(lock,[&]{return stop.stop_requested()||faderSavePending_;});
        if(stop.stop_requested())break;
        auto deadline=faderEdited_+std::chrono::milliseconds(300);
        if(faderSaveWake_.wait_until(lock,deadline,[&]{return stop.stop_requested()||!faderSavePending_||faderEdited_+std::chrono::milliseconds(300)!=deadline;}))continue;
        try{persist(document_);if(controlRuntime_.erase("persistence"))++runtimeRevision_;}
        catch(const std::exception& e){controlRuntime_["persistence"]={{"error",e.what()}};++runtimeRevision_;faderEdited_=std::chrono::steady_clock::now()+std::chrono::seconds(1);}
    }
}
void Model::applyFaderUnlocked(double value,const std::optional<std::string>& output,bool hardware){
    auto& grid=document_["grid"];
    const bool changed=output&&grid["crossfade"].value(*output,0.)!=value;
    const bool moved=hardware&&grid.value("fader_position",Json())!=value;
    if(!changed&&!moved)return;
    const auto now=std::chrono::steady_clock::now();
    if(changed){
        const auto sid=grid["active_show"].get<std::string>();auto& history=histories_[sid];
        const auto key=Json::array({"set_crossfade",*output}).dump();
        // Other content edits clear/change the history merge key. Record a
        // gesture once; don't copy every clip and every show's history per CC.
        const bool merge=faderHistoryRevision_==document_["revision"].get<uint64_t>()&&history.mergeKey==key&&!history.undo.empty()&&history.redo.empty()&&now-history.edited<std::chrono::milliseconds(800);
        if(!merge){auto before=content(grid);history.undo.push_back(before);if(history.undo.size()>100)history.undo.erase(history.undo.begin());history.last=std::move(before);}
        history.redo.clear();history.last["crossfade"][*output]=value;history.mergeKey=key;history.edited=now;
        grid["crossfade"][*output]=value;document_["showContents"][sid]["crossfade"][*output]=value;
        faderSavePending_=true;faderEdited_=now;faderSaveWake_.notify_one();
    }
    if(hardware)grid["fader_position"]=value;
    const auto old=document_["revision"].get<uint64_t>();document_["revision"]=old+1;++faderRevision_;if(changed)faderHistoryRevision_=old+1;
    if(mappingsRevision_==old)mappingsRevision_=old+1;
    if(gridRevision_==old){cachedGrid_["crossfade"]=grid["crossfade"];cachedGrid_["fader_position"]=grid.value("fader_position",Json());auto& h=histories_[grid["active_show"].get<std::string>()];cachedGrid_["history"]={{"can_undo",!h.undo.empty()},{"can_redo",!h.redo.empty()}};gridRevision_=old+1;}
    if(renderDocumentRevision_==old)renderDocumentRevision_=old+1;
}
Json Model::midiSnapshot()const{
    std::lock_guard lock(mutex_);auto state=controlSnapshot(document_);state["grid"]=document_["grid"];state["startupPolicy"]=restoreDevices_?"restore":"isolated";
    if(controlRuntime_.contains("midi"))state["midi"].update(controlRuntime_["midi"]);
    return {{"state",std::move(state)}};
}
std::optional<double> Model::crossfadeValue(const std::string& output)const{
    std::unique_lock lock(mutex_,std::try_to_lock);if(!lock.owns_lock())return std::nullopt;
    return document_["grid"]["crossfade"].value(output,0.);
}

std::optional<double> Model::hardwareFaderValue()const{
    std::unique_lock lock(mutex_,std::try_to_lock);if(!lock.owns_lock())return std::nullopt;
    const auto midi=controlRuntime_.find("midi");
    if(midi==controlRuntime_.end()||!midi->value("connected",Json()).is_string())return std::nullopt;
    const auto value=document_["grid"].value("fader_position",Json());
    return value.is_number()?std::optional<double>(value.get<double>()):std::nullopt;
}

bool Model::receivePatchAPC(int status,int number,int value){
    if(!patchAPCOwned_.load()&&!(patchCrossfaderFollow_.load()&&status==0xb0&&number==15))return false;
    int kind=status&0xf0;
    if(kind==0xb0||kind==0x90||kind==0x80){
        // Coalesce absolute controls at the UI rate, with note-off sharing its note-on key.
        std::lock_guard lock(patchAPCMutex_);
        patchAPCMessages_[{kind==0x80?0x90|(status&15):status,number}]=kind==0x80?0:value;
    }
    return true;
}
std::vector<std::array<int,3>> Model::takePatchAPCMessages(){
    std::lock_guard lock(patchAPCMutex_);std::vector<std::array<int,3>> result;
    for(auto& [key,value]:patchAPCMessages_)result.push_back({key.first,key.second,value});
    patchAPCMessages_.clear();return result;
}
bool Model::receiveChannelFader(int channel,double value){
    if(channel<0||channel>=8||!std::isfinite(value)||value<0||value>1)return false;
    channelFaders_[channel].store(value);return patchChannelFaderFollow_.load();
}
std::array<double,8> Model::hardwareChannelFaders()const{
    std::array<double,8> values;for(int i=0;i<8;++i)values[i]=channelFaders_[i].load();return values;
}

void Model::persist(const Json& value) const{
    auto write=[&](const std::filesystem::path& path,const std::string& bytes){
        int fd=::open(path.c_str(),O_CREAT|O_TRUNC|O_WRONLY,0600);if(fd<0)throw std::runtime_error("Cannot write native state");
        size_t offset=0;while(offset<bytes.size()){auto count=::write(fd,bytes.data()+offset,bytes.size()-offset);if(count<0&&errno==EINTR)continue;if(count<=0){::close(fd);throw std::runtime_error("Native state write failed");}offset+=count;}
        int result=::fsync(fd);::close(fd);if(result)throw std::runtime_error("Native state sync failed");
    };
    const auto temp=directory_/"native-state.json.tmp",destination=directory_/"native-state.json",backup=directory_/"native-state.json.bak";
    write(temp,value.dump(2)+"\n");
    // Rotate a known valid previous revision; never replace a good backup with
    // the corrupt primary from which startup recovered.
    if(std::filesystem::exists(destination)){
        std::ifstream input(destination);const std::string old((std::istreambuf_iterator<char>(input)),{});const auto parsed=Json::parse(old,nullptr,false);
        if(parsed.is_object()&&parsed.value("format",std::string{})=="vj-native-development/1"&&parsed.contains("grid")&&parsed.contains("mappings")){
            const auto backupTemp=directory_/"native-state.json.bak.tmp";write(backupTemp,old);std::filesystem::rename(backupTemp,backup);
        }
    }
    std::filesystem::rename(temp,destination);
    int directory=::open(directory_.c_str(),O_RDONLY);if(directory>=0){::fsync(directory);::close(directory);}
    faderSavePending_=false;

}
std::optional<MediaHttpAsset> Model::mediaAsset(const std::string& path,const Json& query) const {
    const std::string prefix="/api/clips/text-thumbnail/";
    if(!path.starts_with(prefix))return resolveMediaHttpAsset(media_,path,query);
    const auto tail=path.substr(prefix.size());const auto slash=tail.find('/');
    if(slash==std::string::npos||tail.find('/',slash+1)!=std::string::npos)throw ApiError(404,"Text clip unavailable");
    const auto rowId=tail.substr(0,slash),column=tail.substr(slash+1);Json params;
    {std::lock_guard lock(mutex_);for(const auto& row:document_.at("grid").at("rows"))if(row.value("id",std::string{})==rowId&&row.at("clips").contains(column)){const auto& clip=row["clips"][column];if(clip.value("gen",std::string{})=="text")params=clip.at("params");break;}}
    if(params.is_null())throw ApiError(404,"Text clip unavailable");
    if(!TextSource::available())throw ApiError(503,"Text rasterizer unavailable");
    return MediaHttpAsset{textSource_.asset(params,320,180),"image/png","no-store"};
}
void Model::refreshGridUnlocked(double snapshotTime)const{
    const auto revision=document_["revision"].get<uint64_t>(),processingRevision=media_.processingRevision();
    if(gridRevision_!=revision||gridProcessingRevision_!=processingRevision||snapshotTime-gridResolvedAt_>=1.){
    Json grid=document_["grid"];auto history=histories_.find(grid["active_show"].get<std::string>());grid["history"]={{"can_undo",history!=histories_.end()&&!history->second.undo.empty()},{"can_redo",history!=histories_.end()&&!history->second.redo.empty()}};
    const auto catalog=effectCatalog();
    std::set<std::string> known;
    for(const auto& entry:catalog)known.insert(entry.at("name").get<std::string>());
    for(auto& row:grid["rows"])for(auto& clip:row["clips"])if(!known.contains(clip.at("gen").get<std::string>()))
        clip["nativeImportUnsupported"]=true;
    for(auto& row:grid["rows"])for(auto& clip:row["clips"]){auto effect=clip.value("gen",std::string{});if(effect=="image"||effect=="video"){auto status=media_.status(clip["params"].value("file",std::string{}),effect);clip["resolved_file"]=status.value("resolved_file",std::string{});clip["mediaStatus"]=status;if(effect=="video")media_.decorateVideo(clip);}}
    for(auto& row:grid["rows"])for(auto& clip:row["clips"])if(clip.value("gen",std::string{})=="media_collection"){
        clip["resolvedItems"]=Json::array();for(const auto& item:clip["params"].value("items",Json::array())){auto resolved=media_.status(item.value("file",std::string{}),item.value("type",std::string{}));if(item.value("type",std::string{})=="video")media_.decorateVideo(resolved);clip["resolvedItems"].push_back(std::move(resolved));}
    }
    for(auto& row:grid["rows"])for(auto& clip:row["clips"])if(clip.value("gen",std::string{})=="text"){
        try{clip["resolved_file"]=textSource_.asset(clip["params"],1920,1080);clip["textStatus"]={{"available",true}};}
        catch(const std::exception& error){clip["resolved_file"]="";clip["textStatus"]={{"available",false},{"error",error.what()}};}
    }
    for(auto& row:grid["rows"])for(auto& clip:row["clips"])if(clip.value("gen",std::string{}).starts_with("external_")){try{clip["vector"]=modules_.recipe(clip["gen"],clip["params"],1920,1080);}catch(...) {}}
    if(cachedGrid_!=grid)++assetRevision_;cachedGrid_=std::move(grid);gridRevision_=revision;gridProcessingRevision_=processingRevision;gridResolvedAt_=snapshotTime;
    }
}
Json Model::snapshotUnlocked()const{return *snapshotSharedUnlocked();}
std::shared_ptr<const Json> Model::snapshotSharedUnlocked()const{
    const auto revision=document_["revision"].get<uint64_t>(),processingRevision=media_.processingRevision();const auto snapshotTime=controlNow();
    if(mappingsRevision_!=revision){
    Json mappings=Json::object();for(auto it=document_["mappings"].begin();it!=document_["mappings"].end();++it){
        auto entry=selection_.value(it.key(),Json::object());auto m=mappingSnapshot(document_,it.key(),entry.value("ids",Json::array()));m["selectionRevision"]=entry.value("revision",0);
        if(entry.contains("traceId")){m["project"]["selectedTraceId"]=nullptr;for(const auto& trace:m["project"]["traces"])if(trace["id"]==entry["traceId"])m["project"]["selectedTraceId"]=trace["id"];}
        auto history=mappingHistories_.find(it.key());m["history"]={{"can_undo",history!=mappingHistories_.end()&&!history->second.undo.empty()},{"can_redo",history!=mappingHistories_.end()&&!history->second.redo.empty()}};mappings[it.key()]=m;
    }
    cachedMappings_=std::move(mappings);mappingsRevision_=revision;
    }
    refreshGridUnlocked(snapshotTime);
    const auto& grid=cachedGrid_;const auto& mappings=cachedMappings_;
    Json state=controlSnapshot(document_);state["startupPolicy"]=restoreDevices_?"restore":"isolated";state["frameTransport"]=frames_.diagnostics();const auto frameConfig=state["frameTransport"]["config"];const int streamWidth=frameConfig["width"],streamHeight=frameConfig["height"];const int hdWidth=std::max(1280,std::min(1920,streamWidth*2));state["stream"].update({{"size",{streamWidth,streamHeight}},{"fps",frameConfig["fps"]},{"quality",frameConfig["quality"]},{"hd_size",{hdWidth,std::max(720,int(std::nearbyint(double(hdWidth)*streamHeight/std::max(1,streamWidth))))}},{"hd_quality",std::max(90,frameConfig["quality"].get<int>())}});state["grid"]=grid;state.update(outputSnapshot(document_,outputRuntime_));state.update(fixtureOutputSnapshot(document_));state.update(linkSnapshot(document_));state["clock"]=effectiveClock(document_,controlNow());state["bpm"]=state["clock"]["bpm"];
    state["savedDeviceIntent"]={{"midi",state["midi"].value("selected",Json())},{"link",state["linkConfig"].value("enabled",false)},{"wled",state["fixtureOutput"].value("requested",false)},{"dmx",state["dmxTransport"].value("requested",false)}};
    for(auto it=controlRuntime_.begin();it!=controlRuntime_.end();++it){if(!state[it.key()].is_object())state[it.key()]=Json::object();state[it.key()].update(it.value());}
    state["midi"]["patchAPCOwned"]=patchAPCOwned_.load();
    state["midi"]["patchCrossfaderFollow"]=patchCrossfaderFollow_.load();
    state["midi"]["controlHooks"]=midiControlHooks(document_,effectCatalog(),isApc40(state["midi"].value("connected",Json()).is_string()?state["midi"]["connected"].get<std::string>():""),patchChannelFaderFollow_.load(),patchCrossfaderFollow_.load());
    state["clock"]["link_available"]=state["link"].value("available",false);
    state["clock"]["midi_available"]=state["midi"].value("available",false);
    bool hardware=false;for(const auto& projector:outputRuntime_.value("projectors",Json::object()))for(const auto* kind:{"display","ndi"})hardware=hardware||projector.value(kind,Json::object()).value("active",false);
    const auto now=controlNow();auto outputs=compositionOutputs(document_,effectCatalog(),state,now,effectiveClock(document_,now)["beat"],state["clock"]["bpm"]);
    Json snapshot={{"metaMapping",metaGeometryRevision_==revision?cachedMetaMapping_:metaMappingSnapshot(document_)},{"calibration",calibration_.command(controlNow())},{"room",roomSnapshot(document_)},{"clockRevision",clockRevision_},{"nativeEffects",modules_.catalog()},{"history",modules_.history()["animations"]},{"outputs",outputs},{"apiVersion",1},{"type","state"},{"revision",document_["revision"]},{"runtimeRevision",runtimeRevision_+processingRevision+assetRevision_},{"mediaRevision",processingRevision+assetRevision_},{"state",state},{"mappings",mappings},{"mappingLayouts",mappingLayouts(document_)},{"nativeDevelopment",{{"featureParity",false},{"hardwareOutputs",hardware},{"recoveredBackup",recoveredBackup_}}}};
    // Graph geometry depends on authored surfaces, placement, routing and clips,
    // not telemetry or animation time. Keep editor selection/preview state fresh.
    if(metaGeometryRevision_!=revision){
        appendMetaMappingRendering(snapshot);
        cachedMetaMapping_=snapshot["metaMapping"];cachedMetaGeometry_=Json::object();
        for(auto it=snapshot["mappings"].begin();it!=snapshot["mappings"].end();++it)
            cachedMetaGeometry_[it.key()]={{"renderRects",it.value()["project"]["renderRects"]},{"collectionContexts",it.value()["collectionContexts"]}};
        metaGeometryRevision_=revision;
    }else{
        for(auto it=cachedMetaGeometry_.begin();it!=cachedMetaGeometry_.end();++it){
            snapshot["mappings"][it.key()]["project"]["renderRects"]=it.value()["renderRects"];
            snapshot["mappings"][it.key()]["collectionContexts"]=it.value()["collectionContexts"];
        }
    }
    snapshot["editorVisibilityRevision"]=editorVisibilityRevision_;for(auto it=snapshot["mappings"].begin();it!=snapshot["mappings"].end();++it)it.value()["editorVisibility"]=mappingEditorVisibility(it.value()["project"],editorVisibility_.value(it.key(),Json::object()));
    appendMappingPreviewsUnlocked(snapshot);
    decorateExternalSnapshot(snapshot,std::chrono::duration<double>(std::chrono::steady_clock::now()-processStarted).count(),vectorModuleValidatorAvailable());
    auto shared=std::make_shared<const Json>(std::move(snapshot));std::atomic_store(&presentation_,shared);return shared;
}
void Model::appendMappingPreviewsUnlocked(Json& snapshot)const{
    snapshot["previewRevision"]=selection_.value("_previewRevision",uint64_t(0));
    snapshot["scenePreviewRevision"]=selection_.value("_scenePreviewRevision",uint64_t(0));
    auto& previews=snapshot["mappingPreviews"];previews=Json::object();
    for(auto it=document_["mappings"].begin();it!=document_["mappings"].end();++it){
        auto entry=selection_.find(it.key());
        if(entry!=selection_.end()&&entry->contains("preview")&&(*entry)["preview"].value("baseRevision",Json())==it.value()["revision"])previews[it.key()]=(*entry)["preview"];
    }
}
std::shared_ptr<const Json> Model::presentationSnapshotShared()const{auto latest=std::atomic_load(&presentation_);if(latest)return latest;std::lock_guard lock(mutex_);return snapshotSharedUnlocked();}
Json Model::presentationSnapshot()const{return *presentationSnapshotShared();}
uint64_t Model::revision()const{std::lock_guard lock(mutex_);return document_["revision"].get<uint64_t>();}
Json Model::snapshot()const{std::lock_guard lock(mutex_);return snapshotUnlocked();}
Json Model::fixtureSnapshot()const{
    std::lock_guard lock(mutex_);auto state=controlSnapshot(document_);state.update(fixtureOutputSnapshot(document_));state["startupPolicy"]=restoreDevices_?"restore":"isolated";return {{"state",std::move(state)}};
}
Json Model::renderSnapshot()const{return *renderSnapshotShared();}
std::shared_ptr<const Json> Model::renderSnapshotShared()const{
    std::lock_guard lock(mutex_);const auto now=controlNow();
    const auto documentRevision=document_["revision"].get<uint64_t>(),preview=selection_.value("_previewRevision",uint64_t(0)),processing=media_.processingRevision();
    // Procedural playback has its own continuous clock. Do not rebuild the
    // entire scene every 250 ms just to collect telemetry on the render thread.
    // File assets still poll for external changes; calibration retains its lease.
    bool timedRefresh=false;
    if(renderSnapshot_&&now-renderSnapshotAt_>=.25){
        timedRefresh=!(*renderSnapshot_)["calibration"]["outputs"].empty()||!(*renderSnapshot_)["calibration"].value("camera",std::string{}).empty();
        if(now-gridResolvedAt_>=1.){
            bool pollMedia=false;
            for(const auto& row:cachedGrid_["rows"])for(const auto& clip:row["clips"]){
                const auto gen=clip.value("gen",std::string{});
                pollMedia|=gen=="image"||gen=="video"||gen=="media_collection"||gen=="text";
            }
            // Poll assets without rebuilding every mapping and catalog when
            // nothing changed. A changed asset increments assetRevision_ below.
            if(pollMedia)refreshGridUnlocked(now);
        }
    }
    if(renderSnapshot_&&renderDocumentRevision_==documentRevision&&renderRuntimeRevision_==runtimeRevision_-renderTelemetryRevision_&&renderClockRevision_==clockRevision_&&renderProcessingRevision_==processing&&!timedRefresh&&renderSnapshot_->value("mediaRevision",uint64_t(0))==processing+assetRevision_){
        // Pointer motion replaces an ephemeral preview. It must reach the next
        // frame without rebuilding catalogs, layouts and composition state or
        // extending the base snapshot's expiry. Committed/API state stays intact.
        if(renderPreviewRevision_!=preview||renderFaderRevision_!=faderRevision_){
            auto result=*renderSnapshot_;appendMappingPreviewsUnlocked(result);
            result["revision"]=document_["revision"];
            result["state"]["grid"]["crossfade"]=document_["grid"]["crossfade"];
            if(cachedGrid_.contains("history"))result["state"]["grid"]["history"]=cachedGrid_["history"];
            result["state"]["grid"]["fader_position"]=document_["grid"].value("fader_position",Json());
            for(auto& output:result["outputs"])output["crossfade"]=document_["grid"]["crossfade"].value(output["internalBus"].get<std::string>(),0.);
            renderFaderRevision_=faderRevision_;
            // A new preview can rebuild a collection's render scene. Its clock
            // anchor must advance too, otherwise apply_scene would repeatedly
            // restart animation at the cached time while the pointer moves.
            const auto clock=effectiveClock(document_,now);result["state"]["clock"]=clock;
            for(auto& output:result["outputs"])output["clock"]=compositionClock(document_,output["internalBus"],now,clock["beat"],clock["bpm"]);
            renderSnapshot_=std::make_shared<const Json>(std::move(result));renderPreviewRevision_=preview;
            std::atomic_store(&presentation_,renderSnapshot_);
        }
        return renderSnapshot_;
    }
    renderSnapshot_=snapshotSharedUnlocked();renderDocumentRevision_=documentRevision;renderRuntimeRevision_=runtimeRevision_-renderTelemetryRevision_;renderClockRevision_=clockRevision_;renderPreviewRevision_=preview;renderProcessingRevision_=processing;renderSnapshotAt_=now;renderFaderRevision_=faderRevision_;return renderSnapshot_;
}
Json Model::effectiveClock(const Json& document,double now)const{
    auto result=controlClock(document,now);if(!externalClock_.empty()){const double bpm=externalClock_["bpm"],origin=externalClock_["origin"];result.update({{"bpm",bpm},{"origin",origin},{"beat",(now-origin)*bpm/60.},{"seconds",now-origin}});}return result;
}
void Model::setLinkClock(const Json& clock){
    std::lock_guard lock(mutex_);
    if(clock.is_null()){
        if(!externalClock_.empty()){document_["controls"]["clock"].update(externalClock_);externalClock_=Json::object();++clockRevision_;++runtimeRevision_;}return;
    }
    if(!document_["controls"]["clock"].value("link_sync",false))return;
    const double bpm=clock.value("bpm",120.),beat=clock.value("beat",0.),captured=clock.value("capturedAt",controlNow());
    if(!std::isfinite(bpm)||!std::isfinite(beat)||!std::isfinite(captured)||bpm<20||bpm>300)return;const double origin=captured-beat*60/bpm;
    if(externalClock_.empty()||std::abs(origin-externalClock_.value("origin",origin))>.001||std::abs(bpm-externalClock_.value("bpm",bpm))>.001)++clockRevision_;
    externalClock_={{"bpm",bpm},{"origin",origin}};++runtimeRevision_;
}
// Live palette colors are runtime data: never save them into clips or reset scene clocks.
void Model::setPaletteSources(const Json& sources){
    Json valid=Json::array();
    if(sources.is_array())for(const auto& source:sources){
        if(!source.is_object()||!source.contains("id")||!source["id"].is_string()||source["id"].get<std::string>().empty())continue;
        auto colors=source.value("colors",Json::array());
        bool good=source.value("available",false)&&colors.is_array()&&!colors.empty();
        for(const auto& c:colors){
            if(!c.is_object()){good=false;break;}
            for(const auto* key:{"r","g","b"})if(!c.contains(key)||!c[key].is_number()||!std::isfinite(c[key].get<double>())||c[key].get<double>()<0||c[key].get<double>()>1)good=false;
        }
        auto item=source;item["available"]=good;item["held"]=false;item["colors"]=good?colors:Json::array();valid.push_back(std::move(item));
    }
    std::lock_guard lock(paletteMutex_);
    // Keep the last complete palette for each source through extraction gaps,
    // disconnects, and discovery timeouts. Availability still reports live status.
    for(const auto& previous:paletteSources_){
        if(previous["colors"].empty())continue;
        auto current=std::find_if(valid.begin(),valid.end(),[&](const Json& item){return item["id"]==previous["id"];});
        if(current==valid.end()){
            auto held=previous;held["available"]=false;held["held"]=true;held["listed"]=false;valid.push_back(std::move(held));
        }else if(!current->value("available",false)){
            (*current)["colors"]=previous["colors"];(*current)["held"]=true;
        }
    }
    paletteSources_=std::move(valid);palettesAt_=std::chrono::steady_clock::now();
}
void Model::setPatchOutputs(Json sources){std::lock_guard lock(patchMutex_);patchOutputs_=std::move(sources);patchAt_=std::chrono::steady_clock::now();}
Json Model::patchOutputs()const{std::lock_guard lock(patchMutex_);return std::chrono::steady_clock::now()-patchAt_<std::chrono::seconds(3)?patchOutputs_:Json::array();}
Json Model::patchReferences()const{
 std::lock_guard lock(patchMutex_);auto ids=patchReferencesCache_.get<std::set<std::string>>();const auto now=std::chrono::steady_clock::now();
 for(const auto& [id,until]:patchPosterDemand_)if(until>now)ids.insert(id);return ids;
}
void Model::setPatchReferences(Json ids){std::lock_guard lock(patchMutex_);patchReferencesCache_=std::move(ids);}
void Model::requestPatchPoster(const std::string& id){
 if(!id.starts_with("patch:"))return;std::lock_guard lock(patchMutex_);const auto now=std::chrono::steady_clock::now();
 for(auto it=patchPosterDemand_.begin();it!=patchPosterDemand_.end();)if(it->second<=now)it=patchPosterDemand_.erase(it);else ++it;
 patchPosterDemand_[id]=now+std::chrono::seconds(1);
}
Json Model::paletteSources()const{
    std::lock_guard lock(paletteMutex_);
    auto result=paletteSources_;
    if(std::chrono::steady_clock::now()-palettesAt_>=std::chrono::seconds(3))for(auto& source:result){source["available"]=false;source["held"]=!source["colors"].empty();}
    return result;
}
void Model::setPlaybackRuntime(const Json& sources){std::lock_guard lock(playbackMutex_);playback_=sources;playbackAt_=std::chrono::steady_clock::now();}
Json Model::playbackRuntime()const{std::lock_guard lock(playbackMutex_);bool fresh=std::chrono::steady_clock::now()-playbackAt_<std::chrono::seconds(2);return {{"available",fresh},{"sources",fresh?playback_:Json::array()}};}
// WLED transport reports contain delivery diagnostics, not render inputs.
// Fixture enablement, routing and brightness still invalidate via document edits.
void Model::setControlRuntime(const std::string& kind,const Json& runtime){if(kind=="midi"&&!runtime.value("connected",Json()).is_string())for(auto& value:channelFaders_)value.store(-1);std::lock_guard lock(mutex_);if(controlRuntime_.value(kind,Json::object())!=runtime){controlRuntime_[kind]=runtime;++runtimeRevision_;if(kind=="renderer"||kind=="vectors"||kind=="fixtureOutput"||kind=="ui")++renderTelemetryRevision_;}}
void Model::setOutputRuntime(const Json& runtime){
    std::lock_guard lock(mutex_);auto next=outputRuntime_;
    for(auto it=runtime.begin();it!=runtime.end();++it)if(it.key()=="projectors")for(auto projector=it.value().begin();projector!=it.value().end();++projector){if(!next["projectors"][projector.key()].is_object())next["projectors"][projector.key()]=Json::object();next["projectors"][projector.key()].update(projector.value());}else next[it.key()]=it.value();
    if(next!=outputRuntime_){outputRuntime_=std::move(next);++runtimeRevision_;++renderTelemetryRevision_;}
}
Json Model::gridCommand(Json& d,const Json& c){
    auto& g=d["grid"];const auto action=c.at("action").get<std::string>();
    if(c.contains("active_show"))check(c["active_show"]==g["active_show"],"Active show changed");
    check(c.value("bank",std::string("A"))=="A"||c["bank"]=="B","Bank must be A or B");
    if(action=="add_column"){check(g["columns"].size()<64,"Column limit reached");Json v={{"id",id("column")},{"name",label(c,"name",std::to_string(g["columns"].size()+1))}};g["columns"].push_back(v);return v;}
    if(action=="add_row"){check(g["rows"].size()<64,"Layer limit reached");Json v={{"id",id("row")},{"name",label(c,"name","Layer")},{"blend","normal"},{"enabled",true},{"clips",Json::object()}};g["rows"].push_back(v);return v;}
    if(action.ends_with("_show")){
        auto active=g["active_show"].get<std::string>();d["showContents"][active]=content(g);
        if(action=="create_show"||action=="duplicate_show"){
            auto sid=id("show");auto source=c.value("show",active);byId(g["shows"],source);
            Json next=action=="duplicate_show"?d["showContents"][source]:content(initial()["grid"]);
            if(action=="create_show"){next["rows"]=Json::array();next["selections"]=Json::object();next["selections_b"]=Json::object();}
            std::map<std::string,std::string> columns,rows;
            for(auto& column:next["columns"]){auto old=column["id"].get<std::string>();column["id"]=id("column");columns[old]=column["id"];}
            for(auto& row:next["rows"]){auto old=row["id"].get<std::string>();row["id"]=id("row");rows[old]=row["id"];Json clips=Json::object();for(auto it=row["clips"].begin();it!=row["clips"].end();++it){auto clip=it.value();clip["id"]=id("clip");clips[columns.at(it.key())]=clip;}row["clips"]=clips;}
            for(const auto* key:{"selections","selections_b"})for(auto& bank:next[key]){Json remapped=Json::object();for(auto it=bank.begin();it!=bank.end();++it)remapped[rows.at(it.key())]=columns.at(it.value().get<std::string>());bank=remapped;}

            for(auto it=g["running"].begin();it!=g["running"].end();++it){if(!next["running"].contains(it.key()))next["running"][it.key()]=true;if(!next["selections"].contains(it.key()))next["selections"][it.key()]=Json::object();if(!next["selections_b"].contains(it.key()))next["selections_b"][it.key()]=Json::object();}
            g["shows"].push_back({{"id",sid},{"name",label(c,"name",action=="create_show"?"New Set":"Set copy")}});g.update(next);g["active_show"]=sid;d["showContents"][sid]=next;return byId(g["shows"],sid);
        }
        auto sid=c.value("show",active);auto& show=byId(g["shows"],sid);
        if(action=="rename_show"){show["name"]=label(c,"name","Show");return show;}
        if(action=="select_show"){g.update(d["showContents"].at(sid));g["active_show"]=sid;return byId(g["shows"],sid);}
        if(action=="delete_show"){check(g["shows"].size()>1,"Keep at least one Set");removeId(g["shows"],sid);d["showContents"].erase(sid);if(sid==active){auto next=g["shows"][0]["id"].get<std::string>();g.update(d["showContents"][next]);g["active_show"]=next;}return {{"deleted",sid}};}
        throw Error(501,"Show action not implemented");
    }
    auto b=bus(g,c);auto& selected=g[c.value("bank",std::string("A"))=="A"?"selections":"selections_b"][b];if(selected.is_null())selected=Json::object();
    if(action=="select_out"||action=="select_cell"){g["control_focus"]["bus"]=b;if(action=="select_cell"){byId(g["rows"],c.at("row"));byId(g["columns"],c.at("column"));g["control_focus"].update({{"row",c["row"]},{"column",c["column"]}});}return g["control_focus"];}
    if(action=="set_crossfade"){g["crossfade"][b]=number(c,"value",0,1);return {{"bus",b},{"value",g["crossfade"][b]}};}
    if(action=="start_out"||action=="stop_out"||action=="toggle_out"){g["running"][b]=action=="toggle_out"?!g["running"][b].get<bool>():action=="start_out";return {{"bus",b},{"running",g["running"][b]}};}
    if(action=="set_fader_sync"){check(c.at("enabled").is_boolean(),"enabled must be boolean");g["fader_sync"]=c["enabled"];return {{"enabled",g["fader_sync"]}};}
    if(action=="set_controller_lights"){auto v=c.value("mode",std::string{});check(v=="full"||v=="dim"||v=="off","Unknown lighting mode");g["controller_lights"]=v;return {{"mode",v}};}
    if(action=="rename_column"||action=="delete_column"||action=="launch_column"||action=="move_column"){
        auto cid=c.at("column").get<std::string>();auto column=byId(g["columns"],cid);
        if(action=="rename_column")byId(g["columns"],cid)["name"]=label(c,"name",column["name"]);
        if(action=="delete_column"){check(g["columns"].size()>1,"Keep at least one column");for(auto& row:g["rows"]){row["clips"].erase(cid);cleanSelections(g,row["id"],cid);}removeId(g["columns"],cid);}
        if(action=="launch_column"){selected=Json::object();for(const auto& row:g["rows"]){if(row["clips"].contains(cid))selected[row["id"].get<std::string>()]=cid;}}
        if(action=="move_column"){auto target=c.at("target").get<std::string>();byId(g["columns"],target);auto position=c.value("position",std::string{});check(position=="before"||position=="after","Invalid position");if(target!=cid){removeId(g["columns"],cid);auto at=std::find_if(g["columns"].begin(),g["columns"].end(),[&](const Json& item){return item["id"]==target;});g["columns"].insert(at+(position=="after"),column);}}return column;
    }
    auto rid=c.at("row").get<std::string>();auto& row=byId(g["rows"],rid);
    if(action=="set_row"){if(c.contains("opacity"))throw Error(400,"Use clip opacity");if(c.contains("name"))row["name"]=label(c,"name",row["name"]);if(c.contains("blend")){blend(c["blend"]);row["blend"]=c["blend"];}if(c.contains("enabled")){check(c["enabled"].is_boolean(),"enabled must be boolean");row["enabled"]=c["enabled"];}return row;}
    if(action=="delete_row"){cleanSelections(g,rid);removeId(g["rows"],rid);return {{"deleted",rid}};}
    if(action=="stop_row"){selected.erase(rid);return {{"row",rid}};}
    if(action=="move_row"){
        Json copy=row;auto& rows=g["rows"];if(c.contains("target")){auto target=c["target"].get<std::string>();byId(rows,target);check(c.value("position",std::string{})=="above"||c.value("position",std::string{})=="below","Invalid position");if(target!=rid){removeId(rows,rid);auto at=std::find_if(rows.begin(),rows.end(),[&](const Json& r){return r["id"]==target;});rows.insert(at+(c["position"]=="above"),copy);}}
        else{auto at=std::find_if(rows.begin(),rows.end(),[&](const Json& r){return r["id"]==rid;});int index=static_cast<int>(at-rows.begin()),direction=c.value("dir",0);check(direction==1||direction==-1,"dir must be -1 or 1");int next=std::clamp(index+direction,0,static_cast<int>(rows.size())-1);std::swap(rows[index],rows[next]);}return copy;
    }
    auto cid=c.at("column").get<std::string>();byId(g["columns"],cid);auto& clips=row["clips"];
    if(action=="put_clip"){
        auto effect=c.at("effect").get<std::string>();auto params=c.value("params",Json::object());if(effect=="text"){if(!TextSource::available())throw Error(501,"Text rasterization is unavailable on this build");params=normalizeTextParams(params);}if(effect.starts_with("external_"))params=modules_.normalize(effect,params);validateParams(effect,params,effectCatalog());
        if((effect=="image"||effect=="video")&&params.contains("file")&&params["file"]!="")check(!media_.resolve(params["file"],effect).empty(),"Media file is unavailable");
        for(const auto& entry:effectCatalog())if(entry["name"]==effect)for(auto it=entry["params"].begin();it!=entry["params"].end();++it)if(!params.contains(it.key()))params[it.key()]=it.value()["default"];
        if(effect=="video"&&params.value("loop_mode",std::string{})=="ping-pong")params["audio_enabled"]=false;
        std::string title=effect;for(const auto& entry:effectCatalog())if(entry["name"]==effect)title=entry["label"];
        clips[cid]={{"id",id("clip")},{"name",label(c,"name",title)},{"gen",effect},{"params",params},{"opacity",1.0}};return clips[cid];
    }
    if(action=="copy_clip"){auto src=c.at("source_column").get<std::string>();check(clips.contains(src),"No source clip");check(!clips.contains(cid),"Destination occupied");clips[cid]=clips[src];clips[cid]["id"]=id("clip");return clips[cid];}
    if(action=="delete_cell"&&!clips.contains(cid)){
        auto& rows=g["rows"];auto at=std::find_if(rows.begin(),rows.end(),[&](const Json& r){return r["id"]==rid;});int index=static_cast<int>(at-rows.begin());std::map<std::string,std::string> destinations;
        for(int i=index;i>0;i--){auto& target=rows[i];auto& source=rows[i-1];destinations[source["id"]]=target["id"];if(source["clips"].contains(cid))target["clips"][cid]=source["clips"][cid];else target["clips"].erase(cid);}rows[0]["clips"].erase(cid);
        for(const auto* key:{"selections","selections_b"})for(auto& bank:g[key]){std::vector<std::string> moving;for(auto it=bank.begin();it!=bank.end();++it)if(it.value()==cid&&destinations.contains(it.key()))moving.push_back(it.key());for(const auto& old:moving)bank.erase(old);for(const auto& old:moving)if(!bank.contains(destinations[old]))bank[destinations[old]]=cid;}return byId(rows,rid);
    }
    if(action=="delete_clip"||action=="delete_cell"){check(clips.contains(cid),"Empty clip slot");clips.erase(cid);cleanSelections(g,rid,cid);return {{"deleted",cid}};}
    check(clips.contains(cid),"No clip in cell");auto& clip=clips[cid];
    if(action=="video_transport"){
        auto operation=c.value("operation",std::string{});
        check(operation=="play"||operation=="pause"||operation=="stop"||operation=="seek"||operation=="range","Unknown video transport operation");
        Json* target=&clip["params"];
        if(clip["gen"]=="media_collection"){
            auto& items=clip["params"]["items"];identifyMediaItems(items);size_t index=items.size();
            if(c.contains("item_id")){check(c["item_id"].is_string(),"item_id must be a string");for(size_t i=0;i<items.size();++i)if(items[i]["id"]==c["item_id"])index=i;}
            else if(c.contains("item_index")){check(c["item_index"].is_number_integer(),"item_index must be an integer");auto n=c["item_index"].get<int>();check(n>=0,"Invalid item_index");index=size_t(n);}
            check(index<items.size(),"Video item required");check(items[index]["type"]=="video","Selected item must be video");
            if(!items[index].contains("params"))items[index]["params"]=Json::object();target=&items[index]["params"];
        }else {check(clip["gen"]=="video","Video clip required");check(!c.contains("item_id")&&!c.contains("item_index"),"Item selector requires a media collection");}
        auto& params=*target;
        if(operation=="play"||operation=="pause"||operation=="stop")params["playing"]=operation=="play";
        if(operation=="range"){
            double start=c.contains("loop_start")?number(c,"loop_start",0,1):params.value("loop_start",0.);
            double end=c.contains("loop_end")?number(c,"loop_end",0,1):params.value("loop_end",1.);
            check(start<end,"Video loop start must be before end");params["loop_start"]=start;params["loop_end"]=end;
        }
        if(operation=="stop"||operation=="seek"||operation=="range"){params["position"]=operation=="seek"?number(c,"position",0,1):0.0;params["seek_nonce"]=std::fmod(params.value("seek_nonce",0.0)+1.,1000000.);}
        return clip;
    }
    if(action=="launch_clip"||action=="toggle_clip"){if(action=="toggle_clip"&&selected.value(rid,std::string{})==cid)selected.erase(rid);else selected[rid]=cid;return clip;}
    if(action=="set_clip"){
        if(c.contains("params")){auto p=clip["params"];check(c["params"].is_object(),"params must be object");p.update(c["params"]);if(clip["gen"]=="text")p=normalizeTextParams(p);if(clip["gen"].get<std::string>().starts_with("external_"))p=modules_.normalize(clip["gen"],p);validateParams(clip["gen"],p,effectCatalog());auto effect=clip["gen"].get<std::string>();if((effect=="image"||effect=="video")&&c["params"].contains("file")&&p["file"]!="")check(!media_.resolve(p["file"],effect).empty(),"Media file is unavailable");if(effect=="video"&&p.value("loop_mode",std::string{})=="ping-pong")p["audio_enabled"]=false;clip["params"]=p;clip.erase("nativeImportUnsupported");}
        if(c.contains("patchControls")){
            auto bindings=c["patchControls"];check(bindings.is_object(),"patchControls must be an object");
            const auto effects=effectCatalog();auto spec=std::find_if(effects.begin(),effects.end(),[&](const Json& e){return e["name"]==clip["gen"];});
            for(auto it=bindings.begin();it!=bindings.end();++it){check(spec!=effects.end()&&!(*spec).value("vector",false)&&!clip["gen"].get<std::string>().starts_with("external_")&&(*spec)["params"].contains(it.key())&&(*spec)["params"][it.key()]["type"]=="float","Patch control requires a continuous parameter");auto p=(*spec)["params"][it.key()];check(it.value().is_object()&&it.value().value("source",std::string{}).starts_with("patch:"),"Invalid Patch control source");number(it.value(),"min",p["min"],p["max"]);number(it.value(),"max",p["min"],p["max"]);}
            clip["patchControls"]=bindings;
        }
        if(c.contains("name"))clip["name"]=label(c,"name",clip["name"]);
        if(c.contains("opacity"))clip["opacity"]=number(c,"opacity",0,1);
        if(c.contains("blend")){blend(c["blend"]);clip["blend"]=c["blend"];}
        if(c.contains("collectionLayout")){const auto layout=c["collectionLayout"];check(layout=="auto"||layout=="repeat"||layout=="span","collectionLayout must be auto, repeat or span");if(layout=="auto")clip.erase("collectionLayout");else clip["collectionLayout"]=layout;}return clip;
    }
    throw Error(501,"Grid action not implemented: "+action);
}
std::optional<Reply> Model::calibrationRequest(const std::string& method,const std::string& path,const Json& body){
    if(!path.starts_with("/api/calibration/")&&path!="/api/calibrations"&&!path.starts_with("/api/calibrations/")&&path!="/api/mapping/displays")return std::nullopt;
    const bool read=method=="GET"||method=="HEAD";
    auto displays=[&](){std::lock_guard lock(mutex_);return outputSnapshot(document_,outputRuntime_)["projectors"];};
    auto status=[&](){auto reported=displays();return calibration_.status(reported["displays"],reported.value("vectors",Json::object()));};
    auto changed=[&](){std::lock_guard lock(mutex_);++runtimeRevision_;};
    auto waitPresented=[&](uint64_t revision){
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(5);
        while(!calibration_.presented(revision)){
            if(std::chrono::steady_clock::now()>=deadline)throw Error(409,"Native renderer did not present the pattern");
            std::this_thread::sleep_for(std::chrono::milliseconds(15));
        }
    };
    try{
        if(path=="/api/mapping/displays"){if(!read)throw Error(405,"Method not allowed");return Reply{200,status()};}
        if(path=="/api/calibration/projector"){
            if(read){calibration_.touch(controlNow());return Reply{200,status()};}
            if(method!="POST")throw Error(405,"Method not allowed");
            std::lock_guard operation(calibrationRequestMutex_);
            auto command=calibration_.projector(body,displays()["displays"],controlNow());changed();
            if(body.value("op",std::string{})=="exit")stopCalibrationCamera();
            waitPresented(command.at("revision"));return Reply{200,status()};
        }
        if(path=="/api/calibration/cameras"){
            if(!read)throw Error(405,"Method not allowed");
            const auto sources=liveSources_.discover("cameras");
            if(!sources.value("available",false))throw Error(503,sources.value("error",std::string("Camera discovery unavailable")));
            Json devices=Json::array();for(const auto& source:sources.value("sources",Json::array())){
                auto device=source.value("device",source.value("selection",std::string{}));
                if(!device.empty())devices.push_back({{"id",device},{"label",source.value("label",device)}});
            }
            return Reply{200,{{"devices",devices}}};
        }
        if(path=="/api/calibration/camera/start"){
            if(method!="POST")throw Error(405,"Method not allowed");
            std::lock_guard operation(calibrationRequestMutex_);
            const auto input=body.value("device",Json("0"));
            if(!input.is_string()&&!input.is_number_integer())throw Error(409,"Invalid camera");
            const auto device=normalizeLiveSelection("usb_webcam",input.is_string()?input.get<std::string>():input.dump());
            if(device.empty())throw Error(409,"Invalid camera");
            if(!calibrationCameraAvailable())throw Error(501,"Camera capture unavailable in this runtime");
            {std::lock_guard lock(mutex_);if(!outputRuntime_.value("rendererConnected",false))throw Error(409,"Native renderer is not connected");}
            auto started=calibration_.startCamera(device,calibrationInstance_,controlNow());changed();
            startCalibrationCamera(device,calibrationInstance_);
            waitPresented(started.at("revision"));started.erase("revision");return Reply{200,started};
        }
        if(path=="/api/calibration/camera/frame"){
            if(!read)throw Error(405,"Method not allowed");calibration_.touch(controlNow());
            const auto generation=body.value("generation",std::string{});
            if(generation.empty()||generation!=calibration_.cameraGeneration())throw Error(409,"Camera changed. Reconnect.");
            uint64_t after=0;const auto value=body.value("after",Json("0"));
            const auto number=value.is_string()?value.get<std::string>():value.dump();
            if(number.empty()||number.find_first_not_of("0123456789")!=std::string::npos)throw Error(400,"after must be a nonnegative integer");
            try{after=std::stoull(number);}catch(...){throw Error(400,"Invalid frame sequence");}
            const bool fresh=body.value("fresh",Json())=="1";const auto requested=calibrationTimeNs();
            const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(8);
            while(std::chrono::steady_clock::now()<deadline){
                if(generation!=calibration_.cameraGeneration())throw Error(409,"Camera changed. Reconnect.");
                const auto frame=latestCalibrationCameraFrame();const auto now=calibrationTimeNs();
                if(frame&&frame->generation==generation&&frame->sequence>after&&frame->timestampNs<=now&&now-frame->timestampNs<=2000000000ULL&&(!fresh||frame->timestampNs>requested+80000000ULL)){
                    if(frame->width<=0||frame->height<=0||frame->width>8192||frame->height>8192||!frame->rgba||frame->rgba->size()!=size_t(frame->width)*frame->height*4)throw Error(503,"Invalid camera frame");
                    auto bytes=frames_.encodeImage({frame->width,frame->height,frame->sequence,std::chrono::steady_clock::now(),frame->rgba,4},{frame->width,frame->height,94,false});
                    if(bytes.empty())throw Error(503,"Camera frame encoding failed");
                    return Reply{200,Json(),std::string(bytes.begin(),bytes.end()),"image/jpeg",{{"X-Camera-Generation",generation},{"X-Frame-Sequence",std::to_string(frame->sequence)},{"X-Frame-Timestamp-Ns",std::to_string(frame->timestampNs)},{"X-Request-Timestamp-Ns",std::to_string(requested)}}};
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(25));
            }
            const auto error=calibrationCameraError();throw Error(503,error.empty()?"No camera frames from native renderer":error);
        }
        if(path=="/api/calibrations"){
            if(read)return Reply{200,calibration_.library()};
            if(method!="POST")throw Error(405,"Method not allowed");return Reply{200,calibration_.save(body.at("calibration"))};
        }
        if(path=="/api/calibrations/revisions"){
            if(!read)throw Error(405,"Method not allowed");std::lock_guard lock(mutex_);Json revisions=Json::object();
            for(auto it=document_["mappings"].begin();it!=document_["mappings"].end();++it)revisions[it.key()]=it.value()["revision"];
            return Reply{200,revisions};
        }
        if(path=="/api/calibrations/load"){
            if(method!="POST")throw Error(405,"Method not allowed");std::lock_guard operation(calibrationRequestMutex_);std::lock_guard lock(mutex_);
            auto replacements=calibration_.prepareLoad(body.value("revisions",Json::object()),document_["mappings"],outputSnapshot(document_,outputRuntime_)["projectors"]["displays"],controlNow());
            auto next=document_;auto histories=mappingHistories_;auto selection=selection_;Json ids=Json::array();
            for(auto it=replacements.begin();it!=replacements.end();++it){
                auto project=it.value();validateMappingProject(project);auto& mapping=next["mappings"][it.key()];auto& history=histories[it.key()];
                history.undo.push_back({{"project",mapping["project"]},{"layoutId",mapping.value("layoutId",std::string{})}});
                if(history.undo.size()>100)history.undo.erase(history.undo.begin());history.redo.clear();history.mergeKey.clear();
                mapping["project"]=std::move(project);mapping["revision"]=mapping["revision"].get<uint64_t>()+1;
                Json selected=Json::array();if(mapping["project"].value("selectedRectId",Json()).is_string())selected.push_back(mapping["project"]["selectedRectId"]);
                selection[it.key()]={{"ids",selected},{"traceId",nullptr},{"revision",selection.value(it.key(),Json::object()).value("revision",0)+1}};ids.push_back(it.key());
            }
            reconcileMappingTraceFixtures(next);next["revision"]=document_["revision"].get<uint64_t>()+1;persist(next);
            document_=std::move(next);mappingHistories_=std::move(histories);selection_=std::move(selection);calibration_.loaded();++runtimeRevision_;
            return Reply{200,{{"mappings",ids}}};
        }
        throw Error(404,"Calibration route not found");
    }catch(const Error& error){return Reply{error.status,{{"error",error.what()}}};}
    catch(const std::exception& error){const bool conflict=path=="/api/calibrations/load"||path=="/api/calibration/projector"||path=="/api/calibration/camera/start";return Reply{conflict?409:400,{{"error",error.what()}}};}
}
Reply Model::request(const std::string& method,const std::string& path,const Json& body){
    if(path=="/api/v1/grid"&&method=="POST"&&body.is_object()&&(body.contains("subpatchID")||body.value("action",Json())=="make_independent")){
        if(!libraryRequest_)return {501,{{"error","Subpatch placement requires an embedded Patch editor"}}};
        return libraryRequest_(method,"/v1/library/place",body);
    }
    if(path=="/api/v1/library/favorites"||path=="/api/v1/library/subpatches"){
        if(!libraryRequest_)return {501,{{"error","Patch library is unavailable in this host"}}};
        return libraryRequest_(method,path.substr(4),body);
    }
    if(path.starts_with("/api/v1/mappings/")&&path.ends_with("/editor-visibility")){
        try{
            std::lock_guard lock(mutex_);auto p=parts(path);check(p.size()==5,"Unknown editor visibility route");const auto mid=p.at(3);check(document_["mappings"].contains(mid),"Unknown mapping");const auto& project=document_["mappings"][mid]["project"];
            auto state=mappingEditorVisibility(project,editorVisibility_.value(mid,Json::object()));
            if(method=="GET")return {200,state};check(method=="POST","Use GET or POST");check(body.is_object(),"Expected an object");const auto action=body.value("action",std::string{});
            check(action=="hide"||action=="show"||action=="solo"||action=="show_all"||action=="clear_solo","Unknown editor visibility action");
            Json rects=Json::array(),traces=Json::array();if(action=="hide"||action=="show"||action=="solo"){
                rects=mappingIds(project,body.value("rectIds",Json::array()),true);const auto requested=body.value("traceIds",Json::array());check(requested.is_array(),"traceIds must be an array");
                for(const auto& id:requested){check(id.is_string(),"traceIds must contain text");bool found=false;for(const auto& trace:project["traces"])found|=trace["id"]==id;check(found,"Unknown trace");if(std::find(traces.begin(),traces.end(),id)==traces.end())traces.push_back(id);}
                check(!rects.empty()||!traces.empty(),"Select an object");
            }
            if(action=="show_all")state=mappingEditorVisibility(project,Json::object());
            else if(action=="clear_solo"){state["solo"]=false;state["soloRectIds"]=Json::array();state["soloTraceIds"]=Json::array();}
            else{
                if(action=="solo"){state["solo"]=true;state["soloRectIds"]=rects;state["soloTraceIds"]=traces;}
                for(int type=0;type<2;type++){
                    auto ids=type?traces:rects;auto& hidden=state[type?"hiddenTraceIds":"hiddenRectIds"];auto& solo=state[type?"soloTraceIds":"soloRectIds"];
                    for(const auto& id:ids){hidden.erase(std::remove(hidden.begin(),hidden.end(),id),hidden.end());if(action=="hide")hidden.push_back(id);else if(action=="show"&&state["solo"]==true&&std::find(solo.begin(),solo.end(),id)==solo.end())solo.push_back(id);}
                }
            }
            auto next=editorVisibility_;next[mid]=state;const auto temp=directory_/"mapper-visibility.json.tmp";
            {std::ofstream out(temp);out<<Json{{"format","vj-mapper-visibility/1"},{"mappings",next}}.dump(2)<<'\n';out.close();check(out.good(),"Cannot save Mapper visibility");}std::filesystem::rename(temp,directory_/"mapper-visibility.json");
            editorVisibility_=std::move(next);++editorVisibilityRevision_;++runtimeRevision_;return {200,state};
        }catch(const ApiError& e){return {e.status,{{"error",e.what()}}};}catch(const std::exception& e){return {400,{{"error",e.what()}}};}
    }

    if(path.starts_with("/api/v1/mappings/")&&path.ends_with("/preview")){
        try{
            auto p=parts(path);const auto mid=p.at(3);check(p.size()==5,"Unknown mapping preview route");check(method=="POST"||method=="DELETE","Use POST or DELETE");
            // Validation/mesh normalization can be expensive. Do it before taking
            // the document lock shared with rendering, then recheck the revision.
            auto preview=method=="POST"?prepareMappingPreview(mid,body):Json();auto owner=body.value("_owner",std::string{});
            std::lock_guard lock(mutex_);check(document_["mappings"].contains(mid),"Unknown mapping");
            if(method=="POST"&&preview["baseRevision"]!=document_["mappings"][mid]["revision"])throw Error(409,"stale mapping revision");
            auto& entry=selection_[mid];if(!entry.is_object())entry=Json::object();
            if(method=="DELETE"){if(entry.contains("preview")&&entry.value("previewOwner",std::string{})==owner){if(!entry["preview"].contains("markers"))selection_["_scenePreviewRevision"]=selection_.value("_scenePreviewRevision",uint64_t(0))+1;entry.erase("preview");entry.erase("previewOwner");selection_["_previewRevision"]=selection_.value("_previewRevision",uint64_t(0))+1;}return {200,{{"cleared",true}}};}
            if(!preview.contains("markers")||(entry.contains("preview")&&!entry["preview"].contains("markers")))selection_["_scenePreviewRevision"]=selection_.value("_scenePreviewRevision",uint64_t(0))+1;entry["preview"]=preview;entry["previewOwner"]=owner;selection_["_previewRevision"]=selection_.value("_previewRevision",uint64_t(0))+1;return {200,preview};
        }catch(const ApiError& error){return {error.status,{{"error",error.what()}}};}
        catch(const std::exception& error){return {400,{{"error",error.what()}}};}
    }
    if(method=="GET"&&path=="/api/v1/sources/patch")return {200,{{"sources",patchOutputs()},{"consumed",patchReferences()}}};
    if(method=="GET"&&path=="/api/v1/sources/palettes")return {200,{{"sources",paletteSources()}}};
    if(path=="/api/v1/playback")return method=="GET"?Reply{200,playbackRuntime()}:Reply{405,{{"error","Use GET"}}};
    std::unique_lock storeGate(migrationStoreMutex_,std::defer_lock);if(path.starts_with("/api/v1/animations")||path.starts_with("/vector/modules/external/")||path.starts_with("/api/v1/effects/external_")||path.starts_with("/api/calibrations"))storeGate.lock();
    if(path=="/api/v1/ndi/clients"||path.starts_with("/api/v1/ndi/clients/")){
        try{if(auto result=ndiClients_.request(method,path,body))return {200,*result};return {404,{{"error","Unknown receiver route"}}};}
        catch(const ApiError& e){return {e.status,{{"error",e.what()}}};}
        catch(const std::invalid_argument& e){return {400,{{"error",e.what()}}};}
        catch(const std::exception& e){return {409,{{"error",e.what()}}};}
    }
    // The DMX controller lease is UI/runtime state, not a persistent show edit.
    if(path=="/api/v1/dmx"&&(method=="POST"||method=="PATCH")&&body.is_object()&&body.size()==1&&body.contains("apc_active")){
        if(!body["apc_active"].is_boolean())return {400,{{"error","apc_active must be boolean"}}};
        std::lock_guard lock(mutex_);document_["controls"]["dmx"]["_apc_until"]=body["apc_active"].get<bool>()?controlNow()+5:0.;++runtimeRevision_;return {200,snapshotUnlocked()["state"]["dmx"]};
    }
    if(path=="/api/v1/fixture-output/discover"){
        if(method!="POST")return {405,{{"error","Use POST"}}};
        try{Json configured;{std::lock_guard lock(mutex_);configured=document_["controls"].value("fixtureOutput",Json::object());}
            return {200,network_.discoverWled(configured)};
        }catch(const std::exception& e){return {409,{{"error",e.what()}}};}
    }
    if(path=="/api/v1/stats"||path=="/api/v1/network"){
        if(method!="GET")return {405,{{"error","Use GET"}}};
        try{Json controls,metrics,ui;int count;{std::lock_guard lock(mutex_);controls=document_["controls"];controls["fixtureOutput"].update(controlRuntime_.value("fixtureOutput",Json::object()));count=document_["outputCount"];metrics=controlRuntime_.value("renderer",Json::object());ui=controlRuntime_.value("ui",Json::object());}
            if(path=="/api/v1/stats"){auto result=network_.stats(count,metrics);result["ui"]=ui;return {200,result};}
            return {200,network_.network(controls.value("fixtureOutput",Json::object()),controls.value("fixtures",Json::array()),apiPort_,body.value("probe",Json())!="0"&&body.value("probe",Json())!=false)};
        }catch(const std::exception& e){return {500,{{"error",e.what()}}};}
    }
    if(path=="/api/calibration/debug"||path.starts_with("/api/calibration/debug/")){
        try{if(auto response=calibrationDebugRequest(directory_/"calibration-scans",method,path,body,[this](const FrameImage& image,const FrameEncoding& encoding){return frames_.encodeImage(image,encoding);})){std::optional<std::string> bytes;if(response->bytes)bytes=std::string(response->bytes->begin(),response->bytes->end());return {response->status,response->body,std::move(bytes),response->contentType};}}
        catch(const ApiError& error){return {error.status,{{"error",error.what()}}};}catch(const std::exception& error){return {400,{{"error",error.what()}}};}
    }
    if(auto reply=calibrationRequest(method,path,body))return *reply;
    // Discovery is explicit and may wait on a helper; do not block rendering/state reads.
    if(method=="GET"&&(path=="/api/v1/sources/ndi"||path=="/api/v1/sources/syphon"||path=="/api/cameras")){
        try{return {200,liveSources_.discover(path=="/api/cameras"?"cameras":path.substr(path.find_last_of('/')+1),body.value("extra_ips",std::string{}))};}
        catch(const std::exception& e){return {400,{{"error",e.what()}}};}
    }
    if(path.starts_with("/api/v1/animations")){
        try{if(auto reply=modules_.request(method,path,body)){
            if(!reply->changedEffect.empty()){std::lock_guard lock(mutex_);auto next=document_;reconcileUploaded(next);next["revision"]=document_["revision"].get<uint64_t>()+1;persist(next);document_=std::move(next);frames_.setActiveOutputs(document_["outputCount"]);frames_.setStreamHD(document_["controls"].value("stream_hd",false));}
            return {reply->status,reply->body};
        }}catch(const std::exception& error){return {500,{{"error",error.what()}}};}
    }
    if(method=="GET"&&((path.starts_with("/api/v1/animations/")&&path.ends_with("/wasm"))||path.starts_with("/vector/modules/external/")||(path.starts_with("/api/v1/effects/external_")&&path.ends_with("/wasm")))){
        try{std::string id,version;if(path.starts_with("/vector/")){const auto route=parts(path);check(route.size()==4||route.size()==5,"Invalid module path");if(route.size()==4){id=route[3];check(id.ends_with(".wasm"),"Invalid module path");id.resize(id.size()-5);}else{id=route[3];version=route[4];check(version.ends_with(".wasm"),"Invalid module path");version.resize(version.size()-5);}}else if(path.starts_with("/api/v1/effects/")){id=path.substr(25,path.size()-30);}else{id=path.substr(19,path.size()-24);}
            std::ifstream in(modules_.modulePath(id,version),std::ios::binary);if(!in)throw std::runtime_error("Module unavailable");return {200,Json(),std::string((std::istreambuf_iterator<char>(in)),{}),"application/wasm"};
        }catch(const std::exception& error){return {404,{{"error",error.what()}}};}
    }
    if(method=="GET"&&(path=="/api/v1/effects"||(path.starts_with("/api/v1/effects/")&&!path.ends_with("/wasm")))){
        try{auto effects=effectCatalog();auto library=media_.catalog();for(auto& effect:effects){auto name=effect.value("name",std::string{});if(name!="image"&&name!="video")continue;Json files=Json::array();for(const auto& item:library["items"])if(item["type"]==name)files.push_back(item["file"]);for(auto& parameter:effect["parameters"])if(parameter["name"]=="file")parameter["choices"]=files;}
            if(path=="/api/v1/effects")return {200,externalEffectsResponse(effects,vectorModuleValidatorAvailable())};
            for(auto effect:effects)if(effect["name"]==path.substr(16)){effect.erase("title");effect.erase("params");return {200,effect};}return {404,{{"error","Unknown effect"}}};
        }catch(const std::exception& e){return {500,{{"error",e.what()}}};}
    }
    try{if(auto response=media_.request(method,path,body))return {method=="POST"&&path=="/api/v1/media/preprocess"?202:200,*response};}
    catch(const ApiError& error){return {error.status,{{"error",error.what()}}};}
    catch(const Json::exception& error){return {400,{{"error",error.what()}}};}
    catch(const std::invalid_argument& error){return {400,{{"error",error.what()}}};}
    catch(const std::exception& error){return {500,{{"error",error.what()}}};}
    std::lock_guard lock(mutex_);
    try{

        if(path.starts_with("/api/v1/mappings/")&&path.ends_with("/selection")){
            auto p=parts(path);const auto mid=p.at(3);check(document_["mappings"].contains(mid),"Unknown mapping");
            if(method=="PUT"&&(!body.contains("_releaseOwner")||selection_.value(mid,Json::object()).value("owner",std::string{})==body.value("_releaseOwner",std::string{}))){
                auto ids=Json::array();Json trace=nullptr;
                if(body.contains("traceId")){trace=body["traceId"];check(trace.is_null()||trace.is_string(),"traceId must be text or null");if(!trace.is_null()){bool found=false;for(const auto& item:document_["mappings"][mid]["project"]["traces"])found=found||item["id"]==trace;check(found,"Unknown trace");}}
                else ids=mappingIds(document_["mappings"][mid]["project"],body.at("rectIds"),true);
                auto old=selection_.value(mid,Json::object());old.update({{"ids",ids},{"traceId",trace},{"owner",body.value("_owner",std::string{})},{"revision",old.value("revision",0)+1}});selection_[mid]=std::move(old);document_["revision"]=document_["revision"].get<uint64_t>()+1;
            }
            else check(method=="GET"||method=="PUT","Use GET or PUT");
            auto selected=snapshotUnlocked()["mappings"][mid];return {200,{{"mappingId",mid},{"rectIds",selected["selectedRectIds"]},{"traceId",selected["project"].value("selectedTraceId",Json())}}};
        }
        if(method=="GET"){
            if(path=="/api/v1/meta-mapping")return {200,snapshotUnlocked()["metaMapping"]};
            if(path=="/api/v1"||path=="/api/v1/"||path=="/api/v1/capabilities"||path=="/api/v1/docs"||path.starts_with("/api/v1/sdk/"))return *apiCompatibilityReply(method,path,snapshotUnlocked(),effectCatalog(),defaultApiAssetRoot());
            auto copy=document_;if(auto room=requestRoom(copy,method,path,body))return {200,*room};if(auto link=linkRequest(copy,method,path,body,controlRuntime_.value("link",Json::object())))return {200,*link};if(auto fixture=fixtureOutputRequest(copy,method,path,body,controlRuntime_))return {200,*fixture};
            if(isOutputRoute(path)){auto copy=document_;return {200,*requestOutput(copy,method,path,body,outputRuntime_)};}
            if(path=="/api/v1/text/fonts"||path=="/api/text/fonts")return {200,textSource_.fonts()};
            if(path=="/api/v1/stream")return {200,snapshotUnlocked()["state"]["stream"]};
            if(path=="/api/v1/sources/capabilities")return {200,liveSources_.capabilities()};
            if(path=="/api/v1/midi/hooks"){auto runtime=controlRuntime_.value("midi",Json::object());auto device=runtime.value("connected",Json());return {200,{{"hooks",midiControlHooks(document_,effectCatalog(),device.is_string()&&isApc40(device.get<std::string>()),patchChannelFaderFollow_.load(),patchCrossfaderFollow_.load())},{"revision",document_["revision"]},{"channelNumbering","zero-based"}}};}
            if(isControlRoute(path)){auto copy=document_;auto result=*requestControl(copy,method,path,body);if(path=="/api/v1/midi"){result.update(controlRuntime_.value("midi",Json::object()));auto device=result.value("connected",Json());result["controlHooks"]=midiControlHooks(document_,effectCatalog(),device.is_string()&&isApc40(device.get<std::string>()),patchChannelFaderFollow_.load(),patchCrossfaderFollow_.load());}if(path=="/api/v1/clock")result=snapshotUnlocked()["state"]["clock"];return {200,result};}
            if(path.starts_with("/api/v1/mapping-layouts")||path.starts_with("/api/v1/mappings/")){
                auto p=parts(path);if(p[2]=="mappings"&&p.size()==4)return {200,snapshotUnlocked()["mappings"].at(p[3])};
                auto copy=document_;return {200,mappingRequest(copy,method,p,body)};
            }
            if(path=="/health")return {200,{{"app","VJ"},{"featureParity",false}}};
            if(path=="/api/v1/state")return {200,snapshotUnlocked()};
            if(path=="/api/v1/grid")return {200,{{"grid",snapshotUnlocked()["state"]["grid"]},{"revision",document_["revision"]},{"result",nullptr}}};
            if(path=="/api/v1/effects")return {200,externalEffectsResponse(effectCatalog(),vectorModuleValidatorAvailable())};
            if(path.starts_with("/api/v1/effects/")){auto name=path.substr(16);for(auto effect:effectCatalog())if(effect["name"]==name){effect.erase("title");effect.erase("params");return {200,effect};}throw Error(404,"Unknown effect");}
            throw Error(404,"Route not implemented in native development app");
        }
        check(body.is_object(),"Expected object");
        if(body.contains("revision")&&!isRoomRoute(path)&&path.find("/mappings/")==std::string::npos&&path.find("/mapping-layouts")==std::string::npos&&body["revision"]!=document_["revision"])return {409,{{"error","State changed"},{"revision",document_["revision"]}}};
        if(method=="POST"&&((path=="/api/v1/midi"&&body.value("action",std::string{})=="midi_fader_position")||(path=="/api/v1/grid"&&body.value("action",std::string{})=="set_crossfade"))){
            const double value=number(body,"value",0,1);const bool hardware=path=="/api/v1/midi";
            auto& grid=document_["grid"];std::optional<std::string> output;
            if(hardware){for(auto it=body.begin();it!=body.end();++it)check(it.key()=="action"||it.key()=="value"||it.key()=="revision","Unknown MIDI field: "+it.key());if(grid.value("fader_sync",false))output=grid["control_focus"].value("bus",std::string("program"));}
            else{if(body.contains("active_show"))check(body["active_show"]==grid["active_show"],"Active show changed");check(body.value("bank",std::string("A"))=="A"||body["bank"]=="B","Bank must be A or B");output=bus(grid,body);}
            applyFaderUnlocked(value,output,hardware);
            if(hardware)return {200,document_["controls"]["midi"]};
            return {200,{{"grid",snapshotUnlocked()["state"]["grid"]},{"revision",document_["revision"]},{"result",{{"bus",*output},{"value",value}}}}};
        }
        // Focus changes neither show content nor render inputs. Keep the same
        // validation, revision and durable-save contract without rebuilding
        // unrelated geometry, effect schemas or undo histories.
        if(path=="/api/v1/grid"&&method=="POST"&&(body.value("action",std::string{})=="select_cell"||body.value("action",std::string{})=="select_out")){
            auto next=document_;auto result=gridCommand(next,body);
            if(next!=document_){const auto old=document_["revision"].get<uint64_t>();next["revision"]=old+1;persist(next);document_=std::move(next);
                if(mappingsRevision_==old)mappingsRevision_=old+1;
                if(gridRevision_==old){cachedGrid_["control_focus"]=document_["grid"]["control_focus"];gridRevision_=old+1;}
            }
            return {200,{{"grid",snapshotUnlocked()["state"]["grid"]},{"revision",document_["revision"]},{"result",result}}};
        }
        Json next=document_,result;if(!externalClock_.empty())next["controls"]["clock"].update(externalClock_);auto histories=histories_;auto mappingHistories=mappingHistories_;
        if(path=="/api/v1/meta-mapping"){check(method=="POST","Use POST");result=metaMappingCommand(next,body);}
        else if(mappingCompatibilityRoute(path)){
            check(method=="POST","Use POST");result=mappingCompatibilityCommand(next,path,body);
            for(auto it=next["mappings"].begin();it!=next["mappings"].end();++it)if(it.value()["revision"]!=document_["mappings"][it.key()]["revision"]){auto& history=mappingHistories[it.key()];history.undo.push_back({{"project",document_["mappings"][it.key()]["project"]},{"layoutId",document_["mappings"][it.key()].value("layoutId",std::string{})}});if(history.undo.size()>100)history.undo.erase(history.undo.begin());history.redo.clear();history.mergeKey.clear();}
        }
        else if(auto room=requestRoom(next,method,path,body)){result=*room;for(auto it=next["mappings"].begin();it!=next["mappings"].end();++it)if(it.value()["project"]!=document_["mappings"][it.key()]["project"]){auto& history=mappingHistories[it.key()];history.undo.push_back({{"project",document_["mappings"][it.key()]["project"]},{"layoutId",document_["mappings"][it.key()].value("layoutId",std::string{})}});if(history.undo.size()>100)history.undo.erase(history.undo.begin());history.redo.clear();}}
        else if(path=="/api/v1/clock"&&body.value("action",std::string{})=="link_sync"){result=*linkRequest(next,"POST","/api/v1/link",{{"action","set_sync"},{"enabled",body.at("enabled")}},controlRuntime_.value("link",Json::object()));}
        else if(auto link=linkRequest(next,method,path,body,controlRuntime_.value("link",Json::object()))){result=*link;}
        else if(auto fixture=fixtureOutputRequest(next,method,path,body,controlRuntime_)){result=*fixture;}
        else if(path=="/api/v1/flash"&&method=="POST"){next["controls"]["_flash_at"]=controlNow();result={{"triggered",true}};}
        else if(isOutputRoute(path)){result=*requestOutput(next,method,path,body,outputRuntime_);}
        else if(isControlRoute(path)){result=*requestControl(next,method,path,body);}
        else if(path=="/api/v1/grid"&&method=="POST"){
            const auto action=body.value("action",std::string{});
            auto& history=histories[next["grid"]["active_show"].get<std::string>()];auto& undo=history.undo;auto& redo=history.redo;
            if(action=="undo"||action=="redo"){
                auto& from=action=="undo"?undo:redo;auto& to=action=="undo"?redo:undo;
                if(!from.empty()){to.push_back(content(next["grid"]));next["grid"].update(from.back());from.pop_back();}history.mergeKey.clear();result={{"can_undo",!undo.empty()},{"can_redo",!redo.empty()}};
            }else{
                result=gridCommand(next,body);
                if(action.ends_with("_show")){for(auto& [sid,h]:histories){(void)sid;h.mergeKey.clear();}}
                else if(action!="select_out"&&action!="select_cell"){
                    const auto before=content(document_["grid"]),after=content(next["grid"]);
                    if(before!=after){
                        std::string key;
                        if(action=="set_crossfade")key=Json::array({action,bus(next["grid"],body)}).dump();
                        if(action=="set_clip"||action=="set_row"){
                            Json fields=Json::array();if(body.contains("params"))for(auto it=body["params"].begin();it!=body["params"].end();++it)fields.push_back(it.key());
                            for(const auto* field:{"opacity","blend","enabled","name"})if(body.contains(field))fields.push_back(field);
                            key=Json::array({action,body.value("row",std::string{}),body.value("column",std::string{}),fields}).dump();
                        }
                        const auto now=std::chrono::steady_clock::now();
                        const bool merge=!key.empty()&&key==history.mergeKey&&!undo.empty()&&redo.empty()&&history.last==before&&now-history.edited<std::chrono::milliseconds(800);
                        if(!merge){undo.push_back(before);if(undo.size()>100)undo.erase(undo.begin());}
                        redo.clear();history.last=after;history.mergeKey=key;history.edited=now;
                    }
                }
            }
            reconcileGrid(next);auto sid=next["grid"]["active_show"].get<std::string>();next["showContents"][sid]=content(next["grid"]);
        }else if(path.starts_with("/api/v1/outputs/")&&method=="POST"){
            const auto now=controlNow();const auto before=content(next["grid"]);
            result=applyCompositionCommand(next,path.substr(16),body,effectCatalog(),[&](Json& transaction,const Json& command){return gridCommand(transaction,command);},now,controlClock(next,now)["beat"]);
            if(before!=content(next["grid"])){auto& history=histories[next["grid"]["active_show"].get<std::string>()];history.undo.push_back(before);if(history.undo.size()>100)history.undo.erase(history.undo.begin());history.redo.clear();history.mergeKey.clear();}
            next["showContents"][next["grid"]["active_show"].get<std::string>()]=content(next["grid"]);
        }else if(path=="/api/v1/outputs"&&method=="PUT"){
            check(body.at("count").is_number_integer(),"count must be integer");int count=number(body,"count",1,20);next["outputCount"]=count;auto& g=next["grid"];
            for(int i=1;i<=20;i++){auto b=i==1?"program":"out"+std::to_string(i);if(i<=count){if(!g["running"].contains(b)){g["running"][b]=true;g["selections"][b]=Json::object();g["selections_b"][b]=Json::object();g["crossfade"][b]=0;}}else for(const auto* key:{"running","selections","selections_b","crossfade"})g[key].erase(b);}result={{"count",count}};
        }else if(path.starts_with("/api/v1/mappings/")||path.starts_with("/api/v1/mapping-layouts")){
            auto p=parts(path);const bool undo=p.size()==5&&(p[4]=="undo"||p[4]=="redo");
            auto mappingContent=[](const Json& m){return Json{{"project",m["project"]},{"layoutId",m.value("layoutId",std::string{})}};};
            if(undo){
                check(method=="POST","Use POST");auto& m=next["mappings"].at(p[3]);if(!body.contains("revision")||body["revision"]!=m["revision"])throw Error(409,"Mapping changed");
                auto& h=mappingHistories[p[3]];auto& from=p[4]=="undo"?h.undo:h.redo;auto& to=p[4]=="undo"?h.redo:h.undo;
                if(!from.empty()){to.push_back(mappingContent(m));m.update(from.back());from.pop_back();m["revision"]=m["revision"].get<uint64_t>()+1;}result=mappingSnapshot(next,p[3]);
            }else{
                result=mappingRequest(next,method,p,body);
                for(auto it=next["mappings"].begin();it!=next["mappings"].end();++it)if(it.value()["project"]!=document_["mappings"][it.key()]["project"]){auto& h=mappingHistories[it.key()];h.undo.push_back(mappingContent(document_["mappings"][it.key()]));if(h.undo.size()>100)h.undo.erase(h.undo.begin());h.redo.clear();}
            }
        }
        else throw Error(501,"Command not implemented in native development app");
        reconcileGrid(next);reconcileMappingTraceFixtures(next);
        const auto now=controlNow();reconcileCompositionApi(next,now,controlClock(next,now)["beat"],false,path=="/api/v1/grid"?body:Json::object());
        reconcileMetaMapping(next);
        if(next!=document_){next["revision"]=document_["revision"].get<uint64_t>()+1;persist(next);document_=std::move(next);frames_.setActiveOutputs(document_["outputCount"]);frames_.setStreamHD(document_["controls"].value("stream_hd",false));histories_=std::move(histories);mappingHistories_=std::move(mappingHistories);}
        if(method=="POST"&&path.starts_with("/api/v1/mappings/")&&(path.ends_with("/subdivide")||path.ends_with("/subdivide-box"))&&result.contains("rectIds")){
            const auto mid=parts(path).at(3);auto entry=selection_.value(mid,Json::object());entry.update({{"ids",result["rectIds"]},{"traceId",nullptr},{"revision",entry.value("revision",0)+1}});selection_[mid]=entry;mappingsRevision_=UINT64_MAX;
        }
        if(path=="/api/v1/mappings/reset"){auto counter=selection_.value("_previewRevision",uint64_t(0))+1;selection_=Json::object();selection_["_previewRevision"]=counter;selection_["_scenePreviewRevision"]=counter;mappingsRevision_=UINT64_MAX;}
        if(path=="/api/v1/mix"||path=="/api/v1/outputs"||path.starts_with("/api/v1/outputs/"))return {200,snapshotUnlocked()};
        if(path=="/api/v1/grid")return {200,{{"grid",snapshotUnlocked()["state"]["grid"]},{"revision",document_["revision"]},{"result",result}}};
        Reply reply{method=="POST"&&path.starts_with("/api/v1/mappings/")&&path.ends_with("/rects")?201:200,result};reply.committedRevision=document_["revision"].get<uint64_t>();return reply;
    }catch(const Error& e){return {e.status,{{"error",e.what()},{"revision",document_["revision"]}}};}
    catch(const Json::exception& e){return {400,{{"error",e.what()}}};}
    catch(const std::invalid_argument& e){return {400,{{"error",e.what()}}};}
    catch(const std::exception& e){return {500,{{"error",e.what()}}};}
}
}

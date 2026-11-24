#include "calibration_model.hpp"
#include "mapping_collections.hpp"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <fstream>
#include <random>
#include <set>
#include <stdexcept>
#include <fcntl.h>
#include <unistd.h>
namespace vj { namespace {
using J=nlohmann::json;namespace fs=std::filesystem;
void require(bool good,const char* message){if(!good)throw std::invalid_argument(message);}
std::string key(const J& value){return value.is_string()?value.get<std::string>():value.dump();}
std::string uuid(size_t length=32){static std::mutex mutex;static std::mt19937_64 rng(std::random_device{}());std::lock_guard lock(mutex);std::string out;for(size_t i=0;i<length;++i)out+="0123456789abcdef"[rng()&15];return out;}
J identity(const J& display){return J::array({display.value("physical",J()),display.value("name",J()),display.value("width",J()),display.value("height",J())});}
J rotated(const J& point,int rotation){double x=point.at(0),y=point.at(1);if(rotation==90)return {1-y,x};if(rotation==180)return {1-x,1-y};if(rotation==270)return {y,1-x};return point;}
bool calibrated(const J& rect){if(rect.value("origin",std::string{})=="calibration")return true;auto id=rect.value("id",std::string{});return id.size()==16&&id.starts_with("cal-")&&id.substr(4).find_first_not_of("0123456789abcdef")==std::string::npos;}
std::pair<J,J> mapping(const J& result,const std::string& mid){
 const auto& projector=result.at("projector");int width=projector.at("width"),height=projector.at("height");require(width>0&&height>0&&width<=8192&&height<=8192,"Invalid display dimensions");J rects=J::array(),collection;
 const bool points=result.value("kind",std::string{})=="points";
 if(points)collection={{"id","points-"+uuid(12)},{"kind","points"},{"name","Calibrated points"},{"origin","calibration"},{"content",{{"kind","out"},{"source","out1"},{"layout","repeat"}}},{"enabled",true},{"shape","circle"},{"radius",.02},{"aspect",double(width)/height},{"points",J::array()}};
 else collection={{"id","collection-"+uuid(12)},{"kind","planar"},{"name","Calibration · Projector "+mid},{"origin","calibration"},{"content",{{"kind","out"},{"source","out1"},{"layout","repeat"}}},{"enabled",true},{"plane",{{"space","camera"}}},{"faces",J::array()}};
 for(const auto& card:result.at("cards")){
  if(!card.contains("mapping")||card["mapping"].is_null()||card["mapping"].empty())continue;
  const std::string label=card.at("label").get<std::string>();
  if(points){auto p=card["mapping"].at("projectorPoint"),camera=card.at("cameraPoint");double x=p.at("x").get<double>()/width,y=p.at("y").get<double>()/height,cx=camera.at("x"),cy=camera.at("y");require(std::isfinite(x)&&std::isfinite(y)&&x>=0&&y>=0&&x<=1&&y<=1&&std::isfinite(cx)&&std::isfinite(cy),"Invalid calibrated point");collection["points"].push_back({{"id","p"+uuid(12)},{"name",label},{"position",{x,y}},{"cameraPosition",{cx,cy}}});continue;}
  const auto& corners=card.at("output").at("projectorCorners");require(corners.is_array()&&corners.size()==4,"Expected four corners");double cell=card["mapping"].value("cell",result.value("cell",4.));require(std::isfinite(cell)&&cell>=1&&cell<=64,"Invalid calibration stripe cell");J normalized=J::array();for(const auto& p:corners){double x=p.at("x").get<double>()/width,y=p.at("y").get<double>()/height;require(std::isfinite(x)&&std::isfinite(y)&&x>=-2*cell/width&&x<=1+2*cell/width&&y>=-2*cell/height&&y<=1+2*cell/height,"Mapped corners exceed projector edge tolerance. Reduce mapped size and save again");normalized.push_back({std::clamp(x,0.,1.),std::clamp(y,0.,1.)});}
  const auto id="cal-"+uuid(12);rects.push_back({{"id",id},{"kind","surface"},{"name",label},{"origin","calibration"},{"corners",normalized},{"uvs",{{0,1},{1,1},{1,0},{0,0}}},{"source","out1"},{"mode","live"},{"graphic","grid"},{"config",{{"color","#00ff00"},{"thickness",3}}},{"blend","normal"},{"fit","stretch"}});
  J camera=J::array();for(const auto& p:card.at("output").at("cameraCorners"))camera.push_back({p.at("x"),p.at("y")});require(camera.size()==4,"Expected four camera corners");collection["faces"].push_back({{"id",id},{"rectId",id},{"planeCorners",camera}});
 }
 require(points?!collection["points"].empty():!rects.empty(),"No mapped cards");require((points?collection["points"].size():rects.size())<=128,"More than 128 cards");J project={{"rects",rects},{"collections",J::array({collection})}};normalizeMappingCollections(project);return {project["rects"],project["collections"][0]};
}
void persist(const fs::path& path,const J& value){fs::create_directories(path.parent_path());auto pattern=(path.parent_path()/".calibration-XXXXXX").string();std::vector<char> name(pattern.begin(),pattern.end());name.push_back(0);int fd=mkstemp(name.data());if(fd<0)throw std::runtime_error("Cannot create calibration save");try{auto data=value.dump();size_t offset=0;while(offset<data.size()){auto n=write(fd,data.data()+offset,data.size()-offset);if(n<0&&errno==EINTR)continue;if(n<=0)throw std::runtime_error("Cannot write calibration save");offset+=n;}if(fsync(fd)!=0)throw std::runtime_error("Cannot sync calibration save");close(fd);fd=-1;fs::rename(name.data(),path);int dir=open(path.parent_path().c_str(),O_RDONLY|O_DIRECTORY);if(dir>=0){while(fsync(dir)<0&&errno==EINTR){}close(dir);}}catch(...){if(fd>=0)close(fd);unlink(name.data());throw;}}
}
CalibrationModel::CalibrationModel(fs::path root){require(!root.empty(),"Calibration state root must not be empty");path_=root/"calibrations.json";reloadFromDisk();}
void CalibrationModel::reloadFromDisk(){std::lock_guard lock(mutex_);saved_=J::array();storageError_.clear();if(fs::exists(path_)){try{std::ifstream file(path_);J saved;file>>saved;require(saved.is_array(),"Expected saved calibration list");if(!saved.empty())saved_.push_back(saved.back());}catch(const std::exception& error){storageError_=std::string("Could not read saved calibrations: ")+error.what();}}}
CalibrationModel::Json CalibrationModel::status(const J& displays,const J& vectors)const{std::lock_guard lock(mutex_);J list=displays;for(auto& display:list){auto id=key(display.at("id"));display["pattern"]=state_["outputs"].value(id,J());}return {{"displays",list},{"vectors",vectors},{"error",list.empty()?J("Native renderer is not connected."):J()}};}
void CalibrationModel::advance(J next){
    const auto revision=state_["revision"].get<uint64_t>()+1;
    std::set<std::string> targets;
    for(auto it=state_["outputs"].begin();it!=state_["outputs"].end();++it)targets.insert(it.key());
    for(auto it=next["outputs"].begin();it!=next["outputs"].end();++it)targets.insert(it.key());
    next["revision"]=revision;requiredTargets_[revision]=std::move(targets);
    while(requiredTargets_.size()>128)requiredTargets_.erase(requiredTargets_.begin());
    state_=std::move(next);
}
void CalibrationModel::touch(double now){std::lock_guard lock(mutex_);clientAt_=now;}
CalibrationModel::Json CalibrationModel::command(double now){std::lock_guard lock(mutex_);if(now-clientAt_>8&&(!state_["outputs"].empty()||state_["camera"]!="")){auto next=state_;next["outputs"]=J::object();next["camera"]="";owner_.clear();advance(std::move(next));}return state_;}
void CalibrationModel::acknowledge(uint64_t revision){std::lock_guard lock(mutex_);auto found=requiredTargets_.find(revision);if(found!=requiredTargets_.end()&&found->second.empty())presented_=std::max(presented_,revision);}
void CalibrationModel::acknowledgeTarget(const std::string& id,uint64_t revision){std::lock_guard lock(mutex_);presentedTargets_[id]=std::max(presentedTargets_[id],revision);for(const auto& [pending,targets]:requiredTargets_){if(pending<=presented_||targets.empty())continue;bool complete=true;for(const auto& target:targets){auto found=presentedTargets_.find(target);if(found==presentedTargets_.end()||found->second<pending){complete=false;break;}}if(complete)presented_=std::max(presented_,pending);}}
bool CalibrationModel::presented(uint64_t revision)const{std::lock_guard lock(mutex_);return presented_>=revision;}
CalibrationModel::Json CalibrationModel::projector(const J& data,const J& displays,double now){std::lock_guard lock(mutex_);require(data.is_object()&&displays.is_array(),"Invalid calibration command");clientAt_=now;std::string owner=data.value("owner",std::string{}),currentOwner=now-leaseAt_>15?"":owner_;require(currentOwner.empty()||currentOwner==owner,"Another tab is scanning");auto next=state_;auto op=data.value("op",std::string{}),target=key(data.value("target",J("")));std::set<std::string> ids;for(auto& display:displays)ids.insert(key(display.at("id")));auto black=[&](){J output=J::object();for(auto& id:ids)output[id]={{"kind","black"}};return output;};
 if(op=="exit"){next["outputs"]=J::object();next["camera"]="";currentOwner.clear();}
 else if(op=="claim")currentOwner=owner;
 else if(op=="release"){currentOwner.clear();next["outputs"]=black();}
 else if(op=="enable"){next["outputs"]=J::object();for(auto& value:data.value("targets",J::array())){auto id=key(value);if(ids.contains(id))next["outputs"][id]={{"kind","black"}};}}
 else if(op=="black")next["outputs"]=black();
 else if(op=="light"){require(currentOwner.empty(),"Scan in progress");require(ids.contains(target),"Display unavailable");double brightness=data.value("brightness",100.);require(std::isfinite(brightness),"Invalid brightness");next["outputs"][target]={{"kind",data.value("mode",std::string{})=="white"?"white":"black"},{"brightness",std::clamp(brightness,0.,100.)}};}
 else if(op=="render"){require(!currentOwner.empty()&&ids.contains(target),"Claim scan before rendering");auto pattern=data.at("pattern");auto kind=pattern.value("kind",std::string{});require(kind=="black"||kind=="white"||kind=="gray","Invalid pattern");if(kind=="gray"){require(pattern.value("axis",std::string{})=="x"||pattern.value("axis",std::string{})=="y","Invalid stripe axis");require(pattern.at("bit").is_number_integer()&&pattern.at("cell").is_number_integer(),"Invalid stripe parameters");int bit=pattern["bit"],cell=pattern["cell"];require(bit>=0&&bit<=15&&cell>=1&&cell<=64,"Invalid stripe parameters");}next["outputs"]=black();next["outputs"][target]=pattern;}
 else if(op=="grids"){next["outputs"]=black();for(auto& group:data.at("outputs")){auto id=key(group.at("target"));require(ids.contains(id),"Display unavailable");const auto& cards=group.at("cards");require(cards.is_array()&&cards.size()<=128,"Too many cards");for(auto& card:cards){auto matrix=card.at("unitToProjector");require(matrix.is_array()&&matrix.size()==9,"Invalid grid mapping");for(auto& value:matrix)require(value.is_number()&&std::isfinite(value.get<double>()),"Invalid grid mapping");for(auto uv:std::array<std::array<double,2>,4>{{{{0,0}},{{1,0}},{{1,1}},{{0,1}}}})require(std::abs(matrix[6].get<double>()*uv[0]+matrix[7].get<double>()*uv[1]+matrix[8].get<double>())>=1e-8,"Singular grid mapping");}next["outputs"][id]={{"kind","grid"},{"cards",cards}};}}
 else throw std::invalid_argument("Unknown calibration operation");
 advance(std::move(next));owner_=currentOwner;leaseAt_=now;return state_;
}
CalibrationModel::Json CalibrationModel::startCamera(const std::string& device,const std::string& instance,double now){std::lock_guard lock(mutex_);require(!device.empty()&&!instance.empty(),"Invalid camera or renderer");require(owner_.empty(),"Scan in progress");cameraInstance_=instance;clientAt_=now;auto next=state_;next["camera"]=device;advance(std::move(next));return {{"generation",instance+":"+device},{"device",device},{"revision",state_["revision"]}};}
std::string CalibrationModel::cameraGeneration()const{std::lock_guard lock(mutex_);return cameraInstance_+":"+state_["camera"].get<std::string>();}
CalibrationModel::Json CalibrationModel::library()const{std::lock_guard lock(mutex_);if(!storageError_.empty())throw std::runtime_error(storageError_);return saved_;}
CalibrationModel::Json CalibrationModel::save(const J& document){require(document.is_object()&&document.contains("projectors")&&document["projectors"].is_array()&&!document["projectors"].empty(),"No calibrated projectors");require(document["projectors"].size()<=32,"Too many calibrated projectors");for(auto& result:document["projectors"])(void)mapping(result,"");std::lock_guard lock(mutex_);if(!storageError_.empty())throw std::runtime_error(storageError_);auto id=uuid();double created=std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count();J next=J::array({{{"id",id},{"createdAt",created},{"calibration",document}}});persist(path_,next);saved_=std::move(next);return {{"id",id}};}
CalibrationModel::Json CalibrationModel::prepareLoad(const J& revisions,const J& mappings,const J& displays,double now)const{std::lock_guard lock(mutex_);require(owner_.empty()||now-leaseAt_>=15,"Finish the calibration scan before loading mappings");if(!storageError_.empty())throw std::runtime_error(storageError_);require(!saved_.empty(),"No current calibration. Save a scan first");J incoming=J::object(),collections=J::object();for(auto& result:saved_.back()["calibration"]["projectors"]){J matched=J::array();for(auto& display:displays)if(identity(display)==identity(result["projector"]))matched.push_back(display);require(matched.size()==1,"Projector configuration changed. Rescan before loading");auto id=key(matched[0]["id"]);require(!incoming.contains(id),"Duplicate projector in calibration");require(mappings.contains(id),"Mapping surface is unavailable");auto [rects,collection]=mapping(result,id);incoming[id]=std::move(rects);collections[id]=std::move(collection);}
 J changes=J::object();for(auto it=mappings.begin();it!=mappings.end();++it){auto id=it.key();const auto& surface=it.value();auto project=surface.at("project");J manual=J::array();for(auto& rect:project.at("rects"))if(!calibrated(rect))manual.push_back(rect);if(!incoming.contains(id)&&manual.size()==project["rects"].size())continue;require(revisions.contains(id)&&revisions[id]==surface.at("revision"),"Mapping changed. Load calibration again");auto rects=incoming.value(id,J::array());auto output=project.value("output",J::object());int rotation=output.value("rotation",output.value("rotate180",false)?180:0);int compensation=(((-rotation)%360)+360)%360;if(compensation){for(auto& rect:rects)for(auto& p:rect["corners"])p=rotated(p,compensation);if(collections.contains(id)&&collections[id]["kind"]=="points")for(auto& point:collections[id]["points"])point["position"]=rotated(point["position"],compensation);}
 project["rects"]=manual;for(auto& rect:rects)project["rects"].push_back(rect);require(project["rects"].size()<=128,"Mapping supports up to 128 surfaces");std::set<std::string> manualIds;for(auto& rect:manual)manualIds.insert(rect.at("id").get<std::string>());J kept=J::array();for(auto collection:project.value("collections",J::array())){
 const auto kind=collection.value("kind",std::string{});
 if((kind=="points"||kind=="boxes")&&collection.value("origin",std::string{})!="calibration"){
     // Generated manual collections own their point/box models. Keep those
     // models intact even when legacy metadata has not generated faces yet.
     kept.push_back(collection);continue;
 }
 J faces=J::array();for(auto& face:collection.value("faces",J::array())){
     if(!face.contains("rectId")||!face["rectId"].is_string()||manualIds.contains(face["rectId"].get<std::string>()))faces.push_back(face);
 }
 collection["faces"]=faces;if(!faces.empty())kept.push_back(collection);
}if(collections.contains(id))kept.push_back(collections[id]);project["collections"]=kept;project["selectedRectId"]=!rects.empty()?rects[0]["id"]:!manual.empty()?manual[0]["id"]:J();project["selectedTraceId"]=nullptr;normalizeMappingCollections(project);
 std::set<std::string> currentIds;for(auto& rect:project["rects"])currentIds.insert(rect["id"].get<std::string>());
 if(project.contains("groups")){J groups=J::array();for(auto group:project["groups"]){J members=J::array();for(auto& member:group.value("rectIds",J::array()))if(member.is_string()&&currentIds.contains(member.get<std::string>()))members.push_back(member);group["rectIds"]=members;if(!members.empty())groups.push_back(group);}project["groups"]=groups;}
 changes[id]=std::move(project);}
 return changes;
}
void CalibrationModel::loaded(){std::lock_guard lock(mutex_);auto next=state_;next["outputs"]=J::object();advance(std::move(next));}
CalibrationModel::Json CalibrationModel::diagnostics()const{std::lock_guard lock(mutex_);return {{"revision",state_["revision"]},{"presented",presented_},{"owner",owner_},{"storageError",storageError_},{"saved",saved_.size()}};}
}

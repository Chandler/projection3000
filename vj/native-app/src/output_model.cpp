#include "output_model.hpp"
#include "unicode_names.hpp"
#include "api_error.hpp"
#include "../../native-renderer/src/output_limits.hpp"
#include <algorithm>
#include <cctype>
#include <set>

namespace vj {
namespace {
void require(bool ok, const std::string& message) { if (!ok) throw ApiError(400,message); }
bool projectorId(const std::string& id) { return id=="1"||id=="2"||id=="3"||id=="4"; }
void keys(const Json& value, const std::set<std::string>& allowed) {
    require(value.is_object(),"Expected an object");
    for (auto it=value.begin();it!=value.end();++it) require(allowed.contains(it.key()),"Unknown output setting: "+it.key());
}
std::string trim(const std::string& text) {return unicode::trim(text);}
std::string folded(const std::string& text) {return unicode::casefold(text);}
const Json& objectAt(const Json& value,const std::string& key) {
    static const Json empty=Json::object();
    if(!value.is_object()||!value.contains(key)||!value[key].is_object())return empty;
    return value[key];
}
const Json& arrayAt(const Json& value,const std::string& key) {
    static const Json empty=Json::array();
    if(!value.is_object()||!value.contains(key)||!value[key].is_array())return empty;
    return value[key];
}
bool flag(const Json& object,const std::string& key,bool fallback=false) {
    return object.is_object()&&object.contains(key)&&object[key].is_boolean()?object[key].get<bool>():fallback;
}
std::string stringAt(const Json& object,const std::string& key,const std::string& fallback={}) {
    return object.is_object()&&object.contains(key)&&object[key].is_string()?object[key].get<std::string>():fallback;
}
Json settings(const Json& document) {
    auto routing=objectAt(document,"outputRouting");
    if(!routing.contains("ndiProjectors")) {
        if(document.contains("ndi_projectors"))routing["ndiProjectors"]=validateNdiProjectors(document["ndi_projectors"]);
        else routing["ndiProjectors"]=migrateNdiOutputs(document.value("ndi_outputs",Json::object()));
    }
    if(!routing.contains("displayAssignments"))routing["displayAssignments"]=Json::object();
    return routing;
}
Json ids(const Json& document) {
    Json result=Json::array();const auto& mappings=objectAt(document,"mappings");
    if(mappings.empty())return Json::array({"1","2","3","4"});
    for(auto it=mappings.begin();it!=mappings.end();++it)result.push_back(it.key());
    return result;
}
Json statusFor(const Json& requested,const Json& reported,bool available,bool connected,const std::string& transport) {
    const bool enabled=flag(requested,"enabled");
    bool active=enabled&&available&&connected&&flag(reported,"active");
    if(transport=="display"&&stringAt(requested,"displayId")!=stringAt(reported,"displayId"))active=false;
    Json result=reported;
    if(!result.is_object())result=Json::object();
    result.update({{"enabled",enabled},{"active",active},{"available",available}});
    result["status"]=!enabled?"disabled":!available?"unavailable":!connected?"disconnected":active?"active":stringAt(reported,"error").empty()?"pending":"error";
    if(transport=="display")result["displayId"]=stringAt(requested,"displayId");
    if(!available&&enabled)result["error"]=transport=="display"?"Physical display output is unavailable in this runtime":"NDI publishing is unavailable in this runtime";
    else if(!enabled)result["error"]="";
    else if(!connected)result["error"]="Native renderer is not connected.";
    else if(!result.contains("error"))result["error"]="";
    return result;
}
Json runtimeSnapshot(const Json& document,const Json& runtime) {
    const auto routing=settings(document), reports=objectAt(runtime,"projectors");
    Json projectors=Json::object();
    for(const auto& id:ids(document)) {
        auto mid=id.get<std::string>();auto report=objectAt(reports,mid);
        auto display=objectAt(objectAt(routing,"displayAssignments"),mid);
        auto ndi=objectAt(objectAt(routing,"ndiProjectors"),mid);
        projectors[mid]={{"display",statusFor(display,objectAt(report,"display"),flag(runtime,"physicalAvailable"),flag(runtime,"rendererConnected"),"display")},
                         {"ndi",statusFor(ndi,objectAt(report,"ndi"),flag(runtime,"ndiAvailable"),flag(runtime,"rendererConnected"),"ndi")}};
    }
    return {{"physicalAvailable",flag(runtime,"physicalAvailable")},{"ndiAvailable",flag(runtime,"ndiAvailable")},
            {"rendererConnected",flag(runtime,"rendererConnected")},{"displays",arrayAt(runtime,"displays")},{"projectors",projectors}};
}
Json mappedDisplays(const Json& document,const Json& runtime) {
    auto view=runtimeSnapshot(document,runtime);auto routing=settings(document);Json displays=Json::array();
    for(auto it=view["projectors"].begin();it!=view["projectors"].end();++it) {
        const auto mid=it.key();const auto& status=it.value();Json display;
        if(flag(status["display"],"active")) {
            auto did=stringAt(status["display"],"displayId");
            for(const auto& candidate:view["displays"])if(stringAt(candidate,"displayId")==did){display=candidate;break;}
            if(display.is_null())continue; // An inventory entry provides actual pixel dimensions.
        } else if(flag(status["ndi"],"active")) {
            auto config=objectAt(objectAt(routing,"ndiProjectors"),mid);
            display={{"physical",-1},{"name",config.value("name",std::string("Vibe Projector ")+mid)},
                     {"width",config.value("width",1280)},{"height",config.value("height",720)}};
        } else continue;
        display["id"]=std::stoi(mid);
        display["pattern"]=objectAt(objectAt(objectAt(objectAt(document,"mappings"),mid),"project"),"output");
        displays.push_back(display);
    }
    return {{"displays",displays},{"vectors",objectAt(runtime,"vectors")},
            {"error",flag(runtime,"rendererConnected")?Json(nullptr):Json("Native renderer is not connected.")}};
}
}

Json outputDefaults() { return {{"ndiProjectors",Json::object()},{"displayAssignments",Json::object()}}; }
Json validateNdiProjectors(const Json& raw) {
    require(raw.is_object(),"Expected output settings");Json result=Json::object();std::set<std::string> names;
    for(auto it=raw.begin();it!=raw.end();++it) {
        require(projectorId(it.key())&&it.value().is_object(),"Unknown projector");auto value=it.value();
        keys(value,{"enabled","name","width","height","fps"});
        auto enabled=value.value("enabled",Json(false));require(enabled.is_boolean(),"enabled must be boolean");
        auto name=value.value("name",Json("Vibe Projector "+it.key()));
        require(name.is_string(),"Use a stream name of 1–150 bytes without reserved characters");
        auto text=name.get<std::string>();bool valid=!trim(text).empty()&&text.size()<=150;
        for(unsigned char c:text)if(c<32||std::string("\\/:*?\"<>|").find(c)!=std::string::npos)valid=false;
        require(valid,"Use a stream name of 1–150 bytes without reserved characters");text=trim(text);
        Json config={{"enabled",enabled},{"name",text}};
        for(const auto& key:{"width","height","fps"}) {
            const bool fps=std::string(key)=="fps";int low=fps?1:64, high=fps?60:std::string(key)=="width"?1920:1080;
            auto number=value.value(key,Json(fps?30:std::string(key)=="width"?1280:720));
            require(number.is_number_integer()&&number>=low&&number<=high,std::string(key)+" must be "+std::to_string(low)+"–"+std::to_string(high));
            require(fps||number.get<int>()%2==0,"Width and height must be even");config[key]=number;
        }
        if(enabled.get<bool>())require(names.insert(folded(text)).second,"Enabled stream names must be unique");
        result[it.key()]=config;
    }
    return result;
}
Json migrateNdiOutputs(const Json& raw) {
    Json converted=Json::object();if(!raw.is_object())return converted;
    for(auto it=raw.begin();it!=raw.end();++it){auto id=it.key();if(id=="program")id="1";else if(id.starts_with("out"))id=id.substr(3);if(projectorId(id))converted[id]=it.value();}
    return validateNdiProjectors(converted);
}
Json validateDisplayAssignments(const Json& raw) {
    require(raw.is_object(),"Expected display assignments");Json result=Json::object();std::set<std::string> assigned;
    for(auto it=raw.begin();it!=raw.end();++it) {
        require(projectorId(it.key())&&it.value().is_object(),"Unknown projector");keys(it.value(),{"displayId","enabled"});
        auto enabled=it.value().value("enabled",Json(false));auto id=it.value().value("displayId",Json(""));
        require(enabled.is_boolean(),"enabled must be boolean");require(id.is_string(),"displayId must be a string");auto text=id.get<std::string>();
        require(text.size()<=256&&std::none_of(text.begin(),text.end(),[](unsigned char c){return c<32;}),"Invalid displayId");
        require(!enabled.get<bool>()||!trim(text).empty(),"Choose a display before enabling its output");
        if(enabled.get<bool>())require(assigned.insert(text).second,"A display can be assigned to only one enabled projector");
        result[it.key()]={{"displayId",text},{"enabled",enabled}};
    }
    return result;
}
void initializeOutputSettings(Json& document) {
    auto routing=settings(document);
    routing["ndiProjectors"]=validateNdiProjectors(routing["ndiProjectors"]);
    routing["displayAssignments"]=validateDisplayAssignments(routing["displayAssignments"]);
    document["outputRouting"]=routing;
}
bool isOutputRoute(const std::string& path) {
    return path=="/api/v1/ndi/projectors"||path=="/api/v1/display-assignments"||path=="/api/v1/displays"||path=="/api/mapping/displays";
}
std::optional<Json> requestOutput(Json& document,const std::string& method,const std::string& path,const Json& incoming,const Json& runtime) {
    if(!isOutputRoute(path))return std::nullopt;
    if(path=="/api/v1/displays"||path=="/api/mapping/displays") {
        if(method!="GET")throw ApiError(405,"Use GET");
        if(path=="/api/mapping/displays")return mappedDisplays(document,runtime);
        return Json{{"displays",arrayAt(runtime,"displays")},{"available",flag(runtime,"physicalAvailable")}};
    }
    if(method!="GET"&&method!="PUT")throw ApiError(405,"Use GET or PUT");
    if(method=="PUT") {
        auto body=incoming;require(body.is_object(),"Expected an object");body.erase("revision");auto routing=settings(document);
        if(path=="/api/v1/ndi/projectors")routing["ndiProjectors"]=validateNdiProjectors(body);
        else {
            keys(body,{"assignments","activate"});require(body.contains("assignments"),"assignments is required");auto previous=routing["displayAssignments"];auto assignments=validateDisplayAssignments(body["assignments"]);
            std::string activate;if(body.contains("activate")){require(body["activate"].is_string(),"activate must be a projector ID");activate=body["activate"].get<std::string>();require(projectorId(activate)&&assignments.contains(activate)&&flag(assignments[activate],"enabled"),"activate requires an enabled display assignment");}
            for(auto it=assignments.begin();it!=assignments.end();++it){auto old=objectAt(previous,it.key());if(flag(it.value(),"enabled")&&(it.key()==activate||!flag(old,"enabled")||stringAt(old,"displayId")!=stringAt(it.value(),"displayId"))&&document["mappings"].contains(it.key())){auto& mapping=document["mappings"][it.key()];if(!mapping["project"]["output"].value("enabled",true)){mapping["project"]["output"]["enabled"]=true;mapping["revision"]=mapping.value("revision",uint64_t(0))+1;}}}
            routing["displayAssignments"]=assignments;
        }
        document["outputRouting"]=routing;
    }
    auto routing=settings(document);auto status=runtimeSnapshot(document,runtime);
    if(path=="/api/v1/display-assignments")return Json{{"assignments",routing["displayAssignments"]},{"ids",ids(document)},{"runtime",status}};
    Json ndiStatus=Json::object();for(auto it=status["projectors"].begin();it!=status["projectors"].end();++it)ndiStatus[it.key()]=it.value()["ndi"];
    return Json{{"projectors",routing["ndiProjectors"]},{"ids",ids(document)},{"status",ndiStatus},{"rendererConnected",flag(runtime,"rendererConnected")}};
}
Json outputSnapshot(const Json& document,const Json& runtime) {
    auto routing=settings(document);auto reported=mappedDisplays(document,runtime);Json projectors=Json::object(),destinations=Json::object();
    for(const auto& bus:kOutputBuses){projectors[bus]=Json::array();destinations[bus]=Json::array();}
    const auto& mappings=objectAt(document,"mappings");
    for(auto it=mappings.begin();it!=mappings.end();++it) {
        std::set<std::string> sources;
        for(const auto& rect:arrayAt(objectAt(it.value(),"project"),"rects"))
            if(stringAt(rect,"kind")!="overlay"&&stringAt(rect,"mode","live")=="live")sources.insert(stringAt(rect,"source"));
        std::string label="Projector "+it.key();
        for(const auto& display:reported["displays"])if(std::to_string(display["id"].get<int>())==it.key()) {
            auto name=trim(stringAt(display,"name"));if(!name.empty())label=name;
            if(display.value("physical",0)==-1)label="NDI · "+label;break;
        }
        for(int i=0;i<kMaxOutputs;i++)if(sources.contains("out"+std::to_string(i+1))) {
            const auto& bus=kOutputBuses[i];projectors[bus].push_back(it.key());destinations[bus].push_back({{"kind","projector"},{"id",it.key()},{"name",label}});
        }
    }
    for(const auto& fixture:arrayAt(objectAt(document,"controls"),"fixtures")) {
        auto bus=stringAt(objectAt(fixture,"route"),"out");if(bus=="out1")bus="program";
        if(destinations.contains(bus))destinations[bus].push_back({{"kind",stringAt(fixture,"kind")=="virtual"?"trace":"led"},
            {"id",stringAt(fixture,"id")},{"name",stringAt(fixture,"label")},{"enabled",flag(fixture,"enabled")}});
    }
    return {{"ndi_projectors",routing["ndiProjectors"]},{"display_assignments",routing["displayAssignments"]},
            {"output_projectors",projectors},{"output_destinations",destinations},{"projectors",reported},{"output_status",runtimeSnapshot(document,runtime)}};
}
}

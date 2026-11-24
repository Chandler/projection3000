#include "model.hpp"
#include "mapping_model.hpp"
#include <iostream>
#include <unistd.h>
using vj::Json;
static void require(bool value,const char* message){if(!value)throw std::runtime_error(message);}
static Json stable(Json state){state["device"].erase("uptimeSeconds");state.erase("runtimeRevision");state.erase("mediaRevision");state["state"].erase("clock");for(auto& out:state["outputs"])out.erase("clock");return state;}
int main(){
    const auto root=std::filesystem::temp_directory_path()/("vj-native-mapping-"+std::to_string(getpid()));
    std::filesystem::remove_all(root);
    try{
        vj::Model model(root);
        auto mutate=[&](const std::string& method,const std::string& path,Json body){
            if(path.starts_with("/api/v1/mappings/")&&!path.ends_with("/selection"))body["revision"]=model.snapshot()["mappings"][path.substr(17,1)]["revision"];
            auto result=model.request(method,path,body);require(result.status>=200&&result.status<300,result.body.dump().c_str());return result.body;
        };
        auto added=mutate("POST","/api/v1/mappings/1/rects",{{"name","Card 2"},{"corners",{{.2,.2},{.3,.2},{.3,.3},{.2,.3}}}});
        Json ids=Json::array({"rect-1",added["rectId"]});
        auto group=mutate("POST","/api/v1/mappings/1/groups",{{"name","Cards"},{"rectIds",ids}});
        const auto groupId=group["groupId"];
        auto before=model.snapshot();mutate("PUT","/api/v1/mappings/1/selection",{{"rectIds",ids}});
        require(model.snapshot()["mappings"]["1"]["revision"]==before["mappings"]["1"]["revision"],"Selection changed geometry revision");
        mutate("PATCH","/api/v1/mappings/1/rects",{{"rectIds",ids},{"cornerRadius",.08}});
        before=model.snapshot();auto revision=before["mappings"]["1"]["revision"];
        auto invalid=model.request("POST","/api/v1/mappings/1/transform-surfaces",{{"revision",revision},{"rects",Json::array({{{"id","rect-1"},{"name","Partial"}},{{"id",added["rectId"]},{"cornerRadius",2}}})}});
        require(invalid.status==400&&stable(model.snapshot())==stable(before),"Invalid bulk edit partially committed");
        auto saved=mutate("POST","/api/v1/mapping-layouts",{{"name","Cards layout"},{"mappingId","1"},{"revision",revision},{"libraryRevision",0}});
        require(!model.snapshot()["mappings"]["1"]["layout"]["modified"].get<bool>(),"Fresh layout marked modified");
        mutate("POST","/api/v1/mappings/1/move-surfaces",{{"rectIds",ids},{"offset",{.2,.2}}});
        require(model.snapshot()["mappings"]["1"]["layout"]["modified"].get<bool>(),"Live geometry overwrote saved layout");
        mutate("POST","/api/v1/mappings/1/undo",Json::object());
        require(!model.snapshot()["mappings"]["1"]["layout"]["modified"].get<bool>(),"Mapper undo did not restore layout state");
        mutate("PATCH","/api/v1/mappings/2/output",{{"rotation",90},{"enabled",false}});
        mutate("POST","/api/v1/mappings/2/load-layout",{{"layoutId",saved["id"]},{"libraryRevision",saved["revision"]}});
        auto destination=model.snapshot()["mappings"]["2"];
        require(destination["project"]["output"]["rotation"]==90&&destination["project"]["output"]["enabled"]==false,"Layout changed projector settings");
        require(destination["project"]["groups"][0]["id"]==groupId,"Layout lost group");
        auto copied=mutate("POST","/api/v1/mappings/1/copy-surfaces",{{"target","3"},{"rectIds",ids}});
        require(copied["rectIds"].size()==2&&model.snapshot()["mappings"]["3"]["project"]["rects"].size()==3,"Multi-selection copy lost surfaces");
        vj::Model restored(root);
        require(restored.snapshot()["mappingLayouts"]==model.snapshot()["mappingLayouts"],"Layout library lost on restart");
        require(restored.snapshot()["mappings"]["2"]["project"]==destination["project"],"Loaded mapping lost on restart");
        require(restored.snapshot()["mappings"]["1"]["selectedRectIds"].empty(),"Transient selection persisted");
        {
            vj::Model clipboardModel(root/"clipboard");
            const auto edit=[&](const std::string& mid,const std::string& method,const std::string& action,Json body){body["revision"]=clipboardModel.snapshot()["mappings"][mid]["revision"];auto reply=clipboardModel.request(method,"/api/v1/mappings/"+mid+"/"+action,body);require(reply.status==200,reply.body.dump().c_str());return reply.body;};
            edit("1","PATCH","rects/rect-1",{{"name","Curved overlay"},{"kind","overlay"},{"source","out2"},{"mode","grid"},{"curvature",{{"top",.04}}},{"config",{{"color","#123456"},{"thickness",4}}}});
            auto copied=vj::captureMappingClipboard(clipboardModel.snapshot()["mappings"]["1"],Json::array({"rect-1"}),"1");
            edit("1","PATCH","rects/rect-1",{{"name","Changed after copy"},{"source","out1"}});
            auto pasted=edit("2","POST","paste",{{"clipboard",copied},{"offset",.025}});auto pastedID=pasted["rectIds"][0];
            auto rect=pasted["project"]["rects"].back();auto expected=copied["rects"][0];expected["id"]=pastedID;expected["name"]="Curved overlay copy";expected["origin"]="manual";for(auto& p:expected["corners"]){p[0]=p[0].get<double>()+.025;p[1]=p[1].get<double>()+.025;}
            require(rect==expected,"Paste lost copied geometry/properties or read the edited original");
            auto pastedAgain=edit("2","POST","paste",{{"clipboard",copied},{"offset",.05}});require(pastedAgain["rectIds"][0]!=pastedID&&pastedAgain["project"]["rects"].back()["name"]=="Curved overlay copy 2","Repeated paste reused IDs/names");
            edit("2","POST","undo",Json::object());require(clipboardModel.snapshot()["mappings"]["2"]["project"]["rects"].size()==2,"Paste was not one undo step");
            edit("2","POST","redo",Json::object());require(clipboardModel.snapshot()["mappings"]["2"]["project"]["rects"].size()==3,"Paste redo failed");
            auto multi=vj::captureMappingClipboard(clipboardModel.snapshot()["mappings"]["2"],Json::array({"rect-1",pastedID}),"2");require(edit("3","POST","paste",{{"clipboard",multi}})["rectIds"].size()==2,"Multi-surface paste lost selection");
            edit("1","POST","collections",{{"kind","boxes"},{"preset","stack"}});auto mapping=clipboardModel.snapshot()["mappings"]["1"];auto collection=mapping["project"]["collections"].back();auto face=collection["faces"][0];
            auto box=vj::captureMappingClipboard(mapping,Json::array({face["rectId"]}),"1");require(box["kind"]=="box","Selected box face did not copy complete box");
            auto boxesBefore=collection["boxes"].size();auto same=edit("1","POST","paste",{{"clipboard",box}});require(same["project"]["collections"][0]["boxes"].size()==boxesBefore+1&&same["rectIds"].size()==box["faces"].size(),"Box paste lost collection ownership/faces");
            auto across=edit("4","POST","paste",{{"clipboard",box}});require(across["project"]["collections"].size()==1&&across["project"]["collections"][0]["boxes"].size()==1,"Cross-projector box paste lost geometry");
            auto trace=edit("1","POST","traces",{{"name","Copied trace"}});auto traceCopy=vj::captureMappingClipboard(clipboardModel.snapshot()["mappings"]["1"],Json::array(),"1",trace["traceId"]);require(edit("2","POST","paste",{{"clipboard",traceCopy}}).contains("traceId"),"Trace paste lost selection");
            auto beforeInvalid=clipboardModel.snapshot();auto invalid=copied;invalid["rects"][0]["source"]="invalid";auto reply=clipboardModel.request("POST","/api/v1/mappings/2/paste",{{"revision",beforeInvalid["mappings"]["2"]["revision"]},{"clipboard",invalid}});require(reply.status==400&&clipboardModel.revision()==beforeInvalid["revision"],"Invalid clipboard partially committed");
            vj::Model reopened(root/"clipboard");require(reopened.snapshot()["mappings"]["4"]["project"]==across["project"],"Pasted box did not persist");
            edit("3","POST","collections",{{"kind","planar"},{"rectIds",Json::array({"rect-1"})},{"name","Planes"}});
            auto planarMapping=clipboardModel.snapshot()["mappings"]["3"];auto planar=planarMapping["project"]["collections"][0];
            auto planarCopy=vj::captureMappingClipboard(planarMapping,Json::array({"rect-1"}),"3");
            auto inPlanar=edit("3","POST","paste",{{"clipboard",planarCopy}});auto newPlanarID=inPlanar["rectIds"][0];
            require(inPlanar["project"]["collections"].size()==1&&inPlanar["project"]["collections"][0]["faces"].size()==2&&inPlanar["project"]["collections"][0]["faces"][1]["rectId"]==newPlanarID,"Planar paste escaped its collection");
            require(inPlanar["project"]["collections"][0]["faces"][1]["planeCorners"]==planar["faces"][0]["planeCorners"],"Planar paste lost plane coordinates");
            edit("3","POST","undo",Json::object());require(clipboardModel.snapshot()["mappings"]["3"]["project"]["collections"][0]["faces"].size()==1,"Planar paste undo left a dangling face");
            edit("3","POST","redo",Json::object());
            edit("3","PATCH","collections/"+planar["id"].get<std::string>(),{{"referenceFaceId",planar["faces"][0]["id"]}});
            auto subset=vj::captureMappingClipboard(clipboardModel.snapshot()["mappings"]["3"],Json::array({newPlanarID}),"3");
            auto crossPlanar=edit("2","POST","paste",{{"clipboard",subset}});auto newCollection=crossPlanar["project"]["collections"][0];
            require(newCollection["faces"].size()==1&&newCollection["faces"][0]["rectId"]==crossPlanar["rectIds"][0]&&newCollection["plane"]["referenceFaceId"]==newCollection["faces"][0]["id"],"Cross-projector planar subset lost ownership/reference");
            edit("3","DELETE","collections/"+planar["id"].get<std::string>(),Json::object());
            auto recreated=edit("3","POST","paste",{{"clipboard",planarCopy}});require(recreated["project"]["collections"].size()==1&&recreated["project"]["collections"][0]["faces"].size()==1,"Deleted planar collection not recreated for paste");
            vj::Model planarReopened(root/"clipboard");require(planarReopened.snapshot()["mappings"]["2"]["project"]==crossPlanar["project"],"Pasted planar membership did not persist");
            std::cout<<"PASS: clipboard snapshots, surfaces, boxes, planar membership/subsets, traces, offsets, cross-projector paste, undo, validation, persistence\n";
        }
        std::filesystem::remove_all(root);std::cout<<"PASS: grouped bulk edits, atomicity, layout isolation, mapper undo, multi-copy, persistence\n";
    }catch(const std::exception& error){std::filesystem::remove_all(root);std::cerr<<error.what()<<'\n';return 1;}
}

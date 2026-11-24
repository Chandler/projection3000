#include "model.hpp"
#include "api_server.hpp"
#include "render_scene.hpp"
#include "mapping_compat.hpp"
#include "../../native-renderer/src/flash_faces.hpp"
#include <iostream>
#include <fstream>
#include <stdexcept>
#include <unistd.h>
using vj::Json;
void require(bool c,const char* message){if(!c)throw std::runtime_error(message);}
Json stable(Json snapshot){snapshot["device"].erase("uptimeSeconds");snapshot.erase("runtimeRevision");snapshot.erase("mediaRevision");snapshot.erase("previewRevision");snapshot["state"].erase("clock");snapshot["state"].erase("ui");for(auto& out:snapshot["outputs"])out.erase("clock");return snapshot;}
int main(){
    auto root=std::filesystem::temp_directory_path()/("vj-native-model-"+std::to_string(getpid()));std::filesystem::remove_all(root);
    try{
        vj::Model m(root);auto command=[&](Json c){auto r=m.request("POST","/api/v1/grid",c);require(r.status==200,r.body.dump().c_str());return r.body;};
        {
            const auto revision=m.revision();const auto fileTime=std::filesystem::last_write_time(root/"native-state.json");
            const Json params={{"palette_source","patch:mux"},{"theme","candy"}};
            const Json red=Json::array({{{"r",1.},{"g",0.},{"b",0.}}});
            const Json green=Json::array({{{"r",0.},{"g",1.},{"b",0.}}});
            const auto publish=[&](Json colors,bool available=true){m.setPaletteSources(Json::array({{{"id","patch:mux"},{"available",available},{"colors",colors}}}));};
            const auto sample=[&]{return flash_faces::palette(params,m.paletteSources());};
            require(sample()==std::vector<flash_faces::Color>{{0,0,0}},"Uninitialized external palette flashed the local theme");
            publish(red);const auto expected=sample();require(expected==std::vector<flash_faces::Color>{{1,0,0}},"Live palette missing");
            for(int i=0;i<120;++i){
                publish(Json::array(),false);require(sample()==expected,"Empty palette replaced held colors");
                m.setPaletteSources(Json::array());require(sample()==expected,"Missing source replaced held colors");
                publish(Json::array({{{"r",2.},{"g",0.},{"b",0.}}}));require(sample()==expected,"Invalid palette replaced held colors");
                auto source=m.request("GET","/api/v1/sources/palettes").body["sources"][0];
                require(source["available"]==false&&source["held"]==true&&source["colors"]==red,"API hid held palette status");
            }
            publish(green);require(sample()==std::vector<flash_faces::Color>{{0,1,0}},"Recovery did not replace held palette");
            require(m.paletteSources()[0]["held"]==false,"Recovered palette still marked held");
            std::this_thread::sleep_for(std::chrono::milliseconds(3050));
            require(sample()==std::vector<flash_faces::Color>{{0,1,0}}&&m.paletteSources()[0]["available"]==false&&m.paletteSources()[0]["held"]==true,"Snapshot timeout lost last good palette");
            auto other=params;other["palette_source"]="patch:other";require(flash_faces::palette(other,m.paletteSources())==std::vector<flash_faces::Color>{{0,0,0}},"Palette leaked across sources");
            other["palette_source"]="";require(flash_faces::palette(other,m.paletteSources())[0]==flash_faces::color("#ff44aa"),"Explicit local theme stopped working");
            require(m.revision()==revision&&std::filesystem::last_write_time(root/"native-state.json")==fileTime,"Held palettes modified the saved show");
            std::cout<<"PASS: palette holds across 120 dropout cycles, invalid data, timeout, recovery, and source isolation\n";
        }
        auto cached=m.renderSnapshot();require(m.renderSnapshot()==cached,"Stable render snapshot was rebuilt");
        m.setControlRuntime("ui",{{"delayMs",123.},{"lateTicks",1}});
        require(m.renderSnapshot()["state"]["ui"]["delayMs"]==123.,"Render snapshot lost live runtime updates");
        require(m.request("GET","/api/v1/stats").body["ui"]["lateTicks"]==1,"Stats API lost UI telemetry");
        require(m.request("POST","/api/v1/mix",{{"led_master",.4}}).status==200,"Mixer edit failed");
        require(m.renderSnapshot()["state"]["mix"]["led_master"]==.4,"Render snapshot delayed a performance edit");
        m.request("POST","/api/v1/mix",{{"led_master",1.}});m.setControlRuntime("ui",Json::object());
        {
            command({{"action","set_fader_sync"},{"enabled",true}});
            auto fileTime=std::filesystem::last_write_time(root/"native-state.json");
            auto start=std::chrono::steady_clock::now();double worst=0;auto frame=m.renderSnapshot();
            for(int i=1;i<=254;++i){
                const double value=(i<=127?i:254-i)/127.;auto at=std::chrono::steady_clock::now();
                auto reply=m.request("POST","/api/v1/midi",{{"action","midi_fader_position"},{"value",value}});
                worst=std::max(worst,std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-at).count());
                require(reply.status==200,"APC fader rejected");frame=m.renderSnapshot();
                require(frame["state"]["grid"]["crossfade"]["program"]==value&&frame["outputs"]["out1"]["crossfade"]==value,"APC fader missed the next render snapshot");
                require(std::filesystem::last_write_time(root/"native-state.json")==fileTime,"Fader wrote the show while moving");
            }
            std::cout<<"APC sweep: 254 updates + render snapshots in "<<std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count()<<" ms; worst command "<<worst<<" ms\n";
            require(m.request("POST","/api/v1/midi",{{"action","midi_fader_position"},{"value",.7}}).status==200,"Final fader value failed");
            for(int i=0;i<100&&std::filesystem::last_write_time(root/"native-state.json")==fileTime;++i)std::this_thread::sleep_for(std::chrono::milliseconds(10));
            Json saved;{std::ifstream in(root/"native-state.json");in>>saved;}require(saved["grid"]["crossfade"]["program"]==.7&&saved["showContents"]["show_0"]["crossfade"]["program"]==.7,"Settled fader position was not saved");
            command({{"action","undo"}});require(m.snapshot()["state"]["grid"]["crossfade"]["program"]==0.,"Fader sweep did not undo as one gesture");
            command({{"action","redo"}});require(m.snapshot()["state"]["grid"]["crossfade"]["program"]==.7,"Fader sweep redo lost endpoint");
            command({{"action","set_fader_sync"},{"enabled",false}});fileTime=std::filesystem::last_write_time(root/"native-state.json");
            m.request("POST","/api/v1/midi",{{"action","midi_fader_position"},{"value",.2}});
            require(m.snapshot()["state"]["grid"]["crossfade"]["program"]==.7&&m.snapshot()["state"]["grid"]["fader_position"]==.2,"Detached fader changed output");
            require(std::filesystem::last_write_time(root/"native-state.json")==fileTime,"Detached hardware position hit disk");
            auto revision=m.revision();require(m.request("POST","/api/v1/midi",{{"action","midi_fader_position"},{"value",2}}).status==400&&m.revision()==revision,"Invalid fader value mutated state");
            command({{"action","set_crossfade"},{"value",0.}});command({{"action","set_controller_lights"},{"mode","full"}});
        }
        {
            const auto before=m.snapshot();const auto saved=before["mappings"]["1"];
            auto project=saved["project"];const auto fileTime=std::filesystem::last_write_time(root/"native-state.json");
            auto previousClock=m.renderSnapshot()["outputs"]["out1"]["clock"];const auto started=std::chrono::steady_clock::now();
            for(int i=0;i<120;++i){
                project["rects"][0]["corners"][0][0]=.1+i*.001;
                auto reply=m.request("POST","/api/v1/mappings/1/preview",{{"_owner","drag-check"},{"baseRevision",saved["revision"]},{"project",project}});
                require(reply.status==200,"Drag preview rejected");
                auto frame=m.renderSnapshot();require(frame["mappingPreviews"]["1"]["project"]["rects"][0]["corners"]==project["rects"][0]["corners"],"Render snapshot dropped the latest drag position");
                auto clock=frame["outputs"]["out1"]["clock"];require(clock["serverMonotonicNs"]>previousClock["serverMonotonicNs"]&&clock["seconds"]>previousClock["seconds"],"Drag preview froze or rewound the animation clock");previousClock=clock;
                require(frame["mappings"]["1"]==saved,"Ephemeral preview changed committed mapping");
                vj::applyMappingPreviews(frame);require(frame["mappings"]["1"]["project"]["rects"][0]["corners"]==project["rects"][0]["corners"],"Projector frame did not consume the latest geometry");
            }
            const auto elapsed=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-started).count();
            std::cout<<"Mapper preview: 120 consecutive edits reached their next render snapshot in "<<elapsed<<" ms ("<<elapsed/120<<" ms/edit)\n";
            require(m.request("GET","/api/v1/mappings/1").body==saved,"Public mapping API exposed uncommitted geometry");
            require(m.snapshot()["revision"]==before["revision"]&&std::filesystem::last_write_time(root/"native-state.json")==fileTime,"Drag preview persisted or advanced document revision");
            m.request("DELETE","/api/v1/mappings/1/preview",{{"_owner","other-client"}});
            require(m.renderSnapshot()["mappingPreviews"].contains("1"),"Another client cancelled the drag preview");
            m.request("DELETE","/api/v1/mappings/1/preview",{{"_owner","drag-check"}});
            auto cancelled=m.renderSnapshot();require(cancelled["mappingPreviews"].empty(),"Cancel delayed until snapshot expiry");
            vj::applyMappingPreviews(cancelled);require(cancelled["mappings"]["1"]==saved,"Cancelled preview left transformed geometry");
            require(m.request("POST","/api/v1/mappings/1/preview",{{"baseRevision",999},{"project",project}}).status==409,"Stale drag preview accepted");
        }
        auto revision=m.snapshot()["revision"];auto runtime=m.snapshot()["runtimeRevision"];
        require(m.request("GET","/api/v1/playback").body["available"]==false,"Uninitialized playback advertised");
        m.setPlaybackRuntime(Json::array({{{"sourceId","fixture"},{"playheadSeconds",12.5},{"durationSeconds",30.}}}));
        require(m.request("GET","/api/v1/playback").body["sources"][0]["playheadSeconds"]==12.5,"Playback telemetry lost");
        require(m.snapshot()["revision"]==revision&&m.snapshot()["runtimeRevision"]==runtime,"Playhead polluted edit/event revisions");
        require(m.request("POST","/api/v1/playback",{{"position",.5}}).status==405,"Playback endpoint accepted seek");
        require(m.snapshot()["state"]["startupPolicy"]=="isolated","Unsafe default startup policy");
        m.setRestoreDevices(true);require(m.snapshot()["state"]["startupPolicy"]=="restore","Restore policy not exposed");m.setRestoreDevices(false);
        const auto focusBefore=m.snapshot();
        auto focus=command({{"action","select_cell"},{"row","row_0"},{"column","column_1"}});
        auto focusAfter=m.snapshot();
        require(focusAfter["state"]["grid"]["control_focus"]["column"]=="column_1","Focus not published");
        require(focusAfter["state"]["grid"]["history"]==focusBefore["state"]["grid"]["history"],"Focus altered undo history");
        require(focusAfter["mappings"]==focusBefore["mappings"],"Focus changed render geometry");
        require(m.presentationSnapshot()["revision"]==focus["revision"],"Presentation snapshot stale after focus");
        require(m.request("POST","/api/v1/grid",{{"action","select_cell"},{"row","missing"},{"column","column_1"}}).status==400,"Invalid focus accepted");
        require(m.revision()==focus["revision"],"Invalid focus changed revision");
        {vj::Model reopened(root);require(reopened.snapshot()["state"]["grid"]["control_focus"]["column"]=="column_1","Focus not persisted");}
        auto before=stable(m.snapshot());auto conflict=m.request("POST","/api/v1/grid",{{"action","add_row"},{"revision",99}});require(conflict.status==409,"Stale edit accepted");require(stable(m.snapshot())==before,"Conflict changed state");
        auto invalid=m.request("POST","/api/v1/grid",{{"action","set_clip"},{"row","row_0"},{"column","column_0"},{"name","Changed"},{"opacity",2}});require(invalid.status==400,"Invalid opacity accepted");require(stable(m.snapshot())==before,"Invalid transaction partially applied");
        command({{"action","launch_clip"},{"row","row_0"},{"column","column_2"},{"bank","B"}});
        auto g=m.snapshot()["state"]["grid"];require(g["selections"]["program"]["row_0"]=="column_0","B changed A");require(g["selections_b"]["program"]["row_0"]=="column_2","B launch failed");
        command({{"action","stop_out"}});command({{"action","launch_clip"},{"row","row_0"},{"column","column_3"}});require(m.snapshot()["state"]["grid"]["running"]["program"]==false,"Launch resumed stopped output");
        command({{"action","undo"}});require(m.snapshot()["state"]["grid"]["selections"]["program"]["row_0"]=="column_0","Undo lost selection");command({{"action","redo"}});
        auto row=command({{"action","add_row"}})["result"]["id"];
        command({{"action","put_clip"},{"row",row},{"column","column_0"},{"effect","solid_color"},{"params",{{"color","#123456"}}}});
        command({{"action","launch_clip"},{"row",row},{"column","column_0"}});command({{"action","delete_row"},{"row",row}});
        require(!m.snapshot()["state"]["grid"]["selections"]["program"].contains(row.get<std::string>()),"Deleted row left stale selection");
        auto show=m.snapshot()["state"]["grid"]["active_show"];
        command({{"action","create_show"},{"name","Other"}});require(m.snapshot()["state"]["grid"]["rows"].empty(),"New show not empty");command({{"action","select_show"},{"show",show}});require(m.snapshot()["state"]["grid"]["rows"].size()==1,"Show content lost");
        require(m.request("PUT","/api/v1/outputs",{{"count",3}}).status==200,"Output resize failed");
        command({{"action","duplicate_show"}});auto duplicate=m.snapshot()["state"]["grid"];
        require(duplicate["rows"][0]["id"]!="row_0"&&duplicate["columns"][0]["id"]!="column_0","Duplicate reused object IDs");
        command({{"action","select_show"},{"show",show}});command({{"action","undo"}});
        require(m.snapshot()["state"]["grid"]["running"].size()==3,"Show or undo restored old output count");command({{"action","redo"}});
        command({{"action","set_clip"},{"row","row_0"},{"column","column_3"},{"blend","subtract"}});
        const auto scene=vj::renderScene(m.snapshot(),{"program"},12.5);
        require(scene.buses.at("programA").layers[0].blend=="subtract","Clip blend lost in render scene");
        require(scene.buses.at("programA").layers[0].source_id!=scene.buses.at("programB").layers[0].source_id,"Render scene mixed A/B sources");
        require(!scene.buses.at("program").running,"Render scene resumed stopped output");
        command({{"action","set_clip"},{"row","row_0"},{"column","column_3"},{"opacity",.4}});
        command({{"action","set_clip"},{"row","row_0"},{"column","column_3"},{"opacity",.6}});command({{"action","undo"}});
        require(m.snapshot()["state"]["grid"]["rows"][0]["clips"]["column_3"]["opacity"]==1.0,"Slider gesture did not coalesce");command({{"action","redo"}});
        const auto geometry=m.snapshot()["mappings"]["1"];
        auto bad=m.request("PATCH","/api/v1/mappings/1/rects/rect-1",{{"revision",0},{"name","Oops"},{"cornerRadius",2}});require(bad.status==400,"Invalid mapping accepted");require(m.snapshot()["mappings"]["1"]==geometry,"Invalid mapping partially applied");
        require(m.request("PATCH","/api/v1/mappings/1/rects/rect-1",{{"revision",0},{"name","Card"}}).status==200,"Mapping edit failed");require(m.request("PATCH","/api/v1/mappings/1/rects/rect-1",{{"revision",0},{"name","Stale"}}).status==409,"Mapping conflict accepted");
        command({{"action","put_clip"},{"row","row_0"},{"column","column_5"},{"effect","video"}});
        for(int i=0;i<2;++i)command({{"action","video_transport"},{"operation","seek"},{"position",.5},{"row","row_0"},{"column","column_5"}});
        auto params=m.snapshot()["state"]["grid"]["rows"][0]["clips"]["column_5"]["params"];require(params["seek_nonce"]==2,"Repeated same-position seek did not retrigger");
        command({{"action","video_transport"},{"operation","stop"},{"row","row_0"},{"column","column_5"}});
        params=m.snapshot()["state"]["grid"]["rows"][0]["clips"]["column_5"]["params"];require(params["position"]==0&&params["playing"]==false&&params["seek_nonce"]==3,"Video stop is not atomic");
        require(m.request("PATCH","/api/v1/mappings/1/output",{{"enabled",false},{"revision",m.snapshot()["mappings"]["1"]["revision"]}}).status==200,"Could not disable mapping fixture");auto disabledRevision=m.snapshot()["mappings"]["1"]["revision"].get<uint64_t>();
        Json assignments={{"1",{{"displayId","fixture-display"},{"enabled",true}}}};
        require(m.request("PUT","/api/v1/display-assignments",{{"assignments",assignments}}).status==200,"Display assignment failed");
        require(m.snapshot()["mappings"]["1"]["project"]["output"]["enabled"]==true&&m.snapshot()["mappings"]["1"]["revision"]==disabledRevision+1,"Assign did not enable imported disabled mapping atomically");
        require(m.request("PATCH","/api/v1/mappings/1/output",{{"enabled",false},{"revision",m.snapshot()["mappings"]["1"]["revision"]}}).status==200,"Could not mute output fixture");
        require(m.request("PUT","/api/v1/display-assignments",{{"assignments",assignments}}).status==200&&m.snapshot()["mappings"]["1"]["project"]["output"]["enabled"]==false,"Unchanged assignments unexpectedly unmuted mapping");
        require(m.request("PUT","/api/v1/display-assignments",{{"assignments",assignments},{"activate","1"}}).status==200&&m.snapshot()["mappings"]["1"]["project"]["output"]["enabled"]==true,"Explicit reassignment did not reactivate mapping");
        auto stableAssignment=m.snapshot();require(m.request("PUT","/api/v1/display-assignments",{{"assignments",assignments},{"activate","2"}}).status==400&&m.snapshot()["revision"]==stableAssignment["revision"],"Invalid activation changed state");
        auto duplicateAssignments=assignments;duplicateAssignments["2"]=assignments["1"];
        require(m.request("PUT","/api/v1/display-assignments",{{"assignments",duplicateAssignments}}).status==400,"Duplicate display accepted");
        auto output=m.request("GET","/api/v1/display-assignments").body;require(output["assignments"]==assignments,"Invalid output edit partially applied");require(output["runtime"]["projectors"]["1"]["display"]["active"]==false,"Headless runtime advertised active display");
        vj::Model restored(root);auto loaded=restored.snapshot(),current=m.snapshot();loaded["state"]["grid"].erase("history");current["state"]["grid"].erase("history");for(auto* snapshot:{&loaded,&current})for(auto& mapping:(*snapshot)["mappings"])mapping.erase("history");require(stable(loaded)==stable(current),"Restart lost saved state");
        {vj::ApiServer server(m,0);require(server.port()>0,"API did not bind");}
        Json backup;{std::ifstream in(root/"native-state.json.bak");in>>backup;}
        {std::ofstream corrupt(root/"native-state.json");corrupt<<"{partial";}
        vj::Model recovered(root);auto recovery=recovered.snapshot();
        require(recovery["nativeDevelopment"]["recoveredBackup"].get<bool>(),"Corrupt primary did not recover backup");
        auto recoveredGrid=recovery["state"]["grid"];recoveredGrid.erase("history");for(auto& row:recoveredGrid["rows"])for(auto& clip:row["clips"]){clip.erase("resolved_file");clip.erase("mediaStatus");clip.erase("textStatus");}require(recoveredGrid==backup["grid"],"Backup recovery changed saved grid");
        std::filesystem::remove_all(root);std::cout<<"PASS: native atomic commands, revisions, A/B isolation, transport, undo/redo, Show persistence, mapping validation, API lifecycle\n";
    }catch(const std::exception& e){std::filesystem::remove_all(root);std::cerr<<e.what()<<"\n";return 1;}
}

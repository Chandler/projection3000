#import <Foundation/Foundation.h>
#include "native_async.hpp"
#include <atomic>
#include <map>
#include <memory>
namespace {
using Completion=void (^)(const vj::Reply&);
struct Command {
    std::string key;
    vj::Json body;
    std::vector<Completion> completions;
    bool started=false;
};
struct Lane {
    dispatch_queue_t queue=dispatch_queue_create("com.vibe.native.editor.commands",DISPATCH_QUEUE_SERIAL);
    dispatch_group_t work=dispatch_group_create();
    std::atomic<bool> closed{false};std::atomic<unsigned> pending{0};
    std::map<uint64_t,uint64_t> revisions;
    std::mutex guard;
    std::shared_ptr<Command> tail;
};
std::map<vj::Model*,std::shared_ptr<Lane>> lanes; // main-thread owned
}
void VJSubmitUiCommand(vj::Model* model,std::string method,std::string path,vj::Json body,Completion completion,std::string key){
    NSCAssert(NSThread.isMainThread,@"UI commands originate on the main thread");
    auto& slot=lanes[model];if(!slot)slot=std::make_shared<Lane>();auto lane=slot;++lane->pending;
    auto job=std::make_shared<Command>();
    {
        std::lock_guard lock(lane->guard);
        // Only collapse adjacent updates to the same continuous control. Never
        // cross a discrete action, a different target or a revision boundary.
        if(!key.empty()&&lane->tail&&!lane->tail->started&&lane->tail->key==key&&lane->tail->body.value("revision",vj::Json())==body.value("revision",vj::Json())){
            lane->tail->body=std::move(body);lane->tail->completions.push_back([completion copy]);return;
        }
        job->key=std::move(key);job->body=std::move(body);job->completions.push_back([completion copy]);lane->tail=job;
    }
    dispatch_group_async(lane->work,lane->queue,^{@autoreleasepool{
        {std::lock_guard lock(lane->guard);job->started=true;}
        if(lane->closed){lane->pending-=job->completions.size();return;}
        const bool preview=path.starts_with("/api/v1/mappings/")&&path.ends_with("/preview");
        auto started=std::chrono::steady_clock::now();auto command=job->body;const auto before=preview?0:model->revision();
        const bool global=path.find("/mappings/")==std::string::npos&&path.find("/mapping-layouts")==std::string::npos&&path.find("/room")==std::string::npos;
        if(global&&command.contains("revision")&&command["revision"].is_number_unsigned()){
            auto expected=command["revision"].get<uint64_t>();auto found=lane->revisions.find(expected);
            // Rebase only through our own acknowledged commits. An intervening
            // API edit still conflicts, including while commands are queued.
            if(found!=lane->revisions.end()&&before==found->second)command["revision"]=found->second;
        }
        auto reply=model->request(method,path,command);
        if(global&&reply.status<300&&command.contains("revision")&&(reply.committedRevision||reply.body.contains("revision"))){
            auto from=command["revision"].get<uint64_t>(),to=reply.committedRevision?*reply.committedRevision:reply.body["revision"].get<uint64_t>();
            for(auto& [base,head]:lane->revisions)if(head==from)head=to;
            lane->revisions[from]=to;while(lane->revisions.size()>128)lane->revisions.erase(lane->revisions.begin());
        }
        // Render snapshots consume previews directly. Building a complete UI/API
        // snapshot for each pointer position only queues work behind the pointer.
        if(!preview)model->snapshot(); // Publish committed presentation state off the UI thread.
        if(getenv("VJ_PROFILE_UI")&&path=="/api/v1/grid")NSLog(@"UI command %s completed %.2f ms",command.value("action",std::string{}).c_str(),std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-started).count());
        dispatch_async(dispatch_get_main_queue(),^{for(Completion callback:job->completions){--lane->pending;if(!lane->closed&&callback)callback(reply);}});
    }});
}
bool VJUiCommandsIdle(vj::Model* model){auto found=lanes.find(model);return found==lanes.end()||found->second->pending==0;}
void VJStopUiCommands(vj::Model* model){auto found=lanes.find(model);if(found==lanes.end())return;auto lane=found->second;
    // Finish accepted edits before closing the lane. Closing first discarded
    // queued composer changes during quit, leaving the previous saved show.
    // Workers never wait on their main-thread completions, so draining here is safe.
    dispatch_group_wait(lane->work,DISPATCH_TIME_FOREVER);lane->closed=true;lanes.erase(found);}
void VJPublishUiOutputRuntime(vj::Model* model,vj::Json runtime){auto& slot=lanes[model];if(!slot)slot=std::make_shared<Lane>();auto lane=slot;dispatch_group_async(lane->work,lane->queue,^{if(!lane->closed)model->setOutputRuntime(runtime);});}

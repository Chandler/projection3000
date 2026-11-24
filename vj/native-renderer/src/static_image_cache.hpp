#pragma once
#include "static_image.hpp"
#include <atomic>
#include <condition_variable>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <thread>

// Shared CPU cache across output, monitor, and thumbnail renderers. Decoding
// never runs on a GL/render queue; only completed images reach texture upload.
class StaticImageCache {
public:
    struct Request {
        std::atomic<bool> ready{false};
        std::shared_ptr<const RgbaImage> image;
        std::uint64_t used=0;
    };
    static StaticImageCache& shared(){static StaticImageCache cache;return cache;}
    std::shared_ptr<Request> request(const std::string& path,int limit){
        std::lock_guard lock(mutex_);const auto key=path+"\n"+std::to_string(limit);
        if(auto found=entries_.find(key);found!=entries_.end()){found->second->used=++clock_;return found->second;}
        // Backpressure: callers retry next frame instead of growing an
        // unbounded work queue while rapidly browsing a media library.
        if(jobs_.size()>=128)return {};
        auto result=std::make_shared<Request>();result->used=++clock_;entries_[key]=result;
        jobs_.push_back({path,limit,result});wake_.notify_one();return result;
    }
private:
    struct Job {std::string path;int limit;std::shared_ptr<Request> result;};
    std::mutex mutex_;std::condition_variable wake_;std::deque<Job> jobs_;
    std::map<std::string,std::shared_ptr<Request>> entries_;
    std::vector<std::thread> workers_;bool stopping_=false;std::uint64_t clock_=0;
    StaticImageCache(){for(int i=0;i<2;++i)workers_.emplace_back([this]{run();});}
    ~StaticImageCache(){ {std::lock_guard lock(mutex_);stopping_=true;jobs_.clear();}wake_.notify_all();for(auto& worker:workers_)worker.join();}
    void trim(){
        size_t bytes=0;for(const auto& [key,r]:entries_)if(r->ready.load()&&r->image)bytes+=r->image->pixels.size();
        while(bytes>128*1024*1024||entries_.size()>256){
            auto oldest=entries_.end();
            for(auto it=entries_.begin();it!=entries_.end();++it)if(it->second.use_count()==1&&it->second->ready.load()&&(oldest==entries_.end()||it->second->used<oldest->second->used))oldest=it;
            if(oldest==entries_.end())break;
            if(oldest->second->image)bytes-=oldest->second->image->pixels.size();entries_.erase(oldest);
        }
    }
    void run(){for(;;){
        Job job;
        {std::unique_lock lock(mutex_);wake_.wait(lock,[this]{return stopping_||!jobs_.empty();});if(stopping_)return;job=std::move(jobs_.front());jobs_.pop_front();}
        try{if(auto decoded=load_static_image(job.path,job.limit))job.result->image=std::make_shared<RgbaImage>(std::move(*decoded));}catch(...){ }
        job.result->ready.store(true);
        {std::lock_guard lock(mutex_);job.result.reset();trim();}
    }}
};

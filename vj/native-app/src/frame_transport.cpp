#include "frame_transport.hpp"
#include "api_error.hpp"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <mutex>
#include <set>
#include <thread>
namespace vj {
namespace {
using Clock=std::chrono::steady_clock;using J=nlohmann::json;
constexpr auto staleAfter=std::chrono::seconds(2);
constexpr size_t maxRawBytes=128u*1024*1024,maxFrameBytes=32u*1024*1024;
constexpr size_t maxClients=128;
int outIndex(const std::string& name){if(name=="program"||name=="out1")return 1;if(!name.starts_with("out"))return 0;const auto tail=name.substr(3);if(tail.empty()||tail.size()>2||tail[0]=='0'||!std::all_of(tail.begin(),tail.end(),[](char c){return c>='0'&&c<='9';}))return 0;int result=std::stoi(tail);return result<=20?result:0;}
std::string bus(int index){return index==1?"program":"out"+std::to_string(index);}
int channelIndex(std::string name){if(name.ends_with("A")||name.ends_with("B"))name.pop_back();return outIndex(name);}
bool mappingId(const std::string& id){return id=="1"||id=="2"||id=="3"||id=="4";}
std::string profile(const J& query){auto p=query.value("profile",std::string{});return p=="normal"||p=="hd"||p=="mobile"||p=="monitor"?p:"auto";}
int scaledHeight(int width,int baseWidth,int baseHeight){return std::max(1,int(std::nearbyint(double(width)*baseHeight/std::max(1,baseWidth))));}
}
std::optional<FrameStreamRoute> frameStreamRoute(const std::string& path,const J& query,int activeOutputs){
    int index=0;std::string bank;
    if(path=="/ws/output")index=1;
    else if(path.starts_with("/ws/outputs/")){
        auto rest=path.substr(12);auto separator=rest.find("/banks/");if(separator==std::string::npos)throw ApiError(404,"Unknown frame stream");
        index=outIndex(rest.substr(0,separator));bank=rest.substr(separator+7);if(bank=="a")bank="A";if(bank=="b")bank="B";
        if(bank!="A"&&bank!="B")throw ApiError(404,"Choose bank A or B");
    }else if(path.starts_with("/ws/output")){auto tail=path.substr(10);if(tail.empty()||tail=="1")throw ApiError(404,"Unknown frame stream");index=outIndex("out"+tail);}
    else return std::nullopt;
    if(index<1||index>20)throw ApiError(404,"Unknown output");if(index>activeOutputs)throw ApiError(404,"Output is inactive.");
    return FrameStreamRoute{bus(index)+bank,profile(query)};
}
std::optional<std::string> mappingFrameRoute(const std::string& path){
    const std::string prefix="/api/mapping/",suffix="/frame";if(!path.starts_with(prefix)||!path.ends_with(suffix))return std::nullopt;
    auto id=path.substr(prefix.size(),path.size()-prefix.size()-suffix.size());if(!mappingId(id))throw ApiError(404,"Unknown mapping");return id;
}
struct FrameTransport::Impl {
    struct Viewer {std::string channel,profile;Clock::time_point queued{};std::optional<EncodedFrame> pending;std::uint64_t sequence=0;};
    struct Slot {FrameImage image;Clock::time_point lease{};std::map<std::string,EncodedFrame> encoded;};
    mutable std::mutex mutex;std::condition_variable changed;bool stopping=false;Encoder encoder;
    std::map<Client,Viewer> viewers;std::map<std::string,Slot> slots;std::set<std::string> pending;
    std::map<Client,uint64_t> ledViewers;std::shared_ptr<const std::string> ledLatest;Clock::time_point ledCaptured{};uint64_t ledSequence=0;
    Client nextClient=0;std::uint64_t nextFrame=0;size_t rawBytes=0,replaced=0,encodedCount=0;std::string error,lastChannel;
    std::shared_ptr<std::atomic<size_t>> encodedBytes=std::make_shared<std::atomic<size_t>>(0);
    int width=960,height=540,fps=30,quality=72,outputs=1;bool hd=false;std::thread worker;
    Impl():worker([this]{run();}){}
    ~Impl(){{std::lock_guard lock(mutex);stopping=true;}changed.notify_all();worker.join();}
    bool fresh(const FrameImage& image,Clock::time_point now)const{return image.rgb&&now-image.captured<=staleAfter;}
    std::string resolved(const Viewer& v)const{return v.profile=="hd"||(v.profile=="auto"&&hd)?"hd":v.profile=="mobile"?"mobile":"normal";}
    FrameDemand viewerDemand(const Viewer& v)const{
        FrameDemand d;d.fps=(v.profile=="mobile"||v.profile=="monitor")?12:fps;
        if(v.profile=="mobile"||v.profile=="monitor"){d.width=std::min(v.profile=="mobile"?480:640,width);d.height=scaledHeight(d.width,width,height);}
        else if(resolved(v)=="hd"){d.width=std::max(1280,std::min(1920,width*2));d.height=std::max(720,scaledHeight(d.width,width,height));}
        else {d.width=width;d.height=height;}return d;
    }
    std::map<std::string,FrameDemand> demands(Clock::time_point now)const{
        std::map<std::string,FrameDemand> result;
        for(const auto& [id,v]:viewers){(void)id;auto d=viewerDemand(v);auto& target=result[v.channel];target.width=std::max(target.width,d.width);target.height=std::max(target.height,d.height);target.fps=std::max(target.fps,d.fps);}
        for(const auto& [key,slot]:slots)if(slot.lease>now){auto mid=key.substr(8,1),transport=key.substr(10);result[key]={960,scaledHeight(960,width,height),double(fps),mid,transport};}
        return result;
    }
    FrameEncoding encoding(const std::string& name,const FrameImage& image)const{
        FrameEncoding e{image.width,image.height,quality,false};
        if(name=="hd"){e.width=std::max(1280,std::min(1920,width*2));e.height=std::max(720,scaledHeight(e.width,width,height));e.quality=std::max(quality,90);}
        if(name=="mobile"){e.width=std::min(480,width);e.height=scaledHeight(e.width,width,height);e.quality=std::min(quality,58);}
        if(name=="mapping"||name=="room"){e.width=std::min(960,image.width);e.height=scaledHeight(e.width,image.width,image.height);e.quality=88;e.png=name=="room";}
        return e;
    }
    void prune(Clock::time_point now){
        const auto active=demands(now);for(auto it=slots.begin();it!=slots.end();)if(!active.contains(it->first)&&!fresh(it->second.image,now)){if(it->second.image.rgb)rawBytes-=it->second.image.rgb->size();pending.erase(it->first);it=slots.erase(it);}else ++it;
    }
    void run(){
        for(;;){std::string channel;FrameImage frame;Encoder encode;std::map<std::string,FrameEncoding> specs;std::vector<std::pair<Client,std::string>> clients;
            {std::unique_lock lock(mutex);changed.wait(lock,[&]{return stopping||(!pending.empty()&&bool(encoder));});if(stopping)return;
                auto queued=pending.upper_bound(lastChannel);if(queued==pending.end())queued=pending.begin();channel=*queued;pending.erase(queued);lastChannel=channel;auto it=slots.find(channel);if(it==slots.end()||!fresh(it->second.image,Clock::now()))continue;frame=it->second.image;encode=encoder;
                const auto now=Clock::now();for(const auto& [id,v]:viewers)if(v.channel==channel&&v.sequence!=frame.sequence){const double rate=viewerDemand(v).fps;if(v.queued!=Clock::time_point{}&&std::chrono::duration<double>(now-v.queued).count()<1/rate)continue;auto name=resolved(v);specs[name]=encoding(name,frame);clients.emplace_back(id,name);}
                if(it->second.lease>now){auto name=channel.ends_with("-room")?"room":"mapping";specs[name]=encoding(name,frame);}
            }
            std::map<std::string,EncodedFrame> results;
            for(const auto& [name,spec]:specs){try{auto bytes=encode(frame,spec);if(bytes.empty()||bytes.size()>maxFrameBytes)throw std::runtime_error("Invalid encoded frame size");auto storage=std::make_unique<std::vector<std::uint8_t>>(std::move(bytes));const size_t size=storage->size();auto budget=encodedBytes;
                    if(budget->fetch_add(size)+size>64u*1024*1024){budget->fetch_sub(size);throw std::runtime_error("Encoded frame memory limit reached");}
                    std::shared_ptr<const std::vector<std::uint8_t>> shared(storage.release(),[budget,size](const auto* value){delete value;budget->fetch_sub(size);});
                    results[name]={std::move(shared),spec.png?"image/png":"image/jpeg",spec.width,spec.height,frame.sequence,frame.captured};}
                catch(const std::exception& e){std::lock_guard lock(mutex);error=e.what();}}
            {std::lock_guard lock(mutex);if(stopping)return;auto it=slots.find(channel);if(it==slots.end()||!fresh(frame,Clock::now()))continue;
                // New raw arrivals remain pending; completed packets still make
                // progress rather than starving until a slow encoder catches up.
                for(const auto& [name,encoded]:results)it->second.encoded[name]=encoded;encodedCount+=results.size();
                for(const auto& [id,name]:clients){auto client=viewers.find(id);if(client==viewers.end()||client->second.channel!=channel||!results.contains(name))continue;auto& v=client->second;if(v.pending)++replaced;v.pending=results.at(name);v.sequence=frame.sequence;v.queued=Clock::now();}
            }
        }
    }
};
FrameTransport::FrameTransport():impl_(std::make_unique<Impl>()){}FrameTransport::~FrameTransport()=default;
void FrameTransport::configure(int width,int height,int fps,int quality,int activeOutputs,bool streamHD){
    if(width<1||width>8192||height<1||height>8192||size_t(width)*height*3>maxFrameBytes)throw ApiError(400,"Invalid frame dimensions");
    std::lock_guard lock(impl_->mutex);impl_->width=width;impl_->height=height;impl_->fps=std::clamp(fps,1,120);impl_->quality=std::clamp(quality,1,100);impl_->outputs=std::clamp(activeOutputs,1,20);impl_->hd=streamHD;
    for(auto it=impl_->viewers.begin();it!=impl_->viewers.end();)if(channelIndex(it->second.channel)>impl_->outputs)it=impl_->viewers.erase(it);else ++it;
}
void FrameTransport::setStreamHD(bool enabled){std::lock_guard lock(impl_->mutex);if(impl_->hd==enabled)return;impl_->hd=enabled;for(auto& [id,viewer]:impl_->viewers){viewer.pending.reset();viewer.queued={};viewer.sequence=0;impl_->pending.insert(viewer.channel);}impl_->changed.notify_one();}
void FrameTransport::setActiveOutputs(int count){std::lock_guard lock(impl_->mutex);impl_->outputs=std::clamp(count,1,20);for(auto it=impl_->viewers.begin();it!=impl_->viewers.end();)if(channelIndex(it->second.channel)>impl_->outputs)it=impl_->viewers.erase(it);else ++it;}
void FrameTransport::setEncoder(Encoder encoder){{std::lock_guard lock(impl_->mutex);impl_->encoder=std::move(encoder);}impl_->changed.notify_one();}
std::vector<std::uint8_t> FrameTransport::encodeImage(const FrameImage& image,const FrameEncoding& encoding)const{Encoder encode;{std::lock_guard lock(impl_->mutex);encode=impl_->encoder;}if(!encode)throw ApiError(501,"Frame encoder unavailable in this runtime");return encode(image,encoding);}
int FrameTransport::activeOutputs()const{std::lock_guard lock(impl_->mutex);return impl_->outputs;}
FrameTransport::Client FrameTransport::subscribeLeds(){std::lock_guard lock(impl_->mutex);if(impl_->ledViewers.size()>=maxClients)throw ApiError(503,"LED subscriber limit reached");auto id=++impl_->nextClient;impl_->ledViewers[id]=0;return id;}
void FrameTransport::unsubscribeLeds(Client client){std::lock_guard lock(impl_->mutex);impl_->ledViewers.erase(client);if(impl_->ledViewers.empty())impl_->ledLatest.reset();}
std::shared_ptr<const std::string> FrameTransport::takeLeds(Client client){std::lock_guard lock(impl_->mutex);auto it=impl_->ledViewers.find(client);if(it==impl_->ledViewers.end()||!impl_->ledLatest||it->second==impl_->ledSequence||Clock::now()-impl_->ledCaptured>staleAfter)return {};it->second=impl_->ledSequence;return impl_->ledLatest;}
bool FrameTransport::publishLedFrames(const std::map<std::string,std::vector<std::uint8_t>>& frames,bool virtualActive){
    const auto now=Clock::now();{std::lock_guard lock(impl_->mutex);if(impl_->ledViewers.empty()||std::chrono::duration<double>(now-impl_->ledCaptured).count()<1./(virtualActive?30:15))return false;}
    if(frames.empty()||frames.size()>1024)return false;size_t total=0;J payload=J::object();static constexpr char alphabet[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for(const auto& [id,bytes]:frames){if(id.empty()||id.size()>256||bytes.empty()||bytes.size()%3)return false;total+=bytes.size();if(total>1024u*1024)return false;std::string encoded;encoded.reserve((bytes.size()+2)/3*4);
        for(size_t i=0;i<bytes.size();i+=3){const uint32_t value=(uint32_t(bytes[i])<<16)|(uint32_t(bytes[i+1])<<8)|bytes[i+2];encoded+=alphabet[(value>>18)&63];encoded+=alphabet[(value>>12)&63];encoded+=alphabet[(value>>6)&63];encoded+=alphabet[value&63];}payload[id]=std::move(encoded);
    }
    auto text=std::make_shared<const std::string>(J{{"type","led_frames"},{"frames",std::move(payload)}}.dump());std::lock_guard lock(impl_->mutex);if(impl_->ledViewers.empty())return false;impl_->ledLatest=std::move(text);impl_->ledCaptured=now;++impl_->ledSequence;return true;
}
FrameTransport::Client FrameTransport::subscribe(const FrameStreamRoute& route){
    std::lock_guard lock(impl_->mutex);int index=channelIndex(route.channel);if(index<1||index>impl_->outputs)throw ApiError(404,"Output is inactive.");if(impl_->viewers.size()>=maxClients)throw ApiError(503,"Frame subscription limit reached");
    auto id=++impl_->nextClient;impl_->viewers[id]={route.channel,profile({{"profile",route.profile}})};if(impl_->slots.contains(route.channel))impl_->pending.insert(route.channel);impl_->changed.notify_one();return id;
}
void FrameTransport::unsubscribe(Client client){std::lock_guard lock(impl_->mutex);impl_->viewers.erase(client);impl_->prune(Clock::now());}
bool FrameTransport::connected(Client client)const{std::lock_guard lock(impl_->mutex);return impl_->viewers.contains(client);}
std::optional<EncodedFrame> FrameTransport::take(Client client){std::lock_guard lock(impl_->mutex);auto it=impl_->viewers.find(client);if(it==impl_->viewers.end())return {};auto frame=std::move(it->second.pending);it->second.pending.reset();auto slot=impl_->slots.find(it->second.channel);if(slot==impl_->slots.end()||!impl_->fresh(slot->second.image,Clock::now())||(frame&&Clock::now()-frame->captured>staleAfter))return {};return frame;}
std::map<std::string,FrameDemand> FrameTransport::demand()const{std::lock_guard lock(impl_->mutex);return impl_->demands(Clock::now());}
bool FrameTransport::due(const std::string& channel)const{std::lock_guard lock(impl_->mutex);const auto now=Clock::now();const auto demand=impl_->demands(now);auto d=demand.find(channel);if(d==demand.end())return false;auto slot=impl_->slots.find(channel);return slot==impl_->slots.end()||!slot->second.image.rgb||std::chrono::duration<double>(now-slot->second.image.captured).count()>=1/d->second.fps;}
bool FrameTransport::publish(const std::string& channel,int width,int height,std::vector<std::uint8_t> rgb,int channels){
    if((channels!=3&&channels!=4)||width<1||height<1||width>8192||height>8192||size_t(width)*height*channels!=rgb.size()||rgb.size()>maxFrameBytes)return false;
    std::lock_guard lock(impl_->mutex);const auto now=Clock::now();impl_->prune(now);if(!impl_->demands(now).contains(channel))return false;
    auto& slot=impl_->slots[channel];const auto oldSize=slot.image.rgb?slot.image.rgb->size():0;if(impl_->rawBytes-oldSize+rgb.size()>maxRawBytes)return false;
    impl_->rawBytes=impl_->rawBytes-oldSize+rgb.size();slot.image={width,height,++impl_->nextFrame,now,std::make_shared<const std::vector<std::uint8_t>>(std::move(rgb)),channels};if(impl_->pending.contains(channel))++impl_->replaced;impl_->pending.insert(channel);impl_->changed.notify_one();return true;
}
std::optional<FrameImage> FrameTransport::latest(const std::string& channel)const{std::lock_guard lock(impl_->mutex);auto it=impl_->slots.find(channel);if(it==impl_->slots.end()||!impl_->fresh(it->second.image,Clock::now()))return {};return it->second.image;}
std::optional<EncodedFrame> FrameTransport::mappingFrame(const std::string& id,bool room){
    if(!mappingId(id))throw ApiError(404,"Unknown mapping");std::lock_guard lock(impl_->mutex);const auto now=Clock::now();std::optional<EncodedFrame> result;
    for(const auto& transport:room?std::vector<std::string>{"room"}:std::vector<std::string>{"physical","ndi"}){
        const auto key="mapping-"+id+"-"+transport;auto& slot=impl_->slots[key];slot.lease=now+staleAfter;const auto profile=room?"room":"mapping";
        if(impl_->fresh(slot.image,now)){auto found=slot.encoded.find(profile);if(found!=slot.encoded.end()&&now-found->second.captured<=staleAfter&&!result)result=found->second;if(found==slot.encoded.end()||found->second.sequence!=slot.image.sequence)impl_->pending.insert(key);}
    }impl_->changed.notify_one();return result;
}
J FrameTransport::diagnostics()const{std::lock_guard lock(impl_->mutex);J clients=J::object();for(const auto& [id,viewer]:impl_->viewers){(void)id;clients[viewer.channel]=clients.value(viewer.channel,0)+1;}J demands=J::object();for(const auto& [channel,d]:impl_->demands(Clock::now()))demands[channel]={{"width",d.width},{"height",d.height},{"fps",d.fps}};return {{"config",{{"width",impl_->width},{"height",impl_->height},{"fps",impl_->fps},{"quality",impl_->quality},{"activeOutputs",impl_->outputs},{"hd",impl_->hd}}},{"clients",impl_->viewers.size()},{"clientsByBus",clients},{"ledClients",impl_->ledViewers.size()},{"ledSequence",impl_->ledSequence},{"channels",impl_->slots.size()},{"rawBytes",impl_->rawBytes},{"encodedBytes",impl_->encodedBytes->load()},{"pending",impl_->pending.size()},{"replaced",impl_->replaced},{"encoded",impl_->encodedCount},{"encoderAvailable",bool(impl_->encoder)},{"error",impl_->error},{"demand",demands}};}
}

#include "api_addresses.hpp"
#include "api_server.hpp"
#include "api_error.hpp"
#include "media_http.hpp"
#include "ui_commands.hpp"
#include <boost/asio.hpp>
#include <boost/beast.hpp>
#include <boost/beast/websocket.hpp>
#include <atomic>
#include <deque>
#include <optional>
#include <set>
#include <thread>
namespace vj {
namespace asio=boost::asio;namespace beast=boost::beast;namespace http=beast::http;namespace websocket=beast::websocket;using tcp=asio::ip::tcp;
namespace {
struct Target {std::string path;Json query=Json::object();};
int hex(char c){if(c>='0'&&c<='9')return c-'0';if(c>='a'&&c<='f')return c-'a'+10;if(c>='A'&&c<='F')return c-'A'+10;return -1;}
std::string decode(std::string_view value,bool query){
    std::string result;for(size_t i=0;i<value.size();++i){unsigned char c=value[i];if(c=='%'){
        if(i+2>=value.size()||hex(value[i+1])<0||hex(value[i+2])<0)throw ApiError(400,"Malformed URL escape");c=hex(value[i+1])*16+hex(value[i+2]);i+=2;
    }else if(query&&c=='+')c=' ';if(c==0||c<32||c==127)throw ApiError(400,"Control character in URL");result.push_back(char(c));}return result;
}
Target parseTarget(std::string_view raw){
    if(raw.empty()||raw.front()!='/'||raw.find('#')!=std::string_view::npos)throw ApiError(400,"Expected an origin-form request target");
    const auto at=raw.find('?');Target target;target.path=decode(raw.substr(0,at),false);
    if(at!=std::string_view::npos){auto query=raw.substr(at+1);while(!query.empty()){
        auto end=query.find('&');auto pair=query.substr(0,end);auto split=pair.find('=');auto key=decode(pair.substr(0,split),true);
        auto value=split==std::string_view::npos?std::string{}:decode(pair.substr(split+1),true);
        // aiohttp's request.query.get selects the first repeated value.
        if(!key.empty()&&!target.query.contains(key))target.query[key]=value;
        if(end==std::string_view::npos)break;query.remove_prefix(end+1);
    }}return target;
}
bool external(const std::string& path){return path.starts_with("/api/v1/")||path.starts_with("/vector/")||path.starts_with("/mapping/js/")||path=="/mapping/graphics.js";}
bool mediaUploadRoute(const std::string& path){return path=="/api/videos/upload"||path=="/api/files/upload";}
bool mediaAssetRoute(const std::string& path){return path.starts_with("/videos/")||path.starts_with("/native-media/")||path.starts_with("/removable/")||path=="/api/videos/thumbnail"||path.starts_with("/api/clips/text-thumbnail/");}
bool backgroundRequest(const std::string& method,const std::string& path){
    if(path=="/api/v1/fixture-output/discover")return true;
    if(path=="/api/videos"||path=="/api/images"||path.starts_with("/api/removable")||path=="/api/v1/media/drives"||path=="/api/v1/effects"||path.starts_with("/api/v1/effects/"))return true;
    if(path.starts_with("/api/v1/ndi/clients")||path=="/api/v1/network"||path=="/api/v1/stats")return true;
    if(path=="/api/videos/subtitles"||path=="/api/v1/media/subtitles"||path=="/api/v1/media/preprocess")return true;
    if(path.starts_with("/api/calibration/")||path=="/api/calibrations"||path.starts_with("/api/calibrations/"))return true;
    if((method=="POST"||method=="GET"||method=="HEAD")&&path=="/api/v1/media/inspect")return true;
    if((method=="POST"||method=="PUT")&&path.starts_with("/api/v1/animations"))return true;
    if(method=="POST"&&path=="/api/v1/media/import")return true;
    return (method=="GET"||method=="HEAD")&&(path=="/api/v1/sources/ndi"||path=="/api/v1/sources/syphon"||path=="/api/cameras"||path=="/api/media/catalog"||path=="/api/v1/media/catalog");
}
struct RequestWorkers {
    asio::thread_pool pool{2};
    std::shared_ptr<std::atomic<unsigned>> pending=std::make_shared<std::atomic<unsigned>>(0);
    static constexpr unsigned limit=8;
};
std::string methods(const std::string& path){
    if(path=="/api/v1/fixture-output/discover")return "POST";
    if(mediaUploadRoute(path))return "POST";
    if(mediaAssetRoute(path))return "GET, HEAD";
    if(path=="/api/videos"||path=="/api/images"||path=="/api/removable"||path=="/api/v1/media/drives"||(path.starts_with("/api/removable/")&&path.ends_with("/browse")))return "GET, HEAD";
    if(path=="/api/v1/ndi/clients"||path=="/api/v1/stats"||path=="/api/v1/network")return "GET, HEAD";
    if(path=="/api/v1/ndi/clients/discover"|| (path.starts_with("/api/v1/ndi/clients/")&&path.ends_with("/restart")))return "POST";
    if(path.starts_with("/api/v1/ndi/clients/")&&path.find("/inputs/")!=std::string::npos)return "PUT";
    if(path=="/ws/state"||path=="/ws/leds")return "GET, HEAD";
    if(path=="/api/v1/mappings/reset")return "POST";
    if(path=="/api/v1/text/fonts"||path=="/api/text/fonts")return "GET, HEAD";
    if(path=="/api/v1"||path=="/api/v1/"||path=="/api/v1/capabilities"||path=="/api/v1/docs"||path.starts_with("/api/v1/sdk/")||path=="/api/videos/subtitles"||path=="/api/v1/media/subtitles"||path=="/api/v1/media/subtitles/status")return "GET, HEAD";
    if(path=="/api/v1/media/preprocess")return "GET, HEAD, POST";
    if(path=="/api/v1/media/preprocess/cancel"||path=="/api/v1/media/subtitles/prepare")return "POST";
    if(path=="/api/calibration/debug")return "POST";
    if(path.starts_with("/api/calibration/debug/"))return path.find('/',23)==std::string::npos?"POST":"GET, HEAD";
    if(path=="/api/calibration/projector"||path=="/api/calibrations")return "GET, HEAD, POST";
    if(path=="/api/calibration/camera/start"||path=="/api/calibrations/load")return "POST";
    if(path=="/api/calibration/cameras"||path=="/api/calibration/camera/frame"||path=="/api/calibrations/revisions")return "GET, HEAD";
    if(path=="/api/v1/room")return "GET, HEAD, PUT";
    if(path=="/api/v1/room/preview")return "GET, HEAD";
    if(path=="/api/v1/room/history"||path=="/api/v1/room/map")return "POST";
    if(path=="/api/v1/link")return "GET, HEAD, POST, PATCH";
    if(path=="/api/v1/animations")return "GET, HEAD, POST";
    if(path.starts_with("/api/v1/animations/"))return path.ends_with("/wasm")?"GET, HEAD":"GET, HEAD, PUT";
    if(path=="/api/v1/flash"||path=="/api/v1/mapping-layouts/import")return "POST";
    if(path=="/api/v1/fixture-output")return "GET, HEAD, POST, PUT, PATCH";
    if(path.starts_with("/vector/modules/"))return "GET, HEAD";
    if(path=="/api/v1/media/inspect")return "GET, HEAD, POST";
    if(path=="/api/v1/display-assignments")return "GET, HEAD, PUT";
    if(path=="/api/v1/displays"||path=="/api/mapping/displays")return "GET, HEAD";
    if(path=="/health"||path=="/api/v1/state"||path=="/api/v1/effects"||path.starts_with("/api/v1/effects/")||path=="/api/v1/events"||path=="/ws/ui"||path=="/api/cameras"||path=="/api/media/catalog"||path=="/api/v1/media/catalog"||path.starts_with("/api/v1/sources/"))return "GET, HEAD";
    if(path=="/api/v1/grid")return "GET, HEAD, POST";
    if(path=="/api/v1/outputs")return "PUT";
    if(path.starts_with("/api/v1/outputs/"))return "POST";
    if(path=="/api/v1/command"||path=="/api/v1/media/import"||path=="/api/v1/media/status")return "POST";
    if(path=="/api/v1/stream"||path=="/api/v1/mix"||path=="/api/v1/clock"||path=="/api/v1/dmx")return "GET, HEAD, POST, PATCH";
    if(path=="/api/v1/midi")return "GET, HEAD, POST";
    if(path=="/api/v1/leds"||path=="/api/v1/ndi/projectors")return "GET, HEAD, PUT";
    if(path.starts_with("/api/v1/leds/"))return "PATCH";
    if(path=="/api/v1/mapping-layouts")return "GET, HEAD, POST";
    if(path.starts_with("/api/v1/mapping-layouts/"))return "GET, HEAD, PUT, PATCH, DELETE";
    if(path.starts_with("/api/v1/mappings/")){
        if(path.find('/',17)==std::string::npos)return "GET, HEAD";
        if(path.ends_with("/collections"))return "GET, HEAD, POST";
        if(path.find("/collections/")!=std::string::npos)return "PATCH, DELETE";
        if(path.ends_with("/commit"))return "POST";
        if(path.ends_with("/preview"))return "POST, DELETE";
        if(path.ends_with("/traces"))return "GET, HEAD, POST";
        if(path.find("/traces/")!=std::string::npos)return "GET, HEAD, PATCH, DELETE";
        if(path.ends_with("/selection"))return "GET, HEAD, PUT";
        if(path.ends_with("/groups"))return "GET, HEAD, POST";
        if(path.find("/groups/")!=std::string::npos)return "PATCH, DELETE";
        if(path.ends_with("/rects"))return "POST, PATCH, DELETE";
        if(path.find("/rects/")!=std::string::npos)return "PATCH, DELETE";
        if(path.ends_with("/output"))return "PATCH";
        if(path.ends_with("/batch")||path.ends_with("/load-layout")||path.ends_with("/move-surfaces")||path.ends_with("/transform-surfaces")||path.ends_with("/copy-object")||path.ends_with("/copy-surfaces")||path.ends_with("/undo")||path.ends_with("/redo"))return "POST";
    }
    return {};
}
bool allows(const std::string& allowed,const std::string& method){return (", "+allowed+", ").find(", "+method+", ")!=std::string::npos;}
Reply dispatch(Model& model,const std::string& method,const std::string& path,const Json& body){
    try{
        if(method=="POST"&&path=="/api/v1/command"){const auto command=translateUiCommand(body);return model.request(command.method,command.path,command.body);}
        return model.request(method,path,body);
    }catch(const ApiError& error){return {error.status,{{"error",error.what()}}};}
    catch(const Json::exception&){return {400,{{"error","Invalid command payload"}}};}
    catch(const std::exception&){return {500,{{"error","Request failed"}}};}
}
class Events:public std::enable_shared_from_this<Events>{
    websocket::stream<beast::tcp_stream> socket_;asio::steady_timer timer_,deadline_;Model& model_;bool ui_,stopped_=false;
    std::deque<std::string> outgoing_;beast::flat_buffer incoming_;
public:
    Events(beast::tcp_stream stream,Model& model,bool ui):socket_(std::move(stream)),timer_(socket_.get_executor()),deadline_(socket_.get_executor()),model_(model),ui_(ui){}
    void run(http::request<http::string_body> request){
        // HTTP deadlines must not remain active once WebSocket timeout handling
        // takes over. Beast maintains one read and one write concurrently.
        beast::get_lowest_layer(socket_).expires_never();
        auto timeout=websocket::stream_base::timeout::suggested(beast::role_type::server);timeout.idle_timeout=std::chrono::seconds(40);timeout.keep_alive_pings=true;
        socket_.set_option(timeout);socket_.read_message_max(1024*1024);
        socket_.async_accept(request,[self=shared_from_this()](beast::error_code e){if(e)return;self->read();self->snapshot(true);self->tick();});
    }
    void stop(){if(stopped_)return;stopped_=true;timer_.cancel();deadline_.cancel();beast::error_code ignored;beast::get_lowest_layer(socket_).socket().close(ignored);}
    void enqueue(Json value){if(stopped_)return;if(outgoing_.size()>=16){stop();return;}bool idle=outgoing_.empty();outgoing_.push_back(value.dump());if(idle)write();}
    void snapshot(bool first=false){
        try{
            auto snapshot=model_.snapshot();if(ui_){
                Json state=snapshot.value("state",Json::object());state["type"]=first?"hello":"state";
                if(first){auto catalog=model_.request("GET","/api/v1/effects");state["library"]=Json::array();if(catalog.status==200)for(const auto& effect:catalog.body.value("effects",Json::array()))state["library"].push_back({{"name",effect["name"]},{"label",effect["label"]},{"desc",effect.value("description",std::string{})},{"params",effect.value("parameters",Json::array())},{"adjustment",effect.value("adjustment",false)},{"live_source",effect.value("liveSource",false)},{"client_vector",effect.value("vector",false)},{"thumb",""}});state["nativeDevelopment"]=snapshot.value("nativeDevelopment",Json::object());}
                // Native extensions carry full status while preserving the
                // original UI's top-level state fields. Frame URLs are omitted
                // until the frame transport is implemented.
                state["revision"]=snapshot["revision"];enqueue(std::move(state));
            }else enqueue(std::move(snapshot));
        }catch(const std::exception&){enqueue({{"type","error"},{"error","Cannot read application state"}});}
    }
    void tick(){timer_.expires_after(std::chrono::milliseconds(250));timer_.async_wait([self=shared_from_this()](beast::error_code error){if(error||self->stopped_)return;if(self->outgoing_.empty())self->snapshot();self->tick();});}
    void read(){socket_.async_read(incoming_,[self=shared_from_this()](beast::error_code e,size_t){
        if(e){self->stop();return;}
        if(self->ui_&&self->socket_.got_text()){
            try{const auto message=Json::parse(beast::buffers_to_string(self->incoming_.data()));const auto reply=dispatch(self->model_,"POST","/api/v1/command",message);
                if(reply.status>=400)self->enqueue({{"type","error"},{"error",reply.body.value("error",std::string("Command failed"))},{"status",reply.status}});
                else self->snapshot();
            }catch(const Json::exception&){self->enqueue({{"type","error"},{"error","Invalid JSON"},{"status",400}});}
        }
        self->incoming_.consume(self->incoming_.size());if(!self->stopped_)self->read();
    });}
    void write(){
        if(stopped_||outgoing_.empty())return;socket_.text(true);
        deadline_.expires_after(std::chrono::seconds(1));deadline_.async_wait([self=shared_from_this()](beast::error_code e){if(!e)self->stop();});
        socket_.async_write(asio::buffer(outgoing_.front()),[self=shared_from_this()](beast::error_code e,size_t){self->deadline_.cancel();if(e){self->stop();return;}self->outgoing_.pop_front();self->write();});
    }
};
class FrameSocket:public std::enable_shared_from_this<FrameSocket>{
    websocket::stream<beast::tcp_stream> socket_;asio::steady_timer timer_,deadline_;
    FrameTransport& frames_;FrameTransport::Client client_;beast::flat_buffer incoming_;
    std::optional<EncodedFrame> outgoing_;bool stopped_=false;
public:
    FrameSocket(beast::tcp_stream stream,FrameTransport& frames,FrameTransport::Client client)
        :socket_(std::move(stream)),timer_(socket_.get_executor()),deadline_(socket_.get_executor()),frames_(frames),client_(client){}
    ~FrameSocket(){frames_.unsubscribe(client_);}
    void run(http::request<http::string_body> request){
        beast::get_lowest_layer(socket_).expires_never();
        auto timeout=websocket::stream_base::timeout::suggested(beast::role_type::server);
        timeout.idle_timeout=std::chrono::seconds(40);timeout.keep_alive_pings=true;socket_.set_option(timeout);
        websocket::permessage_deflate compression;compression.server_enable=false;compression.client_enable=false;socket_.set_option(compression);
        socket_.read_message_max(1024*1024);
        socket_.async_accept(request,[self=shared_from_this()](beast::error_code error){if(error){self->stop();return;}self->read();self->tick();});
    }
    void stop(){if(stopped_)return;stopped_=true;frames_.unsubscribe(client_);timer_.cancel();deadline_.cancel();beast::error_code ignored;beast::get_lowest_layer(socket_).socket().close(ignored);}
    void read(){socket_.async_read(incoming_,[self=shared_from_this()](beast::error_code error,size_t){if(error){self->stop();return;}self->incoming_.consume(self->incoming_.size());if(!self->stopped_)self->read();});}
    void tick(){
        if(stopped_)return;if(!frames_.connected(client_)){stop();return;}
        if(!outgoing_){outgoing_=frames_.take(client_);if(outgoing_)write();}
        timer_.expires_after(std::chrono::milliseconds(8));timer_.async_wait([self=shared_from_this()](beast::error_code error){if(!error)self->tick();});
    }
    void write(){
        if(stopped_||!outgoing_)return;socket_.binary(true);
        deadline_.expires_after(std::chrono::seconds(1));deadline_.async_wait([self=shared_from_this()](beast::error_code error){if(!error)self->stop();});
        socket_.async_write(asio::buffer(*outgoing_->bytes),[self=shared_from_this()](beast::error_code error,size_t){self->deadline_.cancel();if(error){self->stop();return;}self->outgoing_.reset();});
    }
};
class MappingSocket;
struct MappingHub {std::vector<std::weak_ptr<MappingSocket>> clients;uint64_t nextOwner=0;};
class MappingSocket:public std::enable_shared_from_this<MappingSocket>{
    websocket::stream<beast::tcp_stream> socket_;asio::steady_timer timer_,deadline_;Model& model_;std::shared_ptr<MappingHub> hub_;
    std::string mid_,owner_,last_;bool render_=false,stopped_=false,cleaned_=false;
    struct Packet{std::shared_ptr<const std::string> text;std::string key;};std::deque<Packet> outgoing_;beast::flat_buffer incoming_;
    Json snapshot(){return model_.snapshot().at("mappings").at(mid_);}
    void broadcast(const Json& value,const std::string& key,bool excludeSelf=false){auto text=std::make_shared<const std::string>(value.dump());for(auto it=hub_->clients.begin();it!=hub_->clients.end();){auto peer=it->lock();if(!peer){it=hub_->clients.erase(it);continue;}++it;if(peer->mid_==mid_&&(!excludeSelf||peer.get()!=this))peer->enqueue(text,key);}}
    void cleanup(){if(cleaned_)return;cleaned_=true;model_.request("DELETE","/api/v1/mappings/"+mid_+"/preview",{{"_owner",owner_}});model_.request("PUT","/api/v1/mappings/"+mid_+"/selection",{{"rectIds",Json::array()},{"_releaseOwner",owner_}});}
public:
    MappingSocket(beast::tcp_stream stream,Model& model,std::shared_ptr<MappingHub> hub,std::string mid,bool render):socket_(std::move(stream)),timer_(socket_.get_executor()),deadline_(socket_.get_executor()),model_(model),hub_(std::move(hub)),mid_(std::move(mid)),owner_("socket-"+std::to_string(++hub_->nextOwner)),render_(render){}
    ~MappingSocket(){cleanup();}
    void run(http::request<http::string_body> request){beast::get_lowest_layer(socket_).expires_never();auto timeout=websocket::stream_base::timeout::suggested(beast::role_type::server);timeout.idle_timeout=std::chrono::seconds(40);timeout.keep_alive_pings=true;socket_.set_option(timeout);socket_.read_message_max(32u*1024*1024+65536);hub_->clients.push_back(shared_from_this());socket_.async_accept(request,[self=shared_from_this()](beast::error_code error){if(error){self->stop();return;}self->poll();self->read();self->tick();});}
    void stop(){if(stopped_)return;stopped_=true;cleanup();timer_.cancel();deadline_.cancel();beast::error_code ignored;beast::get_lowest_layer(socket_).socket().close(ignored);}
    void enqueue(std::shared_ptr<const std::string> text,const std::string& key){if(stopped_)return;if(text->size()>32u*1024*1024){stop();return;}
        if(key=="state"||key=="preview")for(size_t i=1;i<outgoing_.size();++i)if(outgoing_[i].key==key){outgoing_[i].text=std::move(text);return;}
        size_t bytes=text->size();for(const auto& packet:outgoing_)bytes+=packet.text->size();if(outgoing_.size()>=16||bytes>64u*1024*1024){stop();return;}const bool idle=outgoing_.empty();outgoing_.push_back({std::move(text),key});if(idle)write();
    }
    void poll(){try{auto value=snapshot();auto text=value.dump();if(text!=last_){last_=text;enqueue(std::make_shared<const std::string>(std::move(text)),"state");}}catch(...){stop();}}
    void tick(){if(stopped_)return;timer_.expires_after(std::chrono::milliseconds(100));timer_.async_wait([self=shared_from_this()](beast::error_code error){if(!error){self->poll();self->tick();}});}
    void read(){socket_.async_read(incoming_,[self=shared_from_this()](beast::error_code error,size_t){if(error){self->stop();return;}if(self->socket_.got_text())try{
        auto message=Json::parse(beast::buffers_to_string(self->incoming_.data()));if(message.is_object()){
            const auto type=message.value("type",std::string{});message["_owner"]=self->owner_;
            if(type=="mapping_selection"&&!self->render_){auto reply=self->model_.request("PUT","/api/v1/mappings/"+self->mid_+"/selection",message);if(reply.status<400)self->broadcast(self->snapshot(),"state");}
            else if(type=="mapping_preview"){auto reply=self->model_.request("POST","/api/v1/mappings/"+self->mid_+"/preview",message);if(reply.status<400)self->broadcast(reply.body,"preview",true);}
            else if(type=="mapping_commit"){
                auto reply=self->model_.request("POST","/api/v1/mappings/"+self->mid_+"/commit",message);auto value=self->snapshot();auto id=message.value("commitId",Json());auto commit=id.is_null()?std::string{}:id.is_string()?id.get<std::string>():id.dump();value["commitId"]=commit.substr(0,100);
                if(reply.status>=400){value["rejected"]=true;value["reason"]=reply.body.value("error",std::string("Invalid mapping"));self->enqueue(std::make_shared<const std::string>(value.dump()),"ack");}
                else {value["clientId"]=reply.body.value("clientId",Json(""));self->broadcast(value,"ack");}
            }
        }
    }catch(const std::exception&){}self->incoming_.consume(self->incoming_.size());if(!self->stopped_)self->read();});}
    void write(){if(stopped_||outgoing_.empty())return;socket_.text(true);deadline_.expires_after(std::chrono::seconds(1));deadline_.async_wait([self=shared_from_this()](beast::error_code error){if(!error)self->stop();});socket_.async_write(asio::buffer(*outgoing_.front().text),[self=shared_from_this()](beast::error_code error,size_t){self->deadline_.cancel();if(error){self->stop();return;}self->outgoing_.pop_front();self->write();});}
};
class LedSocket:public std::enable_shared_from_this<LedSocket>{
    websocket::stream<beast::tcp_stream> socket_;asio::steady_timer timer_,deadline_;FrameTransport& frames_;FrameTransport::Client client_;beast::flat_buffer incoming_;std::shared_ptr<const std::string> outgoing_;bool stopped_=false;
public:
    LedSocket(beast::tcp_stream stream,FrameTransport& frames,FrameTransport::Client client):socket_(std::move(stream)),timer_(socket_.get_executor()),deadline_(socket_.get_executor()),frames_(frames),client_(client){}
    ~LedSocket(){frames_.unsubscribeLeds(client_);}
    void run(http::request<http::string_body> request){beast::get_lowest_layer(socket_).expires_never();auto timeout=websocket::stream_base::timeout::suggested(beast::role_type::server);timeout.idle_timeout=std::chrono::seconds(40);timeout.keep_alive_pings=true;socket_.set_option(timeout);socket_.read_message_max(1024);socket_.async_accept(request,[self=shared_from_this()](beast::error_code error){if(error){self->stop();return;}self->read();self->tick();});}
    void stop(){if(stopped_)return;stopped_=true;frames_.unsubscribeLeds(client_);timer_.cancel();deadline_.cancel();beast::error_code ignored;beast::get_lowest_layer(socket_).socket().close(ignored);}
    void read(){socket_.async_read(incoming_,[self=shared_from_this()](beast::error_code error,size_t){if(error){self->stop();return;}self->incoming_.consume(self->incoming_.size());if(!self->stopped_)self->read();});}
    void tick(){if(stopped_)return;if(!outgoing_){outgoing_=frames_.takeLeds(client_);if(outgoing_)write();}timer_.expires_after(std::chrono::milliseconds(8));timer_.async_wait([self=shared_from_this()](beast::error_code error){if(!error)self->tick();});}
    void write(){socket_.text(true);deadline_.expires_after(std::chrono::seconds(1));deadline_.async_wait([self=shared_from_this()](beast::error_code error){if(!error)self->stop();});socket_.async_write(asio::buffer(*outgoing_),[self=shared_from_this()](beast::error_code error,size_t){self->deadline_.cancel();if(error){self->stop();return;}self->outgoing_.reset();});}
};
class Session:public std::enable_shared_from_this<Session>{
    beast::tcp_stream stream_;beast::flat_buffer buffer_;http::request_parser<http::string_body> parser_;http::response<http::string_body> response_;Model& model_;RequestWorkers& workers_;std::shared_ptr<MappingHub> mappingHub_;bool cors_=false,head_=false;std::string allow_;
public:
    Session(tcp::socket socket,Model& model,RequestWorkers& workers,std::shared_ptr<MappingHub> hub):stream_(std::move(socket)),model_(model),workers_(workers),mappingHub_(std::move(hub)){parser_.body_limit(mediaUploadBodyLimit);parser_.header_limit(16384);}
    void readError(beast::error_code e){if(e==http::error::end_of_stream||e==asio::error::operation_aborted)return;cors_=external(std::string(parser_.get().target()));int status=e==http::error::body_limit?413:e==http::error::header_limit?431:400;send({status,{{"error",status==413?"Request body exceeds route limit":status==431?"Request headers too large":"Malformed HTTP request"}}});}
    void run(){stream_.expires_after(std::chrono::seconds(10));http::async_read_header(stream_,buffer_,parser_,[self=shared_from_this()](beast::error_code error,size_t){
        if(error){self->readError(error);return;}
        try{auto target=parseTarget(std::string(self->parser_.get().target()));if(mediaUploadRoute(target.path)){
                self->cors_=external(target.path);self->head_=self->parser_.get().method()==http::verb::head;self->allow_="POST";
                if(self->parser_.get().method()!=http::verb::post){self->send({405,{{"error","Method not allowed"}}});return;}
                if(self->workers_.pending->fetch_add(1)>=RequestWorkers::limit){self->workers_.pending->fetch_sub(1);self->send({503,{{"error","Background request queue is busy"}}});return;}
                auto count=self->workers_.pending;
                try{serveMediaUpload(std::move(self->stream_),std::move(self->buffer_),std::move(self->parser_),self->model_.stateRoot()/"media",self->workers_.pool,[count]{count->fetch_sub(1);});}catch(...){count->fetch_sub(1);throw;}return;
            }
            size_t limit=4*1024*1024;if(target.path=="/api/calibration/debug")limit=16*1024*1024;else if(target.path.starts_with("/api/calibration/debug/"))limit=48*1024*1024;self->parser_.body_limit(limit);if(auto length=self->parser_.content_length();length&&*length>limit){self->readError(http::error::body_limit);return;}
            if(self->parser_.is_done()){self->reply();return;}http::async_read(self->stream_,self->buffer_,self->parser_,[self](beast::error_code e,size_t){if(e)self->readError(e);else self->reply();});
        }catch(const ApiError& error){self->send({error.status,{{"error",error.what()}}});}
    });}
    void reply(){
        auto request=parser_.release();cors_=external(std::string(request.target()));head_=request.method()==http::verb::head;
        try{
            const auto target=parseTarget(std::string(request.target()));cors_=external(target.path);const std::string method(request.method_string());
            if(method=="OPTIONS"&&cors_){send({204,Json()});return;}
            const auto frameRoute=frameStreamRoute(target.path,target.query,model_.frames().activeOutputs());
            const auto mappingRoute=mappingFrameRoute(target.path);
            allow_=(frameRoute||mappingRoute)?"GET, HEAD":methods(target.path);if(!allow_.empty()&&!allows(allow_,method)){send({405,{{"error","Method not allowed"}}});return;}
            if(mediaAssetRoute(target.path)){
                if(workers_.pending->fetch_add(1)>=RequestWorkers::limit){workers_.pending->fetch_sub(1);send({503,{{"error","Background request queue is busy"}}});return;}
                auto executor=stream_.get_executor();auto count=workers_.pending;
                try{asio::post(workers_.pool,[self=shared_from_this(),executor,count,target,request=std::move(request)]() mutable {
                    std::optional<MediaHttpAsset> asset;Reply error{404,{{"error","Media unavailable"}}};
                    try{asset=self->model_.mediaAsset(target.path,target.query);}catch(const ApiError& e){error={e.status,{{"error",e.what()}}};}catch(const std::exception&){error={500,{{"error","Media request failed"}}};}
                    asio::post(executor,[self,count,asset=std::move(asset),error=std::move(error),request=std::move(request)]() mutable {
                        if(!asset){count->fetch_sub(1);self->send(std::move(error));return;}
                        serveMediaAsset(std::move(self->stream_),std::move(request),std::move(*asset),self->workers_.pool,[count]{count->fetch_sub(1);});
                    });
                });}catch(...){count->fetch_sub(1);throw;}return;
            }
            if(target.path=="/ws/state"||target.path=="/ws/leds"){
                if(!websocket::is_upgrade(request)){send({426,{{"error","WebSocket upgrade required"}}});return;}
                if(target.path=="/ws/leds"){auto client=model_.frames().subscribeLeds();try{std::make_shared<LedSocket>(std::move(stream_),model_.frames(),client)->run(std::move(request));}catch(...){model_.frames().unsubscribeLeds(client);throw;}return;}
                std::erase_if(mappingHub_->clients,[](const auto& weak){return weak.expired();});if(mappingHub_->clients.size()>=32){send({503,{{"error","Mapping subscriber limit reached"}}});return;}
                auto mid=target.query.value("mapping",std::string("1"));if(mid!="1"&&mid!="2"&&mid!="3"&&mid!="4")mid="1";const bool render=target.query.value("role",std::string{})=="render";
                std::make_shared<MappingSocket>(std::move(stream_),model_,mappingHub_,mid,render)->run(std::move(request));return;
            }
            if(frameRoute){
                if(!websocket::is_upgrade(request)){send({426,{{"error","WebSocket upgrade required"}}});return;}
                auto client=model_.frames().subscribe(*frameRoute);try{std::make_shared<FrameSocket>(std::move(stream_),model_.frames(),client)->run(std::move(request));}catch(...){model_.frames().unsubscribe(client);throw;}return;
            }
            if(mappingRoute){
                const bool room=target.query.value("room",std::string{})=="1";
                const auto frame=model_.frames().mappingFrame(*mappingRoute,room);
                if(!frame){send({503,Json(),std::string("No native collection preview"),"text/plain; charset=utf-8"});return;}
                send({200,Json(),std::string(frame->bytes->begin(),frame->bytes->end()),frame->contentType});return;
            }
            if(websocket::is_upgrade(request)&&(target.path=="/api/v1/events"||target.path=="/ws/ui")){std::make_shared<Events>(std::move(stream_),model_,target.path=="/ws/ui")->run(std::move(request));return;}
            if(target.path=="/api/v1/events"||target.path=="/ws/ui"){send({426,{{"error","WebSocket upgrade required"}}});return;}
            if(request.body().size()>1024*1024&&!target.path.starts_with("/api/v1/animations")&&target.path!="/api/calibration/debug"&&!target.path.starts_with("/api/calibration/debug/")){send({413,{{"error","Request body exceeds 1 MiB"}}});return;}
            Json body=request.body().empty()?Json::object():Json::parse(request.body());
            if(method=="GET"||method=="HEAD"){
                if(!body.is_object())throw ApiError(400,"Expected an object");
                // Query strings remain strings, like aiohttp request.query.
                // JSON bodies do not override the URL's requested parameters.
                body.update(target.query);
            }
            if(backgroundRequest(method,target.path)){
                if(workers_.pending->fetch_add(1)>=RequestWorkers::limit){workers_.pending->fetch_sub(1);send({503,{{"error","Background request queue is busy"}}});return;}
                // No socket or HTTP response state is touched on a worker.
                // Holding self keeps the connection/executor alive until its
                // completion runs, or is destroyed during io_context shutdown.
                auto executor=stream_.get_executor();
                try{
                    asio::post(workers_.pool,[self=shared_from_this(),executor,method=head_?std::string("GET"):method,path=target.path,body=std::move(body)]() mutable {
                        struct Pending {std::atomic<unsigned>& count;~Pending(){count.fetch_sub(1);}} pending{*self->workers_.pending};
                        auto result=dispatch(self->model_,method,path,body);
                        asio::post(executor,[self,result=std::move(result)]() mutable {
                            self->stream_.expires_after(std::chrono::seconds(10));
                            self->send(std::move(result));
                        });
                    });
                }catch(...){workers_.pending->fetch_sub(1);throw;}
                return;
            }
            send(dispatch(model_,head_?"GET":method,target.path,body));
        }catch(const ApiError& error){send({error.status,{{"error",error.what()}}});}
        catch(const Json::exception&){send({400,{{"error","Invalid JSON"}}});}
        catch(const std::exception&){send({500,{{"error","Request failed"}}});}
    }
    void send(Reply reply){
        response_.version(11);response_.result(reply.status);response_.set(http::field::content_type,reply.contentType);response_.set(http::field::cache_control,"no-store");response_.keep_alive(false);
        if(cors_){response_.set(http::field::access_control_allow_origin,"*");response_.set(http::field::access_control_allow_methods,"GET, POST, PUT, PATCH, DELETE, OPTIONS");response_.set(http::field::access_control_allow_headers,"Content-Type");}
        for(const auto& [name,value]:reply.headers)response_.set(name,value);
        if(reply.status==405&&!allow_.empty())response_.set(http::field::allow,allow_);
        if(reply.status==426)response_.set(http::field::upgrade,"websocket");
        if(reply.status!=204){const auto payload=reply.rawBody?*reply.rawBody:reply.body.dump();if(!head_)response_.body()=payload;response_.content_length(payload.size());}
        http::async_write(stream_,response_,[self=shared_from_this()](beast::error_code,size_t){beast::error_code ignored;self->stream_.socket().shutdown(tcp::socket::shutdown_send,ignored);});
    }
};
}
struct ApiServer::Impl{
    // io is destroyed last: completion handlers retain Sessions containing
    // stream executors. Workers finish before either io or Model may disappear.
    asio::io_context io;RequestWorkers workers;tcp::acceptor acceptor;Model& model;std::thread thread;std::shared_ptr<MappingHub> mappingHub=std::make_shared<MappingHub>();
    Impl(Model& m,unsigned short port,const std::string& address):acceptor(io,tcp::endpoint(asio::ip::make_address(address),port)),model(m){model.setApiPort(acceptor.local_endpoint().port());model.setControlRuntime("api",apiAddresses(address,acceptor.local_endpoint().port()));accept();thread=std::thread([this]{io.run();});}
    void accept(){acceptor.async_accept([this](beast::error_code e,tcp::socket socket){if(!e)std::make_shared<Session>(std::move(socket),model,workers,mappingHub)->run();if(acceptor.is_open())accept();});}
    ~Impl(){
        // First prevent new submissions, including handlers already executing.
        io.stop();if(thread.joinable())thread.join();
        beast::error_code ignored;acceptor.close(ignored);
        // join drains the bounded queue; stop() here would discard submitted
        // requests. Completions may post to stopped io while it remains alive.
        workers.pool.join();
    }
};
ApiServer::ApiServer(Model& model,unsigned short port,const std::string& address):impl_(std::make_unique<Impl>(model,port,address)){}
ApiServer::~ApiServer()=default;
unsigned short ApiServer::port()const{return impl_->acceptor.local_endpoint().port();}
}

#include "remote_server.hpp"
#include "api_addresses.hpp"
#include "api_error.hpp"
#include "frame_transport.hpp"
#include "mapping_canvas.hpp"
#include "mapping_geometry.hpp"
#include "remote_page.hpp"
#include <algorithm>
#include <cmath>
#include <boost/asio.hpp>
#include <boost/beast.hpp>
#include <boost/beast/websocket.hpp>
#include <deque>
#include <random>
#include <thread>
namespace vj {
namespace asio=boost::asio;namespace beast=boost::beast;namespace http=beast::http;namespace websocket=beast::websocket;using tcp=asio::ip::tcp;
namespace {
std::string queryValue(std::string_view target,const std::string& key){
    auto at=target.find('?');if(at==std::string_view::npos)return {};auto query=target.substr(at+1);
    while(!query.empty()){auto end=query.find('&');auto pair=query.substr(0,end);if(pair.starts_with(key+"="))return std::string(pair.substr(key.size()+1));if(end==std::string_view::npos)break;query.remove_prefix(end+1);}return {};
}
bool sameKey(const std::string& a,const std::string& b){if(a.size()!=b.size()||a.empty())return false;unsigned char diff=0;for(size_t i=0;i<a.size();++i)diff|=a[i]^b[i];return !diff;}
bool has(const Json& values,const Json& value){return std::find(values.begin(),values.end(),value)!=values.end();}
CanvasRect rect(const Json& value){return {value.value("x",0.),value.value("y",0.),std::max(1.,value.value("w",1.)),std::max(1.,value.value("h",1.))};}
}
// One phone canvas. Pointer events run through the Mapper's own gesture engine;
// previews and commits use the same mapping routes as the AppKit Mapper.
class RemoteCanvas:public std::enable_shared_from_this<RemoteCanvas>{
    websocket::stream<beast::tcp_stream> socket_;beast::flat_buffer buffer_;asio::steady_timer timer_;std::deque<std::string> outgoing_;Model& model_;
    std::string owner_,mid_="1",addingPin_,positioningContent_,status_;Json mapping_,selected_=Json::array(),trace_=nullptr,activeCorner_=nullptr;MappingCanvasGesture gesture_=[]{MappingCanvasGesture g;g.curveHandles=false;return g;}();CanvasRect bounds_{0,0,1600,900},viewport_{0,0,1600,900};bool previewing_=false,closed_=false;
    MappingCanvasDoc doc(){return {mapping_,selected_,trace_,addingPin_,positioningContent_};}
    std::string path(const std::string& action={})const{return "/api/v1/mappings/"+mid_+(action.empty()?"":"/"+action);}
    void reload(){auto reply=model_.request("GET",path());if(reply.status<300)mapping_=reply.body;Json visible=Json::array();for(const auto& id:selected_)if(mapping_.contains("project"))for(const auto& r:mapping_["project"]["rects"])if(r["id"]==id&&mappingEditorVisible(mapping_,id))visible.push_back(id);selected_=visible;if(trace_.is_string()&&!mappingEditorVisible(mapping_,trace_,true))trace_=nullptr;}
    bool commit(const std::string& method,const std::string& action,Json body){
        auto current=model_.request("GET",path());body["revision"]=current.body.value("revision",Json());
        auto reply=model_.request(method,path(action),body);status_=reply.status<300?std::string{}:reply.body.value("error",std::string("Command failed"));return reply.status<300;
    }
    void clearPreview(){if(previewing_){model_.request("DELETE",path("preview"),{{"_owner",owner_}});previewing_=false;}}
    void bindActions(){
        auto weak=weak_from_this();auto with=[weak](auto fn){return [weak,fn](auto&&... args){if(auto self=weak.lock())fn(*self,args...);};};
        gesture_.actions={
            .selection=with([](RemoteCanvas& s,const Json& ids){s.model_.request("PUT",s.path("selection"),{{"rectIds",ids}});}),
            .traceSelection=with([](RemoteCanvas&,const Json&){}),
            .geometry=with([](RemoteCanvas& s,const Json& updates){try{auto operations=mappingGeometryOperations(s.mapping_,updates);if(!operations.empty())s.commit("POST","batch",{{"operations",operations}});}catch(const std::exception& e){s.status_=e.what();}}),
            .traceGeometry=with([](RemoteCanvas& s,const Json& id,const Json& points){s.commit("PATCH","traces/"+id.get<std::string>(),{{"points",points}});}),
            .surfaceProperty=with([](RemoteCanvas& s,const Json& id,const Json& patch){s.commit("PATCH","rects/"+id.get<std::string>(),patch);}),
            .collectionProperty=with([](RemoteCanvas& s,const Json& id,const Json& patch){s.commit("PATCH","collections/"+id.get<std::string>(),patch);}),
            .translation=with([](RemoteCanvas& s,const Json& ids,const Json& delta){s.commit("POST","move-surfaces",{{"rectIds",ids},{"offset",delta}});}),
            .curveEdgeSelection=with([](RemoteCanvas&,const std::string&){})};
    }
    void sendScene(){
        Json mappings=Json::array();const auto snapshot=model_.presentationSnapshotShared();for(auto it=(*snapshot)["mappings"].begin();it!=(*snapshot)["mappings"].end();++it)mappings.push_back({{"id",it.key()},{"name","Projector "+it.key()}});
        Json message={{"type","scene"},{"mappingId",mid_},{"mappings",mappings},{"selected",selected_},{"selectedTrace",trace_},{"status",status_},{"interacting",gesture_.dragging()||gesture_.marquee()}};
        if(activeCorner_.is_object()&&!has(selected_,activeCorner_["id"]))activeCorner_=nullptr;message["activeCorner"]=activeCorner_;
        if(mapping_.contains("project")){message.update({{"revision",mapping_.value("revision",Json())},{"layout",mapping_.value("layout",Json())},{"history",mapping_.value("history",Json::object())},{"output",mapping_["project"].value("output",Json::object())},{"scene",mappingCanvasScene(mapping_,selected_,trace_,bounds_,viewport_,gesture_.curveHandles)}});
            Json objects=Json::array();for(const auto& r:mapping_["project"]["rects"])if(mappingEditorVisible(mapping_,r["id"]))objects.push_back({{"id",r["id"]},{"name",r.value("name",std::string("Surface"))},{"kind","rect"}});for(const auto& t:mapping_["project"].value("traces",Json::array()))if(mappingEditorVisible(mapping_,t["id"],true))objects.push_back({{"id",t["id"]},{"name",t.value("name",std::string("Trace"))},{"kind","trace"}});message["objects"]=objects;}
        if(gesture_.marquee()){auto m=gesture_.marqueeRect();message["marquee"]={(m.x-bounds_.x)/bounds_.w,(m.y-bounds_.y)/bounds_.h,m.w/bounds_.w,m.h/bounds_.h};}
        round(message);queue(message.dump());
    }
    // Scene geometry only needs display precision; full doubles triple the payload.
    static void round(Json& value){if(value.is_number_float())value=std::round(value.get<double>()*1e5)/1e5;else if(value.is_structured())for(auto& item:value)round(item);}
    void queue(std::string text){if(closed_)return;outgoing_.push_back(std::move(text));if(outgoing_.size()>8)outgoing_.erase(outgoing_.begin()+1,outgoing_.end()-1);if(outgoing_.size()==1)write();}
    void write(){socket_.text(true);socket_.async_write(asio::buffer(outgoing_.front()),[self=shared_from_this()](beast::error_code error,size_t){if(error){self->close();return;}self->outgoing_.pop_front();if(!self->outgoing_.empty())self->write();});}
    void read(){socket_.async_read(buffer_,[self=shared_from_this()](beast::error_code error,size_t){if(error){self->close();return;}auto text=beast::buffers_to_string(self->buffer_.data());self->buffer_.consume(self->buffer_.size());try{self->handle(Json::parse(text));}catch(const std::exception& e){self->status_=e.what();self->sendScene();}self->read();});}
    void tick(){timer_.expires_after(std::chrono::milliseconds(250));timer_.async_wait([self=shared_from_this()](beast::error_code error){if(error||self->closed_)return;
        if(!self->gesture_.dragging()&&!self->gesture_.marquee()){auto revision=self->mapping_.value("revision",Json());auto visibility=self->mapping_.value("editorVisibility",Json());self->reload();if(self->mapping_.value("revision",Json())!=revision||self->mapping_.value("editorVisibility",Json())!=visibility)self->sendScene();}self->tick();});}
    void close(){if(closed_)return;closed_=true;timer_.cancel();clearPreview();beast::error_code ignored;beast::get_lowest_layer(socket_).socket().close(ignored);}
    void handle(const Json& m){
        const auto type=m.value("type",std::string{});const CanvasPoint at{m.value("x",0.),m.value("y",0.)};const bool shift=m.value("shift",false);
        if(type=="view"){gesture_.hitScale=std::clamp(m.value("hitScale",1.),1.,4.);gesture_.curveHandles=m.value("curves",false);bounds_=rect(m.value("bounds",Json::object()));viewport_=rect(m.value("viewport",Json::object()));auto mid=m.value("mapping",mid_);
            if(mid!=mid_&&model_.request("GET","/api/v1/mappings/"+mid).status<300){gesture_.cancel(doc());clearPreview();mid_=mid;selected_=Json::array();trace_=nullptr;}if(!gesture_.dragging())reload();sendScene();return;}
        if(type=="down"){if(!gesture_.dragging()&&!gesture_.marquee())reload();status_.clear();bindActions();if(m.contains("bounds"))bounds_=rect(m["bounds"]);
            const auto tool=m.value("tool",std::string("move"));
            if(tool!="move"&&!selected_.empty())gesture_.transformDown(doc(),at,bounds_,tool=="scale",tool=="rotate");
            else{gesture_.down(doc(),at,bounds_,viewport_,m.value("clickCount",1),{shift,m.value("command",false),shift||m.value("command",false)||m.value("additive",false)});
                activeCorner_=gesture_.corner()>=0&&gesture_.dragging()&&gesture_.clickID().is_string()?Json{{"id",gesture_.clickID()},{"index",gesture_.corner()}}:Json();}
            if(!gesture_.dragging()&&!gesture_.marquee())reload();sendScene();return;}
        if(type=="move"){gesture_.drag(doc(),at,bounds_,shift);if(auto preview=gesture_.preview(doc())){auto reply=model_.request("POST",path("preview"),{{"_owner",owner_},{"clientId",owner_},{"baseRevision",preview->second},{"project",preview->first}});previewing_=reply.status<300||previewing_;status_=reply.status<300?std::string{}:"Preview: "+reply.body.value("error",std::string("failed"));}sendScene();return;}
        if(type=="up"){gesture_.up(doc(),at,bounds_,shift);clearPreview();reload();sendScene();return;}
        if(type=="cancel"){gesture_.cancel(doc());clearPreview();reload();sendScene();return;}
        if(type=="clearCorner"){activeCorner_=nullptr;sendScene();return;}
        if(type=="select"){activeCorner_=nullptr;selected_=m.value("ids",Json::array());trace_=nullptr;model_.request("PUT",path("selection"),{{"rectIds",selected_}});sendScene();return;}
        if(type=="selectTrace"){trace_=m.value("id",Json());selected_=Json::array();sendScene();return;}
        if(type=="selectAll"){selected_=Json::array();trace_=nullptr;for(const auto& r:mapping_["project"]["rects"])if(mappingEditorVisible(mapping_,r["id"]))selected_.push_back(r["id"]);model_.request("PUT",path("selection"),{{"rectIds",selected_}});sendScene();return;}
        // Arrow keys: 1 px (10 with shift) of a 1920×1080 output, as in the Mapper.
        if(type=="nudge"){double step=shift?10.:1.,dx=m.value("dx",0)*step/1920.,dy=m.value("dy",0)*step/1080.;
            if(activeCorner_.is_object()&&has(selected_,activeCorner_["id"])){bindActions();if(!gesture_.nudgeCorner(doc(),activeCorner_["id"],activeCorner_["index"].get<size_t>(),dx,dy))activeCorner_=nullptr;}
            else if(trace_.is_string()){for(const auto& t:mapping_["project"].value("traces",Json::array()))if(t["id"]==trace_){auto points=t["points"];for(auto& p:points)p=Json::array({std::clamp(p[0].get<double>()+dx,0.,1.),std::clamp(p[1].get<double>()+dy,0.,1.)});commit("PATCH","traces/"+t["id"].get<std::string>(),{{"points",points}});}}
            else if(!selected_.empty())commit("POST","move-surfaces",{{"rectIds",selected_},{"offset",{dx,dy}}});reload();sendScene();return;}
        if(type=="undo"||type=="redo"){commit("POST",type,Json::object());reload();sendScene();return;}
        if(type=="grid"){commit("PATCH","output",{{"boundsGrid",!mapping_["project"]["output"].value("boundsGrid",false)}});reload();sendScene();return;}
        status_="Unknown remote command";sendScene();
    }
public:
    RemoteCanvas(tcp::socket socket,Model& model):socket_(std::move(socket)),timer_(socket_.get_executor()),model_(model){std::random_device random;owner_="remote-"+std::to_string(random())+std::to_string(random());}
    ~RemoteCanvas(){clearPreview();}
    void run(http::request<http::string_body> request){beast::get_lowest_layer(socket_).expires_never();auto timeout=websocket::stream_base::timeout::suggested(beast::role_type::server);timeout.idle_timeout=std::chrono::seconds(40);timeout.keep_alive_pings=true;socket_.set_option(timeout);socket_.read_message_max(64*1024);
        socket_.async_accept(request,[self=shared_from_this()](beast::error_code error){if(error)return;self->reload();self->read();self->tick();});}
};
class RemoteSession:public std::enable_shared_from_this<RemoteSession>{
    beast::tcp_stream stream_;beast::flat_buffer buffer_;http::request_parser<http::string_body> parser_;http::response<http::string_body> response_;Model& model_;std::string key_;
public:
    RemoteSession(tcp::socket socket,Model& model,std::string key):stream_(std::move(socket)),model_(model),key_(std::move(key)){parser_.body_limit(64*1024);parser_.header_limit(8192);}
    void run(){stream_.expires_after(std::chrono::seconds(10));http::async_read(stream_,buffer_,parser_,[self=shared_from_this()](beast::error_code error,size_t){if(error){if(error!=http::error::end_of_stream)self->send({400,{{"error","Malformed HTTP request"}}});return;}self->reply();});}
    void reply(){
        auto request=parser_.release();const std::string target(request.target()),method(request.method_string());const auto path=target.substr(0,target.find('?'));
        if(!sameKey(queryValue(target,"k"),key_)){send(path=="/"?Reply{403,Json(),std::string("VJ remote key required"),"text/plain; charset=utf-8"}:Reply{403,{{"error","Remote key required"}}});return;}
        try{
            if(path=="/"&&method=="GET"){send({200,Json(),std::string(remotePage),"text/html; charset=utf-8"});return;}
            if(path=="/remote/ws"){if(!websocket::is_upgrade(request)){send({426,{{"error","WebSocket upgrade required"}}});return;}std::make_shared<RemoteCanvas>(stream_.release_socket(),model_)->run(std::move(request));return;}
            if(path=="/remote/frame"&&method=="GET"){auto frame=model_.frames().mappingFrame(queryValue(target,"mapping"),false);if(!frame){send({503,Json(),std::string("No mapping frame"),"text/plain; charset=utf-8"});return;}send({200,Json(),std::string(frame->bytes->begin(),frame->bytes->end()),frame->contentType});return;}
            send({404,{{"error","Not available on remote"}}});
        }catch(const ApiError& e){send({e.status,{{"error",e.what()}}});}
        catch(const std::exception&){send({500,{{"error","Request failed"}}});}
    }
    void send(Reply reply){
        response_.version(11);response_.result(reply.status);response_.set(http::field::content_type,reply.contentType);response_.set(http::field::cache_control,"no-store");response_.keep_alive(false);
        const auto payload=reply.rawBody?*reply.rawBody:reply.body.dump();response_.body()=payload;response_.content_length(payload.size());
        http::async_write(stream_,response_,[self=shared_from_this()](beast::error_code,size_t){beast::error_code ignored;self->stream_.socket().shutdown(tcp::socket::shutdown_send,ignored);});
    }
};
struct RemoteServer::Impl{
    asio::io_context io;tcp::acceptor acceptor;Model& model;std::string key;std::thread thread;
    Impl(Model& m,unsigned short port,std::string k,const std::string& address):acceptor(io,tcp::endpoint(asio::ip::make_address(address),port)),model(m),key(std::move(k)){
        if(key.size()<8)throw std::runtime_error("Remote key must be at least 8 characters");
        auto runtime=apiAddresses(address,acceptor.local_endpoint().port());for(auto& url:runtime["urls"])url=url.get<std::string>()+"/?k="+key;model.setControlRuntime("remote",runtime);
        accept();thread=std::thread([this]{io.run();});
    }
    void accept(){acceptor.async_accept([this](beast::error_code e,tcp::socket socket){if(!e)std::make_shared<RemoteSession>(std::move(socket),model,key)->run();if(acceptor.is_open())accept();});}
    ~Impl(){io.stop();if(thread.joinable())thread.join();beast::error_code ignored;acceptor.close(ignored);}
};
RemoteServer::RemoteServer(Model& model,unsigned short port,std::string key,const std::string& address):impl_(std::make_unique<Impl>(model,port,std::move(key),address)){}
RemoteServer::~RemoteServer()=default;
unsigned short RemoteServer::port()const{return impl_->acceptor.local_endpoint().port();}
}

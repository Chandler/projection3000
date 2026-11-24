#include "api_server.hpp"
#include "remote_server.hpp"
#include <boost/asio.hpp>
#include <boost/beast.hpp>
#include <boost/beast/websocket.hpp>
#include <cassert>
#include <filesystem>
#include <iostream>
#include <unistd.h>
namespace asio=boost::asio;namespace beast=boost::beast;namespace http=beast::http;namespace ws=beast::websocket;using tcp=asio::ip::tcp;
http::response<http::string_body> request(unsigned short port,http::verb method,const std::string& target,const std::string& body="",const std::map<http::field,std::string>& headers={}){
    asio::io_context io;beast::tcp_stream stream(io);stream.connect(tcp::endpoint(asio::ip::make_address("127.0.0.1"),port));
    http::request<http::string_body> message(method,target,11);message.set(http::field::host,"localhost");message.set(http::field::origin,"http://localhost:12345");for(const auto& [name,value]:headers)message.set(name,value);message.body()=body;message.prepare_payload();http::write(stream,message);
    beast::flat_buffer buffer;http::response<http::string_body> reply;http::read(stream,buffer,reply);return reply;
}
int main(){
    auto directory=std::filesystem::temp_directory_path()/("vj-native-transport-"+std::to_string(getpid()));std::filesystem::remove_all(directory);
    {
        vj::Model model(directory);vj::ApiServer server(model,0);auto port=server.port();
        {
            vj::RemoteServer remote(model,0,"testkey123","127.0.0.1");auto rp=remote.port();
            assert(request(rp,http::verb::get,"/").result_int()==403);assert(request(rp,http::verb::get,"/?k=wrongkey12").result_int()==403);
            auto page=request(rp,http::verb::get,"/?k=testkey123");assert(page.result_int()==200&&page.body().find("VJ Mapping")!=std::string::npos);
            assert(request(rp,http::verb::get,"/api/v1/grid?k=testkey123").result_int()==404);
            assert(request(rp,http::verb::get,"/remote/ws?k=testkey123").result_int()==426);
            assert(model.snapshot()["state"]["remote"]["urls"][0]=="http://127.0.0.1:"+std::to_string(rp)+"/?k=testkey123");
            // The canvas socket runs Mapper gestures: a tap selects, a body drag commits one move.
            asio::io_context io;ws::stream<beast::tcp_stream> socket(io);beast::get_lowest_layer(socket).connect(tcp::endpoint(asio::ip::make_address("127.0.0.1"),rp));socket.handshake("localhost","/remote/ws?k=testkey123");
            auto next=[&]{beast::flat_buffer buffer;socket.read(buffer);return vj::Json::parse(beast::buffers_to_string(buffer.data()));};
            auto send=[&](const vj::Json& m){socket.write(asio::buffer(m.dump()));for(;;){auto scene=next();if(scene["type"]=="scene")return scene;}};
            auto scene=send({{"type","view"},{"mapping","1"},{"bounds",{{"x",0},{"y",0},{"w",1600},{"h",900}}},{"viewport",{{"x",0},{"y",0},{"w",1600},{"h",900}}}});
            auto rect=scene["scene"]["rects"][0];auto corners=model.request("GET","/api/v1/mappings/1").body["project"]["rects"][0]["corners"];double cx=0,cy=0;for(const auto& p:corners){cx+=p[0].get<double>()*400;cy+=p[1].get<double>()*225;}
            auto revision=scene["revision"];send({{"type","down"},{"x",cx},{"y",cy}});scene=send({{"type","up"},{"x",cx},{"y",cy}});assert(scene["selected"]==vj::Json::array({rect["id"]}));
            send({{"type","down"},{"x",cx},{"y",cy}});send({{"type","move"},{"x",cx+16},{"y",cy}});scene=send({{"type","up"},{"x",cx+16},{"y",cy}});
            assert(scene["revision"]!=revision&&std::abs(model.request("GET","/api/v1/mappings/1").body["project"]["rects"][0]["corners"][0][0].get<double>()-corners[0][0].get<double>()-.01)<1e-9);
            beast::error_code ignored;socket.close(ws::close_code::normal,ignored);
        }
        auto grid=request(port,http::verb::get,"/api/v1/%67rid?filter=a%2Bb&extra_ips=192.0.2.1%2C+192.0.2.2");
        assert(grid.result_int()==200);assert(grid[http::field::access_control_allow_origin]=="*");assert(vj::Json::parse(grid.body()).contains("grid"));
        auto options=request(port,http::verb::options,"/api/v1/grid");assert(options.result_int()==204&&options.body().empty());assert(options[http::field::access_control_allow_methods].find("PATCH")!=beast::string_view::npos);
        assert(request(port,http::verb::get,"/api/v1/grid?bad=%xy").result_int()==400);
        assert(request(port,http::verb::delete_,"/api/v1/grid").result_int()==405);
        assert(request(port,http::verb::get,"/api/v1/events").result_int()==426);
        // A completion callback must release its media worker slot exactly once.
        // Exercise the real handoff with a body larger than the JSON route limit.
        const std::string media(2*1024*1024,'v');
        const auto multipart="--native-test\r\nContent-Disposition: form-data; name=\"file\"; filename=\"uploaded.mp4\"\r\n\r\n"+media+"\r\n--native-test--\r\n";
        auto uploaded=request(port,http::verb::post,"/api/files/upload",multipart,{{http::field::content_type,"multipart/form-data; boundary=native-test"}});
        assert(uploaded.result_int()==200&&vj::Json::parse(uploaded.body())["size"]==media.size());
        for(int i=0;i<3;++i){
            auto bytes=request(port,http::verb::get,"/native-media/uploaded.mp4","",{{http::field::range,"bytes=65530-65550"}});
            assert(bytes.result_int()==206&&bytes.body()==media.substr(65530,21));
            assert(request(port,http::verb::get,"/api/v1/media/catalog").result_int()==200);
        }
        auto before=model.snapshot();
        assert(request(port,http::verb::post,"/api/v1/command",R"({"type":"no_such_command"})").result_int()==501);
        assert(model.snapshot()["revision"]==before["revision"]);assert(model.snapshot()["state"]["grid"]==before["state"]["grid"]);
        {
            asio::io_context io;ws::stream<beast::tcp_stream> socket(io);beast::get_lowest_layer(socket).connect(tcp::endpoint(asio::ip::make_address("127.0.0.1"),port));socket.handshake("localhost","/ws/ui");beast::flat_buffer buffer;socket.read(buffer);auto hello=vj::Json::parse(beast::buffers_to_string(buffer.data()));buffer.consume(buffer.size());assert(hello["type"]=="hello"&&hello.contains("grid"));assert(hello["library"][0].contains("params"));
            const auto count=hello["grid"]["columns"].size();socket.write(asio::buffer(std::string(R"({"type":"grid","action":"add_column","name":"Socket column"})")));
            bool changed=false;for(int i=0;i<8&&!changed;i++){socket.read(buffer);auto state=vj::Json::parse(beast::buffers_to_string(buffer.data()));buffer.consume(buffer.size());changed=state.contains("grid")&&state["grid"]["columns"].size()==count+1;}assert(changed);
            socket.write(asio::buffer(std::string("{bad JSON")));bool error=false;for(int i=0;i<8&&!error;i++){socket.read(buffer);auto state=vj::Json::parse(beast::buffers_to_string(buffer.data()));buffer.consume(buffer.size());error=state.value("type",std::string{})=="error"&&state.value("status",0)==400;}assert(error);
            socket.close(ws::close_code::normal);
        }
        {
            asio::io_context io;ws::stream<beast::tcp_stream> socket(io);beast::get_lowest_layer(socket).connect(tcp::endpoint(asio::ip::make_address("127.0.0.1"),port));socket.handshake("localhost","/api/v1/events?observer=1");beast::flat_buffer buffer;socket.read(buffer);auto before=vj::Json::parse(beast::buffers_to_string(buffer.data()));buffer.consume(buffer.size());socket.write(asio::buffer(std::string(R"({"type":"grid","action":"add_column"})")));socket.read(buffer);auto after=vj::Json::parse(beast::buffers_to_string(buffer.data()));assert(after["revision"]==before["revision"]);socket.close(ws::close_code::normal);
        }
    }
    std::filesystem::remove_all(directory);std::cout<<"HTTP URL/CORS/method/errors and WebSocket UI commands/read-only events passed\n";
}

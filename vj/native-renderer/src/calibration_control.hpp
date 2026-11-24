#pragma once

// Temporary calibration state. Main-thread presentation acknowledges commands;
// the network thread never owns the GL context or opens another camera.
struct CalibrationControl {
    std::mutex mutex;
    json command=json::object(), status=json::object();
    Clock::time_point received=Clock::now()-std::chrono::seconds(20);
};

void calibration_worker(Runtime *runtime, CalibrationControl *control) {
    while(runtime->running.load()) {
        try {
            const auto url=parse_ws_url("ws://"+runtime->server+"/ws/calibration-renderer");
            if(!url) return;
            asio::io_context io; tcp::resolver resolver(io);
            websocket::stream<beast::tcp_stream> ws(io);
            beast::get_lowest_layer(ws).connect(resolver.resolve(url->host,url->port));
            ws.set_option(websocket::stream_base::timeout::suggested(beast::role_type::client));
            ws.handshake(url->authority(),url->target);
            while(runtime->running.load()) {
                json status;
                { std::lock_guard lock(control->mutex); status=control->status; }
                ws.write(asio::buffer(status.dump()));
                beast::flat_buffer buffer; ws.read(buffer);
                const auto command=json::parse(beast::buffers_to_string(buffer.data()));
                { std::lock_guard lock(control->mutex); control->command=command;control->received=Clock::now(); }
            }
        } catch(const std::exception &error) {
            std::cerr<<"Calibration control: "<<error.what()<<"\n";
            std::this_thread::sleep_for(std::chrono::seconds(1));
        }
    }
}

// Pixel coordinates match the scan decoder: origin at the top left.
void calibration_pattern(const json &pattern, const SDL_Rect &viewport) {
    glEnable(GL_SCISSOR_TEST);
    glScissor(viewport.x,viewport.y,viewport.w,viewport.h);
    const auto kind=pattern.value("kind","black");
    const float level=kind=="white"?std::clamp(pattern.value("brightness",100.0f)/100.f,0.f,1.f):0.f;
    glClearColor(level,level,level,1);glClear(GL_COLOR_BUFFER_BIT);
    if(kind=="gray") {
        const bool horizontal=pattern.value("axis","x")=="x";
        const int size=horizontal?viewport.w:viewport.h;
        const int cell=std::clamp(pattern.value("cell",4),1,64);
        const int bit=std::clamp(pattern.value("bit",0),0,15);
        const bool inverse=pattern.value("inverse",false);
        glClearColor(1,1,1,1);
        for(int pos=0;pos<size;pos+=cell) {
            const int index=pos/cell;
            if(bool(((index^(index>>1))>>bit)&1)==inverse)continue;
            const int count=std::min(cell,size-pos);
            if(horizontal)glScissor(viewport.x+pos,viewport.y,count,viewport.h);
            else glScissor(viewport.x,viewport.y+viewport.h-pos-count,viewport.w,count);
            glClear(GL_COLOR_BUFFER_BIT);
        }
    }
    glDisable(GL_SCISSOR_TEST);
}

Project calibration_grid(const json &pattern,const SDL_Rect &viewport) {
    json rects=json::array();
    for(const auto &card:pattern.value("cards",json::array())) {
        const auto h=card.at("unitToProjector").get<std::vector<double>>();
        if(h.size()!=9)continue;
        json corners=json::array();
        for(auto uv:std::array<std::array<double,2>,4>{{{{0,0}},{{1,0}},{{1,1}},{{0,1}}}}) {
            const double z=h[6]*uv[0]+h[7]*uv[1]+h[8];
            corners.push_back({(h[0]*uv[0]+h[1]*uv[1]+h[2])/z/viewport.w,
                               (h[3]*uv[0]+h[4]*uv[1]+h[5])/z/viewport.h});
        }
        rects.push_back({{"corners",corners},{"mode","grid"},{"graphic","grid"},
                        {"config",{{"color","#00ff00"},{"thickness",3}}}});
    }
    return *parse_project({{"type","mapping_snapshot"},{"project",{{"rects",rects}}}},0);
}

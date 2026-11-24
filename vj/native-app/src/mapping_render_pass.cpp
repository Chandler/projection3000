#include "../../native-renderer/src/surface_curvature_json.hpp"
#include "mapping_render_pass.hpp"
#include "projector_raster.hpp"
#include "surface_curvature.hpp"
#include "rounded_surface.hpp"
#include "selection_marker.hpp"
#include "mapping_fit.hpp"
#include "trace_render_geometry.hpp"
#include <cstddef>
#include <map>
#include <set>
namespace vj {
namespace {
using json=nlohmann::json;
using namespace projector_raster;
// Pattern coordinates match graphics.js's 1024-square Canvas textures. Widths
// therefore deform with the surface, rather than changing in projector pixels.
GLuint make_mapping_program() {
    const char* vertex=R"GLSL(#version 330 core
layout(location=0) in vec2 position;layout(location=1) in vec3 uvq;
out vec3 projected_uv;void main(){projected_uv=uvq;gl_Position=vec4(position,0,1);}
)GLSL";
    const char* fragment=R"GLSL(#version 330 core
uniform sampler2D frame_texture;uniform vec2 destination_scale,content_position;
uniform int use_texture,overlay_grid,pattern_kind;uniform vec2 plane_extent;
uniform bool plane_circle,round_point;uniform vec3 pattern_color;
uniform float pattern_thickness,pattern_marker;
uniform bool hemisphere_on;uniform vec4 hemisphere;uniform int mask_mode;
in vec3 projected_uv;out vec4 color;
)GLSL" VJ_PLANE_PATTERN_GLSL R"GLSL(
float segment(vec2 p,vec2 a,vec2 b){vec2 d=b-a;return length(p-a-d*clamp(dot(p-a,d)/max(dot(d,d),.000001),0.,1.));}
float stroke(float distance,float width,float aa){return 1.-smoothstep(width*.5-aa*.5,width*.5+aa*.5,distance);}
float boundsGrid(vec2 uv){vec2 d=abs(fract(uv*10.+.5)-.5)/max(fwidth(uv*10.),vec2(.000001));vec2 e=min(uv,1.-uv)/max(fwidth(uv),vec2(.000001));return 1.-min(min(min(d.x,d.y),min(e.x,e.y)),1.);}
void surface(vec2 uv){
 if(overlay_grid==1){float line=boundsGrid(uv);if(line<.01)discard;color=vec4(vec3(1),line);return;}
 if(pattern_kind==3&&use_texture==0){if(round_point&&length(uv*2.-1.)>1.)discard;color=vec4(pattern_color,1);return;}
 if(pattern_kind==5&&use_texture==0){float radius=length(uv*2.-1.);float aa=max(fwidth(radius),.001);float a=1.-smoothstep(1.-aa,1.,radius);if(a<.01)discard;color=vec4(pattern_color,a);return;}
 if(round_point&&length(uv*2.-1.)>1.)discard;
 if(use_texture!=0){vec2 source=(uv-(1.-destination_scale)*content_position)/destination_scale;if(any(lessThan(source,vec2(0)))||any(greaterThan(source,vec2(1)))){color=vec4(0);return;}source.y=1.-source.y;color=texture(frame_texture,source);return;}
 if(overlay_grid==3){color=planePattern(uv,plane_extent,plane_circle);return;}
 vec2 p=clamp(uv,0.,1.)*1024.;float aa=max(max(fwidth(p.x),fwidth(p.y)),1.);float line=0.;
 if(pattern_kind==1||pattern_kind==4){vec2 edge=min(abs(p-vec2(3)),abs(p-vec2(1021)));float d=min(edge.x,edge.y);bool inside=all(greaterThanEqual(p,vec2(3-pattern_thickness*.5)))&&all(lessThanEqual(p,vec2(1021+pattern_thickness*.5)));line=inside?stroke(d,pattern_thickness,aa):0.;if(pattern_kind==4){float radius=max(36.,aa*2.5);float dot=1.-smoothstep(radius-aa*.5,radius+aa*.5,length(p-vec2(512)));color=vec4(mix(pattern_color*line,vec3(1),dot),1);}else color=vec4(pattern_color*line,1);return;}
 if(pattern_kind==2){float arm=1024.*pattern_marker*.01,inset=max(pattern_thickness,1024.*.008),far=1024.-inset;float d=1e6;
  for(int i=0;i<4;i++){vec2 c=vec2((i==0||i==3)?inset:far,i<2?inset:far),s=vec2((i==0||i==3)?1.:-1.,i<2?1.:-1.);vec2 a=c+vec2(s.x*arm,0),b=c+vec2(0,s.y*arm);d=min(d,min(segment(p,a,c),min(segment(p,c,b),segment(p,b,a))));}
  float r=arm*.35;d=min(d,min(segment(p,vec2(512-r,512),vec2(512+r,512)),segment(p,vec2(512,512-r),vec2(512,512+r))));line=stroke(d,pattern_thickness,aa);
 }else{vec2 d=abs(fract(p/(1024./20.)+.5)-.5)*(1024./20.);line=stroke(min(d.x,d.y),pattern_thickness,aa);}
 if(line<=.001)discard;color=vec4(pattern_color,line);
}
// hemisphere = (wrap, feather, inset, edge boost). The circle inscribed in the surface's
// unit square is the dome; feather and inset are fractions of its radius.
void main(){float q=abs(projected_uv.z)<.000001?.000001:projected_uv.z;vec2 uv=projected_uv.xy/q;float mask=1.,gain=1.;
 if(hemisphere_on){vec2 d=uv*2.-1.;float edge=1.-hemisphere.z,r=length(d)/edge,aa=max(fwidth(r),.0005);
  mask=1.-smoothstep(1.-max(hemisphere.y/edge,aa),1.,r);if(mask<=0.)discard;r=min(r,1.);
  // Wrap spreads flat content evenly along the dome's arc so it reads as painted on.
  float arc=r>.0001?asin(r)/(1.5707963*r):.6366198;uv=.5+.5*d/edge*mix(1.,arc,hemisphere.x);
  // The rim receives grazing light; boosting it evens out the dome's brightness.
  gain=mix(1.,1./max(sqrt(1.-r*r),.3),hemisphere.w);}
 surface(uv);color.rgb*=gain;color.a*=mask;
 if(mask_mode==1)color.rgb*=mask;else if(mask_mode==2)color.rgb=mix(vec3(1),color.rgb,mask);
}
)GLSL";
    GLuint vs=compile_shader(GL_VERTEX_SHADER,vertex),fs=compile_shader(GL_FRAGMENT_SHADER,fragment),program=glCreateProgram();glAttachShader(program,vs);glAttachShader(program,fs);glLinkProgram(program);glDeleteShader(vs);glDeleteShader(fs);GLint ok=0;glGetProgramiv(program,GL_LINK_STATUS,&ok);if(!ok)throw std::runtime_error("Mapping pattern shader link failed");return program;
}
GLuint make_trace_program() {
    constexpr const char *vertex = R"GLSL(
        #version 330 core
        layout(location = 0) in vec2 position;
        layout(location = 1) in vec3 line_local;
        layout(location = 2) in vec4 core_color;
        layout(location = 3) in vec4 glow_color;
        layout(location = 4) in vec4 widths;
        out vec3 v_line_local;
        out vec4 v_core;
        out vec4 v_glow;
        out vec4 v_widths;
        void main() {
            gl_Position = vec4(position, 0.0, 1.0);
            v_line_local = line_local;
            v_core = core_color;
            v_glow = glow_color;
            v_widths = widths;
        }
    )GLSL";
    constexpr const char *fragment = R"GLSL(
        #version 330 core
        in vec3 v_line_local; // along, across, segment length in pixels
        in vec4 v_core;
        in vec4 v_glow;
        in vec4 v_widths;     // core diameter, glow radius, butt start/end
        uniform int vector_pass; // 0 = glow field, 1 = crisp core
        out vec4 color;
        void main() {
            float along = v_line_local.x;
            float across = v_line_local.y;
            float length_px = v_line_local.z;
            float cap = max(max(-along, along - length_px), 0.0);
            float distance_px = length(vec2(cap, across));
            float core_radius = max(v_widths.x * 0.5, 0.3);
            float aa = max(fwidth(distance_px), 0.7);
            float cap_mask = 1.0;
            if (v_widths.z > 0.5) {
                cap_mask *= smoothstep(-aa, aa, along);
            }
            if (v_widths.w > 0.5) {
                cap_mask *= smoothstep(-aa, aa, length_px - along);
            }
            float core = (1.0 - smoothstep(
                core_radius - aa, core_radius + aa, distance_px))
                * v_core.a * cap_mask;
            if (vector_pass == 0) {
                if (v_widths.y <= 0.0 || v_glow.a <= 0.0) discard;
                // Canvas2D's shadowBlur is substantially tighter than a
                // Gaussian whose sigma equals the UI radius. Model its wide
                // glow stroke plus an approximately half-radius blur.
                float glow_sigma = max(v_widths.y * 0.5, 0.001);
                float glow_stroke_radius =
                    core_radius + v_widths.y * 0.275;
                float glow_distance =
                    max(distance_px - glow_stroke_radius, 0.0);
                float halo = exp(
                    -0.5 * pow(glow_distance / glow_sigma, 2.0))
                    * v_glow.a * cap_mask;
                if (halo < 0.003) discard;
                color = vec4(v_glow.rgb * halo, halo);
                return;
            }
            if (core < 0.001) discard;
            color = vec4(v_core.rgb * core, core);
        }
    )GLSL";
    const GLuint vs = compile_shader(GL_VERTEX_SHADER, vertex);
    const GLuint fs = compile_shader(GL_FRAGMENT_SHADER, fragment);
    const GLuint program = glCreateProgram();
    glAttachShader(program, vs);
    glAttachShader(program, fs);
    glLinkProgram(program);
    glDeleteShader(vs);
    glDeleteShader(fs);
    GLint ok = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &ok);
    if (!ok) {
        GLint length = 0;
        glGetProgramiv(program, GL_INFO_LOG_LENGTH, &length);
        std::string log(static_cast<std::size_t>(std::max(length, 1)), '\0');
        glGetProgramInfoLog(program, length, nullptr, log.data());
        throw std::runtime_error("Vector shader link failed: " + log);
    }
    return program;
}

struct Rect {
    std::string id;
    std::vector<std::array<float, 2>> corners;
    std::vector<std::array<float, 2>> uvs{{
        {{0.0f, 1.0f}}, {{1.0f, 1.0f}}, {{1.0f, 0.0f}}, {{0.0f, 0.0f}},
    }};
    std::string source = "out1";
    std::string native_bus;
    bool fold = false;
    double corner_radius = 0;
    std::vector<Rect> masks;
    std::vector<Rect> overlay_masks;
    surface_curvature::Settings curvature;
    std::shared_ptr<const surface_curvature::Mesh> curved;
    bool live = true;
    int pattern_kind=0;
    std::array<float,3> pattern_color{0,1,0};
    float pattern_thickness=3,pattern_marker=16;
    bool plane_pattern = false, plane_circle = false;
    std::array<float,2> plane_extent{1,1};
    bool overlay = false;
    bool occlude = false;
    bool hemisphere = false;
    std::array<float,4> hemisphere_settings{1,.04f,0,0};
    std::string blend = "normal";
    std::string fit = "stretch";
    std::array<float,2> fit_extent{0,0};
    std::array<float,2> content_position{.5f,.5f};
    // A collection face that follows its Out keeps a span variant to draw instead.
    std::shared_ptr<const Rect> span;
};

// Projector-space pin annotations mirror native-renderer/main.cpp make_pin_scene:
// targets never follow the fitted mesh, and labels share the surface layer order.
std::vector<TraceGpuVertex> pinVertices(const Rect& rect,int width,int height,int rotation){
    std::vector<TraceGpuVertex> vertices;if(rect.live||rect.overlay||rect.fold||rect.curvature.pins.empty())return vertices;
    const auto matrix=surface_curvature::quad_matrix(rect.corners);if(!matrix)return vertices;const auto& h=*matrix;
    const float w=(rotation==90||rotation==270)?height:width,v=(rotation==90||rotation==270)?width:height;
    using Point=std::array<float,2>;auto project=[&](const std::array<double,2>& p){const double q=h[6]*p[0]+h[7]*p[1]+h[8];return Point{float((h[0]*p[0]+h[1]*p[1]+h[2])/q)*w,float((h[3]*p[0]+h[4]*p[1]+h[5])/q)*v};};
    const auto center=project({.5,.5});const std::array<std::array<float,4>,4> colors={{{.396f,.843f,1,1},{1,.749f,.412f,1},{.769f,.627f,1,1},{.486f,.867f,.659f,1}}};
    const unsigned digits[]={0x3f,0x06,0x5b,0x4f,0x66,0x6d,0x7d,0x07,0x7f,0x6f};const float strokes[7][4]={{0,0,6,0},{6,0,6,6},{6,6,6,12},{0,12,6,12},{0,6,0,12},{0,0,0,6},{0,6,6,6}};
    for(size_t i=0;i<rect.curvature.pins.size();++i){const auto& pin=rect.curvature.pins[i];const auto target=project(pin.target);const auto uv=surface_curvature::pin_uv(pin.side,pin.t);const auto actual=project(surface_curvature::point(uv[0],uv[1],rect.curvature));
        if(!std::isfinite(target[0])||!std::isfinite(target[1])||!std::isfinite(actual[0])||!std::isfinite(actual[1]))continue;
        const bool enabled=rect.curvature.pins_enabled&&pin.enabled;const auto color=enabled?colors[pin.side]:std::array<float,4>{.48f,.5f,.54f,1};
        auto line=[&](float x1,float y1,float x2,float y2){auto a=rotate_output_uv({x1/w,y1/v},rotation),b=rotate_output_uv({x2/w,y2/v},rotation);a={a[0]*width,a[1]*height};b={b[0]*width,b[1]*height};const float dx=b[0]-a[0],dy=b[1]-a[1],length=std::hypot(dx,dy);if(length<.001f)return;const float tx=dx/length,ty=dy/length,nx=-ty,ny=tx,pad=2.5f;
            const std::array<std::array<float,4>,4> points={{{a[0]-tx*pad+nx*pad,a[1]-ty*pad+ny*pad,-pad,pad},{a[0]-tx*pad-nx*pad,a[1]-ty*pad-ny*pad,-pad,-pad},{b[0]+tx*pad+nx*pad,b[1]+ty*pad+ny*pad,length+pad,pad},{b[0]+tx*pad-nx*pad,b[1]+ty*pad-ny*pad,length+pad,-pad}}};
            for(int index:{0,1,2,1,3,2}){const auto& p=points[index];vertices.push_back({{p[0]/width*2-1,1-p[1]/height*2},{p[2],p[3],length},{color[0],color[1],color[2],color[3]},{0,0,0,0},{2,0,0,0}});}
        };
        const float dx=actual[0]-target[0],dy=actual[1]-target[1],distance=std::hypot(dx,dy);for(float d=0;d<distance;d+=9){const float end=std::min(d+5,distance);line(target[0]+dx*d/distance,target[1]+dy*d/distance,target[0]+dx*end/distance,target[1]+dy*end/distance);}
        if(distance>3){line(actual[0]-3,actual[1]-3,actual[0]+3,actual[1]+3);line(actual[0]-3,actual[1]+3,actual[0]+3,actual[1]-3);}
        for(int j=0;j<24;++j){if(!enabled&&j%3==2)continue;const float a=j*6.2831853f/24,b=(j+1)*6.2831853f/24;line(target[0]+8*std::cos(a),target[1]+8*std::sin(a),target[0]+8*std::cos(b),target[1]+8*std::sin(b));}
        line(target[0]-4,target[1],target[0]+4,target[1]);line(target[0],target[1]-4,target[0],target[1]+4);const auto label=std::to_string(i+1);const float inward=std::max(1.f,std::hypot(center[0]-target[0],center[1]-target[1]));const float x=target[0]+22*(center[0]-target[0])/inward-(label.size()*10-4)/2.f,y=target[1]+22*(center[1]-target[1])/inward-6;
        for(size_t n=0;n<label.size();++n)for(int j=0;j<7;++j)if(digits[label[n]-'0']&(1<<j))line(x+n*10+strokes[j][0],y+strokes[j][1],x+n*10+strokes[j][2],y+strokes[j][3]);
    }return vertices;
}

bool finite_pair(const json& point){return point.is_array()&&point.size()==2&&point[0].is_number()&&point[1].is_number()&&std::isfinite(point[0].get<double>())&&std::isfinite(point[1].get<double>());}
std::map<std::string,std::array<float,3>> boxFaceColors(const json& value){
    std::map<std::string,std::array<float,3>> colors;
    if(auto collections=value.find("collections");collections!=value.end())for(const auto& collection:*collections)if(collection.value("kind",std::string{})=="boxes")
        if(auto faces=collection.find("faces");faces!=collection.end())for(const auto& face:*faces){
            const auto side=face.value("side",std::string{});
            colors[face.value("rectId",std::string{})]=(side=="front"||side=="back")?std::array<float,3>{0,1,1}:
                (side=="left"||side=="right")?std::array<float,3>{1,0,1}:std::array<float,3>{1,1,0};
        }
    return colors;
}
std::vector<Rect> surfaces(const json& value,const std::map<std::string,std::array<float,3>>& boxColors){std::vector<Rect> result;
    const auto rects = value.find(value.contains("renderRects") ? "renderRects" : "rects");
    if (rects == value.end() || !rects->is_array()) return {};
    for (const auto &item : *rects) {
        if (!item.is_object()) continue;
        const auto corners = item.find("corners");
        if (corners == item.end() || !corners->is_array()
            || corners->size() < 3 || corners->size() > 64) {
            continue;
        }
        Rect rect;
        rect.id=item.value("id",std::string{});
        rect.corners.clear();
        bool valid = true;
        for (const auto &point : *corners) {
            if (!finite_pair(point)) {
                valid = false;
                break;
            }
            rect.corners.push_back(
                {point[0].get<float>(), point[1].get<float>()});
        }
        if (!valid) continue;
        if (const auto uvs = item.find("uvs");
            uvs != item.end() && uvs->is_array()
            && uvs->size() == rect.corners.size()) {
            rect.uvs.clear();
            for (const auto &point : *uvs) {
                if (!finite_pair(point)) {
                    valid = false;
                    break;
                }
                rect.uvs.push_back(
                    {point[0].get<float>(), point[1].get<float>()});
            }
        } else if (rect.corners.size() != 4) {
            valid = false;
        }
        if (!valid) continue;
        rect.fold = item.value("fold", false) && rect.corners.size()==6;
        rect.corner_radius=std::clamp(item.value("cornerRadius",0.0),0.0,.5);
        for(const auto* field:{"maskSurfaces","overlaySurfaces"})if(const auto masks=item.find(field);masks!=item.end()&&masks->is_array()){
            for(const auto& raw:*masks){
                Rect mask;mask.corner_radius=raw.value("cornerRadius",0.0);
                for(const auto& p:raw.at("corners"))mask.corners.push_back({p[0].get<float>(),p[1].get<float>()});
                mask.curvature=surface_curvature::from_json(raw.value("curvature",json()));
                if(mask.curvature.active()){
                    auto mesh=surface_curvature::build(mask.corners,{{0,0},{1,0},{1,1},{0,1}},mask.curvature);
                    if(mesh)mask.curved=std::make_shared<const surface_curvature::Mesh>(std::move(*mesh));
                }
                (std::string(field)=="overlaySurfaces"?rect.overlay_masks:rect.masks).push_back(std::move(mask));
            }
        }
        if(const auto c=item.find("curvature");c!=item.end()&&c->is_object()){
            rect.curvature={c->value("top",0.0),c->value("right",0.0),c->value("bottom",0.0),c->value("left",0.0),c->value("wrapX",0.0),c->value("wrapY",0.0)};
            rect.curvature.spacing_x=c->value("spacingX",0.0);rect.curvature.spacing_y=c->value("spacingY",0.0);
            const std::array<std::string,4> sides{"top","right","bottom","left"};
            for(int i=0;i<4;i++){
                rect.curvature.skew[i]=c->value(sides[i]+"Skew",0.0);
                rect.curvature.shape[i]=c->value(sides[i]+"Shape",0.0);
            }
            if(const auto pins=c->find("pins");pins!=c->end()&&pins->is_object()){
                rect.curvature.pins_enabled=pins->value("enabled",true);
                rect.curvature.local_pins=pins->value("method",std::string("fit"))=="local";
                if(const auto points=pins->find("points");points!=pins->end()&&points->is_array())for(const auto& p:*points){
                    const auto side=std::find(sides.begin(),sides.end(),p.value("side",std::string()));
                    if(side==sides.end()||!p.contains("target")||!finite_pair(p["target"]))continue;
                    rect.curvature.pins.push_back({int(side-sides.begin()),p.value("t",.5),{p["target"][0].get<double>(),p["target"][1].get<double>()},p.value("enabled",true)});
                }
                surface_curvature::prepare_pins(rect.curvature);
            }
            if(rect.curvature.active()){
                if(rect.fold)continue;
                auto mesh=surface_curvature::build(rect.corners,rect.uvs,rect.curvature);
                if(!mesh)continue;
                rect.curved=std::make_shared<const surface_curvature::Mesh>(std::move(*mesh));
            }
        }
        rect.source = item.value("source", "out1");
        rect.native_bus = item.value("nativeBus", "");
        if (output_source_index(rect.source) < 0 && rect.source != "none") rect.source = "out1";
        if(const auto extent=item.find("planePattern");extent!=item.end() && finite_pair(*extent)){
            rect.plane_pattern=true;rect.plane_extent={(*extent)[0].get<float>(),(*extent)[1].get<float>()};
            rect.plane_circle=item.value("pointShape",std::string{})=="circle";
        }
        rect.live = item.value("mode", "live") != "grid";
        auto graphic=item.value("graphic",std::string("grid"));rect.pattern_kind=graphic=="solid"?3:graphic=="wireframe"?1:graphic=="alignment"?2:0;
        auto config=item.value("config",json::object());if(!config.is_object())config=json::object();
        if(graphic=="wireframe"&&config.value("centerDot",json(false))==true)rect.pattern_kind=4;
        if(graphic=="wireframe"&&config.value("centerOnly",false))rect.pattern_kind=5;
        auto color=config.value("color",graphic=="wireframe"?std::string("#00ff66"):graphic=="alignment"?std::string("#ffffff"):std::string("#00ff00"));
        if(color.size()==7&&color.front()=='#')try{unsigned long rgb=std::stoul(color.substr(1),nullptr,16);rect.pattern_color={float((rgb>>16)&255)/255,float((rgb>>8)&255)/255,float(rgb&255)/255};}catch(...){}
        rect.pattern_thickness=std::clamp(config.value("thickness",graphic=="wireframe"?4.f:3.f),1.f,20.f);rect.pattern_marker=std::clamp(config.value("markerSize",16.f),5.f,35.f);
        if(!rect.live&&(!item.value("patternStyleExplicit",false)||graphic=="faces"))if(const auto color=boxColors.find(rect.id);color!=boxColors.end()){
            rect.pattern_kind=3;rect.pattern_color=color->second;
        }
        if(item.value("patternStyleExplicit",false)||graphic=="solid")rect.plane_pattern=false;
        rect.overlay = item.value("kind", "surface") == "overlay";
        rect.occlude = !rect.overlay && item.value("occlude", false);
        if(const auto h=item.find("hemisphere");h!=item.end()&&h->is_object()&&h->value("enabled",true)&&!rect.overlay&&!rect.fold&&rect.corners.size()==4){
            rect.hemisphere=true;
            rect.hemisphere_settings={std::clamp(h->value("wrap",1.f),0.f,1.f),std::clamp(h->value("feather",.04f),0.f,.5f),std::clamp(h->value("inset",0.f),0.f,.5f),std::clamp(h->value("edgeBoost",0.f),0.f,1.f)};
            rect.corner_radius=0;
        }
        rect.blend = item.value("blend", "normal");
        rect.fit = item.value("fit", "stretch");
        if(auto position=item.find("contentPosition");position!=item.end()&&finite_pair(*position))
            rect.content_position={std::clamp((*position)[0].get<float>(),0.f,1.f),std::clamp((*position)[1].get<float>(),0.f,1.f)};
        if(auto bounds=item.find("fitBounds");bounds!=item.end()&&finite_pair(*bounds)&&(*bounds)[0]>0&&(*bounds)[1]>0)rect.fit_extent={(*bounds)[0].get<float>(),(*bounds)[1].get<float>()};
        if(const auto span=item.find("spanUvs");span!=item.end()){
            auto variant=item;variant["uvs"]=*span;variant.erase("spanUvs");
            if(auto parsed=surfaces(json{{"rects",json::array({variant})}},boxColors);parsed.size()==1)rect.span=std::make_shared<const Rect>(std::move(parsed[0]));
        }
        result.push_back(std::move(rect));
    }
return result;}
}
struct MappingRenderPass::Impl {
    json cachedRectInput;
    std::map<std::string,std::array<float,3>> cachedBoxColors;
    std::vector<Rect> cachedRects;

    GLuint program=0,marker_program=0,vao=0,vbo=0,ebo=0,fallback_texture=0;
    GLuint trace_program=0,trace_vao=0,trace_vbo=0;GLint trace_pass=0;
    GLint texture_location,overlay_location,scale_location,position_location,plane_extent_location,plane_circle_location;
    GLint pattern_kind_location,pattern_color_location,pattern_thickness_location,pattern_marker_location,round_point_location;
    GLint hemisphere_on_location,hemisphere_location,mask_mode_location;
    Impl(){
        program=make_mapping_program();
        glGenTextures(1,&fallback_texture);glBindTexture(GL_TEXTURE_2D,fallback_texture);const unsigned char black[]={0,0,0,255};glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,1,1,0,GL_RGBA,GL_UNSIGNED_BYTE,black);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
        trace_program=make_trace_program();trace_pass=glGetUniformLocation(trace_program,"vector_pass");
        glGenVertexArrays(1,&trace_vao);glGenBuffers(1,&trace_vbo);glBindVertexArray(trace_vao);glBindBuffer(GL_ARRAY_BUFFER,trace_vbo);
        const int components[]={2,3,4,4,4};const size_t offsets[]={offsetof(TraceGpuVertex,position),offsetof(TraceGpuVertex,local),offsetof(TraceGpuVertex,core),offsetof(TraceGpuVertex,glow),offsetof(TraceGpuVertex,widths)};
        for(int i=0;i<5;i++){glEnableVertexAttribArray(i);glVertexAttribPointer(i,components[i],GL_FLOAT,GL_FALSE,sizeof(TraceGpuVertex),reinterpret_cast<void*>(offsets[i]));}
        const auto vs=compile_shader(GL_VERTEX_SHADER,"#version 330 core\nlayout(location=0) in vec2 position;void main(){gl_Position=vec4(position,0,1);}");
        const auto fs=compile_shader(GL_FRAGMENT_SHADER,"#version 330 core\nout vec4 color;void main(){color=vec4(.08,.65,.18,.65);}");
        marker_program=glCreateProgram();glAttachShader(marker_program,vs);glAttachShader(marker_program,fs);glLinkProgram(marker_program);glDeleteShader(vs);glDeleteShader(fs);
        GLint linked=0;glGetProgramiv(marker_program,GL_LINK_STATUS,&linked);if(!linked)throw std::runtime_error("Mapping marker shader link failed");
        glGenVertexArrays(1,&vao);glGenBuffers(1,&vbo);glGenBuffers(1,&ebo);
        glBindVertexArray(vao);glBindBuffer(GL_ARRAY_BUFFER,vbo);glBindBuffer(GL_ELEMENT_ARRAY_BUFFER,ebo);
        glEnableVertexAttribArray(0);glVertexAttribPointer(0,2,GL_FLOAT,GL_FALSE,5*sizeof(float),nullptr);
        glEnableVertexAttribArray(1);glVertexAttribPointer(1,3,GL_FLOAT,GL_FALSE,5*sizeof(float),reinterpret_cast<void*>(2*sizeof(float)));
        texture_location=glGetUniformLocation(program,"use_texture");overlay_location=glGetUniformLocation(program,"overlay_grid");
        scale_location=glGetUniformLocation(program,"destination_scale");position_location=glGetUniformLocation(program,"content_position");plane_extent_location=glGetUniformLocation(program,"plane_extent");plane_circle_location=glGetUniformLocation(program,"plane_circle");
        pattern_kind_location=glGetUniformLocation(program,"pattern_kind");pattern_color_location=glGetUniformLocation(program,"pattern_color");pattern_thickness_location=glGetUniformLocation(program,"pattern_thickness");pattern_marker_location=glGetUniformLocation(program,"pattern_marker");round_point_location=glGetUniformLocation(program,"round_point");
        hemisphere_on_location=glGetUniformLocation(program,"hemisphere_on");hemisphere_location=glGetUniformLocation(program,"hemisphere");mask_mode_location=glGetUniformLocation(program,"mask_mode");
        glUseProgram(program);glUniform1i(glGetUniformLocation(program,"frame_texture"),0);
    }
    ~Impl(){if(fallback_texture)glDeleteTextures(1,&fallback_texture);if(trace_vbo)glDeleteBuffers(1,&trace_vbo);if(trace_vao)glDeleteVertexArrays(1,&trace_vao);if(trace_program)glDeleteProgram(trace_program);if(marker_program)glDeleteProgram(marker_program);if(ebo)glDeleteBuffers(1,&ebo);if(vbo)glDeleteBuffers(1,&vbo);if(vao)glDeleteVertexArrays(1,&vao);if(program)glDeleteProgram(program);}
    void render(const json& mapping,int drawable_w,int drawable_h,const MappingRenderPass::TextureLookup& lookup,const MappingRenderPass::TraceLookup& traceLookup,bool ignoreOutputRotation=false,NativeRenderGraph* graph=nullptr){
        const auto& value=mapping.contains("project")?mapping.at("project"):mapping;
        const auto output=value.value("output",json::object());
        static const json emptyRects=json::array();
        const auto input=value.find(value.contains("renderRects")?"renderRects":"rects");
        const auto& rectInput=input==value.end()?emptyRects:*input;
        const auto boxColors=boxFaceColors(value);
        if(cachedRectInput!=rectInput||cachedBoxColors!=boxColors){
            cachedRectInput=rectInput;cachedBoxColors=boxColors;
            cachedRects=surfaces(value,boxColors);
        }
        struct {const std::vector<Rect>& rects;int rotation;} project{cachedRects,ignoreOutputRotation?0:output.value("rotation",0)};
        glViewport(0,0,drawable_w,drawable_h);glDisable(GL_SCISSOR_TEST);glDisable(GL_CULL_FACE);glDisable(GL_DEPTH_TEST);glDisable(GL_STENCIL_TEST);
        glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);glClearColor(0,0,0,1);glClear(GL_COLOR_BUFFER_BIT);
        if(!output.value("enabled",true))return;
        glUseProgram(program);glBindVertexArray(vao);glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,fallback_texture);
        glUniform1i(hemisphere_on_location,0);glUniform1i(mask_mode_location,0);
        std::function<void(const Rect&)> stencil_polygon = [&](const Rect &shape) {
            if(!shape.masks.empty()){
                for(const auto& mask:shape.masks)stencil_polygon(mask);
                return;
            }
            std::vector<float> vertices;
            std::vector<std::array<float,2>> coverage=shape.corners;
            const bool rounded=(shape.corner_radius>0||shape.hemisphere)&&shape.corners.size()==4&&!shape.fold;
            if(shape.hemisphere){
                coverage=rounded_surface::triangles(rounded_surface::ellipse_outline(shape.corners,shape.curvature,shape.hemisphere_settings[2]));
            } else if(rounded){
                const double aspect=(project.rotation==90||project.rotation==270)?double(drawable_h)/drawable_w:double(drawable_w)/drawable_h;
                coverage=rounded_surface::triangles(rounded_surface::outline(shape.corners,shape.curvature,shape.corner_radius,aspect));
            } else if(shape.curved){
                coverage.clear();
                for(auto index:shape.curved->indices)coverage.push_back(shape.curved->points[index]);
            } else if(shape.fold && shape.corners.size()==6){
                coverage.clear();
                for(int i:{0,1,4,0,4,5,1,2,3,1,3,4})coverage.push_back(shape.corners[i]);
            }
            for (const auto &corner : coverage) {
                const auto rotated = rotate_output_uv(corner, project.rotation);
                float x = rotated[0] * 2.0f - 1.0f;
                float y = 1.0f - rotated[1] * 2.0f;
                vertices.insert(vertices.end(), {x, y, 0.5f, 0.5f, 1.0f});
            }
            glBindBuffer(GL_ARRAY_BUFFER, vbo);
            glBufferData(GL_ARRAY_BUFFER, vertices.size() * sizeof(float), vertices.data(), GL_DYNAMIC_DRAW);
            glDrawArrays((rounded || shape.fold || shape.curved) ? GL_TRIANGLES : GL_TRIANGLE_FAN, 0, static_cast<GLsizei>(coverage.size()));
        };
        for (std::size_t rect_index = 0; rect_index < project.rects.size(); ++rect_index) {
            const auto &base = project.rects[rect_index];
            const int base_index=output_source_index(base.source);
            const auto &rect = base.span && lookup(base.native_bus.empty()?(base_index>=0?kOutputBuses[base_index]:base.source):base.native_bus).span ? *base.span : base;
            glDisable(GL_STENCIL_TEST);
            if (rect.source == "none") continue;
            NativeBusTexture backdropOverlay;
            if(graph&&rect.live&&!rect.native_bus.empty())
                backdropOverlay=graph->projector_overlay(rect.native_bus,drawable_w,drawable_h,project.rotation);
            // The overlay renderer uses its own GL program and targets.
            glUseProgram(program);glBindVertexArray(vao);glActiveTexture(GL_TEXTURE0);
            if (rect.overlay || rect.corner_radius>0 || !rect.masks.empty()) {
                glUseProgram(program);
                glBindVertexArray(vao);
                glUniform1i(texture_location, 0);
                glUniform1i(overlay_location, 0);glUniform1i(pattern_kind_location,3);glUniform1i(round_point_location,0);glBindTexture(GL_TEXTURE_2D,fallback_texture);
                glEnable(GL_STENCIL_TEST);
                glStencilMask(0xff);
                glClearStencil(0);
                glClear(GL_STENCIL_BUFFER_BIT);
                glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
                glStencilFunc(GL_ALWAYS, 1, 0xff);
                glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE);
                if(rect.overlay){
                    for (std::size_t lower = 0; lower < rect_index; ++lower)
                        if (!project.rects[lower].overlay){
                            const auto& below=project.rects[lower];
                            if(below.overlay_masks.empty())stencil_polygon(below);
                            else for(const auto& mask:below.overlay_masks)stencil_polygon(mask);
                        }
                    glStencilFunc(GL_EQUAL, 1, 0xff);
                    glStencilOp(GL_KEEP, GL_KEEP, GL_INCR);
                }
                stencil_polygon(rect);
                glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
                glStencilMask(0);
                glStencilFunc(GL_EQUAL, rect.overlay?2:1, 0xff);
                glStencilOp(GL_KEEP, GL_KEEP, GL_KEEP);
            }
            glUseProgram(program);
            glBindVertexArray(vao);
            const auto uvq = projective_uvs(rect);
            std::vector<float> vertices;
            std::vector<unsigned int> mapping_indices;
            auto append_vertex = [&](const std::array<float, 2> &point,
                                     float u, float v, float q) {
                const auto rotated = rotate_output_uv(point, project.rotation);
                float px = rotated[0] * 2.0f - 1.0f;
                float py = 1.0f - rotated[1] * 2.0f;
                vertices.insert(vertices.end(), {px, py, u, v, q});
            };
            if(rect.curved){
                for(std::size_t i=0;i<rect.curved->points.size();i++){
                    const auto &uv=rect.curved->uvqs[i];append_vertex(rect.curved->points[i],uv[0],uv[1],uv[2]);
                }
                mapping_indices=rect.curved->indices;
            } else if(rect.fold && rect.corners.size()==6 && rect.uvs.size()==6){
                for(const auto &panel : std::array<std::array<int,4>,2>{{{{0,1,4,5}},{{1,2,3,4}}}}){
                    Rect part=rect;part.fold=false;part.corners.clear();part.uvs.clear();
                    for(int i:panel){part.corners.push_back(rect.corners[i]);part.uvs.push_back(rect.uvs[i]);}
                    const auto pq=projective_uvs(part);
                    if(!pq)continue;
                    const unsigned int offset=vertices.size()/5;
                    for(int i=0;i<4;++i)append_vertex(part.corners[i],(*pq)[i][0],(*pq)[i][1],(*pq)[i][2]);
                    for(unsigned int i:{0u,1u,2u,0u,2u,3u})mapping_indices.push_back(offset+i);
                }
            } else if (uvq) {
                for (int i = 0; i < 4; ++i) {
                    append_vertex(
                        rect.corners[i], (*uvq)[i][0],
                        (*uvq)[i][1], (*uvq)[i][2]);
                }
                mapping_indices = {0, 1, 2, 0, 2, 3};
            } else if (rect.corners.size() == rect.uvs.size()
                       && rect.corners.size() >= 3) {
                std::array<float, 2> center{0, 0};
                std::array<float, 2> center_uv{0, 0};
                for (std::size_t i = 0; i < rect.corners.size(); ++i) {
                    center[0] += rect.corners[i][0];
                    center[1] += rect.corners[i][1];
                    center_uv[0] += rect.uvs[i][0];
                    center_uv[1] += rect.uvs[i][1];
                }
                const float divisor =
                    static_cast<float>(rect.corners.size());
                center[0] /= divisor;
                center[1] /= divisor;
                center_uv[0] /= divisor;
                center_uv[1] /= divisor;
                append_vertex(center, center_uv[0], center_uv[1], 1.0f);
                for (std::size_t i = 0; i < rect.corners.size(); ++i) {
                    append_vertex(
                        rect.corners[i], rect.uvs[i][0],
                        rect.uvs[i][1], 1.0f);
                    mapping_indices.insert(mapping_indices.end(), {
                        0,
                        static_cast<unsigned int>(i + 1),
                        static_cast<unsigned int>(
                            (i + 1) % rect.corners.size() + 1),
                    });
                }
            } else {
                continue;
            }
            glBindBuffer(GL_ARRAY_BUFFER, vbo);
            glBufferData(
                GL_ARRAY_BUFFER,
                static_cast<GLsizeiptr>(vertices.size() * sizeof(float)),
                vertices.data(), GL_DYNAMIC_DRAW);
            glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ebo);
            glBufferData(
                GL_ELEMENT_ARRAY_BUFFER,
                static_cast<GLsizeiptr>(
                    mapping_indices.size() * sizeof(unsigned int)),
                mapping_indices.data(), GL_DYNAMIC_DRAW);

            glUniform1i(hemisphere_on_location,rect.hemisphere);glUniform1i(mask_mode_location,0);
            glUniform4f(hemisphere_location,rect.hemisphere_settings[0],rect.hemisphere_settings[1],rect.hemisphere_settings[2],rect.hemisphere_settings[3]);
            if(rect.occlude){
                // Black out everything beneath this surface's shape first, so lower
                // surfaces stay hidden where its content is transparent or blended.
                // A hemisphere's feathered rim fades the black out with its mask.
                glUniform1i(texture_location,0);glUniform1i(overlay_location,0);glUniform1i(pattern_kind_location,3);
                glUniform1i(round_point_location,(rect.live||!rect.plane_pattern)&&rect.plane_circle);
                glUniform3f(pattern_color_location,0,0,0);glUniform2f(scale_location,1,1);
                glEnable(GL_BLEND);glBlendEquation(GL_FUNC_ADD);glBlendFunc(GL_ZERO,GL_ONE_MINUS_SRC_ALPHA);
                glDrawElements(GL_TRIANGLES,static_cast<GLsizei>(mapping_indices.size()),GL_UNSIGNED_INT,nullptr);
            }
            const int index=output_source_index(rect.source);
            // Overlays sample their Out just like surfaces. The stencil above
            // clips that continuous image to the union of lower surfaces.
            auto gpu=backdropOverlay.texture?backdropOverlay:lookup(rect.native_bus.empty()?(index>=0?kOutputBuses[index]:rect.source):rect.native_bus);
            const bool textured = rect.live && gpu.width > 0 && gpu.height > 0 && gpu.texture != 0;
            glUniform1i(texture_location, textured ? 1 : 0);
            glUniform1i(overlay_location, !rect.live && rect.plane_pattern ? 3 : 0);
            glUniform1i(pattern_kind_location,rect.overlay&&rect.live&&!textured?3:rect.pattern_kind);glUniform1i(round_point_location,(rect.live||!rect.plane_pattern)&&rect.plane_circle);
            glUniform3f(pattern_color_location,rect.overlay&&rect.live?0:rect.pattern_color[0],rect.overlay&&rect.live?0:rect.pattern_color[1],rect.overlay&&rect.live?0:rect.pattern_color[2]);
            glUniform1f(pattern_thickness_location,rect.pattern_thickness);glUniform1f(pattern_marker_location,rect.pattern_marker);
            glUniform2f(plane_extent_location,rect.plane_extent[0],rect.plane_extent[1]);
            glUniform1i(plane_circle_location,rect.plane_circle);
            glBindTexture(GL_TEXTURE_2D, gpu.texture?gpu.texture:fallback_texture);

            float scale_x = 1.0f, scale_y = 1.0f;
            if (textured && rect.fit != "stretch") {
                float min_x = 1, max_x = 0, min_y = 1, max_y = 0;
                for (const auto &corner : rect.corners) {
                    min_x = std::min(min_x, corner[0]);
                    max_x = std::max(max_x, corner[0]);
                    min_y = std::min(min_y, corner[1]);
                    max_y = std::max(max_y, corner[1]);
                }
                const float box_w = std::max((rect.fit_extent[0]>0?rect.fit_extent[0]:max_x-min_x) * ((project.rotation==90||project.rotation==270)?drawable_h:drawable_w), 0.001f);
                const float box_h = std::max((rect.fit_extent[1]>0?rect.fit_extent[1]:max_y-min_y) * ((project.rotation==90||project.rotation==270)?drawable_w:drawable_h), 0.001f);
                const auto scale = mapping_content_scale(
                    rect.fit, static_cast<float>(gpu.width) / gpu.height,
                    box_w, box_h);
                scale_x = scale[0];
                scale_y = scale[1];
            }
            glUniform2f(scale_location, scale_x, scale_y);
            // Stored crop positions use top-origin image coordinates; mapping
            // UVs are flipped immediately before the texture sample.
            glUniform2f(position_location,rect.fit=="fill"?rect.content_position[0]:.5f,rect.fit=="fill"?1.f-rect.content_position[1]:.5f);
            set_blend(rect.blend);
            // Blends that ignore source alpha need the hemisphere's soft edge folded into color.
            if(rect.hemisphere)glUniform1i(mask_mode_location,rect.blend=="multiply"?2:rect.blend=="normal"||rect.blend=="subtract"?0:1);

            glDrawElements(
                GL_TRIANGLES,
                static_cast<GLsizei>(mapping_indices.size()),
                GL_UNSIGNED_INT, nullptr);
            if(!rect.live&&!rect.overlay&&!rect.curvature.pins.empty()){
                const auto pins=pinVertices(rect,drawable_w,drawable_h,project.rotation);
                glUseProgram(trace_program);glBindVertexArray(trace_vao);glBindBuffer(GL_ARRAY_BUFFER,trace_vbo);glBufferData(GL_ARRAY_BUFFER,pins.size()*sizeof(TraceGpuVertex),pins.data(),GL_DYNAMIC_DRAW);
                glUniform1i(trace_pass,1);glEnable(GL_BLEND);glBlendEquation(GL_FUNC_ADD);glBlendFunc(GL_ONE,GL_ONE_MINUS_SRC_ALPHA);glDrawArrays(GL_TRIANGLES,0,pins.size());
                glUseProgram(program);glBindVertexArray(vao);
            }
        }
        glDisable(GL_STENCIL_TEST);glStencilMask(0xff);glBlendEquation(GL_FUNC_ADD);glBlendFunc(GL_SRC_ALPHA,GL_ONE_MINUS_SRC_ALPHA);
        if(traceLookup&&value.contains("traces")&&value["traces"].is_array()){
            const auto mid=mapping.value("mappingId",mapping.value("id",std::string("1")));
            glUseProgram(trace_program);glBindVertexArray(trace_vao);
            for(const auto& trace:value["traces"]){
                if(!trace.is_object()||!trace.value("enabled",true))continue;
                const auto id=trace.value("id",std::string{});if(id.empty())continue;
                const auto rgb=traceLookup((mid=="1"?"map-":"map"+mid+"-")+id);
                const auto vertices=traceRenderGeometry(trace,rgb,drawable_w,drawable_h,project.rotation);if(vertices.empty())continue;
                glBindBuffer(GL_ARRAY_BUFFER,trace_vbo);glBufferData(GL_ARRAY_BUFFER,vertices.size()*sizeof(TraceGpuVertex),vertices.data(),GL_DYNAMIC_DRAW);
                const auto blend=trace.value("blend",std::string("add"));glEnable(GL_BLEND);
                for(int pass=0;pass<2;pass++){
                    glUniform1i(trace_pass,pass);glBlendEquation(pass==0&&blend=="normal"?GL_MAX:GL_FUNC_ADD);
                    if(blend=="add")glBlendFunc(GL_ONE,GL_ONE);else if(blend=="screen")glBlendFunc(GL_ONE,GL_ONE_MINUS_SRC_COLOR);else glBlendFunc(GL_ONE,GL_ONE_MINUS_SRC_ALPHA);
                    glDrawArrays(GL_TRIANGLES,0,vertices.size());
                }
            }
            glUseProgram(program);glBindVertexArray(vao);glBlendEquation(GL_FUNC_ADD);glBlendFunc(GL_SRC_ALPHA,GL_ONE_MINUS_SRC_ALPHA);
        }
        if(output.value("boundsGrid",false)){
            const float vertices[]={-1,1,0,1,1, 1,1,1,1,1, 1,-1,1,0,1, -1,-1,0,0,1};
            glBindBuffer(GL_ARRAY_BUFFER,vbo);glBufferData(GL_ARRAY_BUFFER,sizeof(vertices),vertices,GL_DYNAMIC_DRAW);
            // The projector grid stays flat: clear any hemisphere warp left by the last surface.
            glEnable(GL_BLEND);glUseProgram(program);glBindVertexArray(vao);glUniform1i(hemisphere_on_location,0);glUniform1i(mask_mode_location,0);glUniform1i(texture_location,0);glUniform1i(overlay_location,1);glUniform2f(scale_location,1,1);glDrawArrays(GL_TRIANGLE_FAN,0,4);
        }
        const auto selected=mapping.value("selectedRectIds",json::array());
        glEnable(GL_BLEND);glBlendEquation(GL_FUNC_ADD);glBlendFunc(GL_SRC_ALPHA,GL_ONE_MINUS_SRC_ALPHA);glUseProgram(marker_program);glBindVertexArray(vao);
        // Marker is an independent thin square; it never obscures surface corners.
        // Reuse the same center/size helper as the reference projection renderer.
        for(const auto& rect:project.rects){
            if(rect.live||rect.source=="none"||std::find(selected.begin(),selected.end(),json(rect.id))==selected.end())continue;
            auto points=selection_marker::square(rect.corners,rect.curvature,drawable_w,drawable_h,project.rotation);
            std::vector<float> vertices;
            for(const auto& p:points){auto rotated=rotate_output_uv(p,project.rotation);vertices.insert(vertices.end(),{rotated[0]*2-1,1-rotated[1]*2,.5f,.5f,1});}
            glBindBuffer(GL_ARRAY_BUFFER,vbo);glBufferData(GL_ARRAY_BUFFER,vertices.size()*sizeof(float),vertices.data(),GL_DYNAMIC_DRAW);
            glLineWidth(1);glDrawArrays(GL_LINE_LOOP,0,points.size());
        }
        glDisable(GL_BLEND);glBindVertexArray(0);glUseProgram(0);
    }
};
MappingRenderPass::MappingRenderPass():impl_(std::make_unique<Impl>()){}
MappingRenderPass::~MappingRenderPass()=default;
void MappingRenderPass::render(const json& mapping,int width,int height,const TextureLookup& lookup,const TraceLookup& traces,const json& calibration,bool ignoreOutputRotation,NativeRenderGraph* graph){
    if(width<1||height<1)return;
    if(calibration.is_object()){
        const auto kind=calibration.value("kind",std::string("black"));
        if(kind!="grid"){
            glViewport(0,0,width,height);glDisable(GL_DEPTH_TEST);glDisable(GL_STENCIL_TEST);glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);
            glEnable(GL_SCISSOR_TEST);glScissor(0,0,width,height);
            const float level=kind=="white"?std::clamp(calibration.value("brightness",100.f)/100.f,0.f,1.f):0.f;
            glClearColor(level,level,level,1);glClear(GL_COLOR_BUFFER_BIT);
            if(kind=="gray"){
                bool x=calibration.value("axis",std::string("x"))=="x",inverse=calibration.value("inverse",false);
                int size=x?width:height,cell=std::clamp(calibration.value("cell",4),1,64),bit=std::clamp(calibration.value("bit",0),0,15);
                glClearColor(1,1,1,1);for(int pos=0;pos<size;pos+=cell){int index=pos/cell;if(bool(((index^(index>>1))>>bit)&1)==inverse)continue;int count=std::min(cell,size-pos);if(x)glScissor(pos,0,count,height);else glScissor(0,height-pos-count,width,count);glClear(GL_COLOR_BUFFER_BIT);}
            }
            glDisable(GL_SCISSOR_TEST);return;
        }
        json rects=json::array();for(const auto& card:calibration.value("cards",json::array())){
            const auto h=card.at("unitToProjector").get<std::vector<double>>();if(h.size()!=9)continue;json corners=json::array();
            for(auto uv:std::array<std::array<double,2>,4>{{{{0,0}},{{1,0}},{{1,1}},{{0,1}}}}){double z=h[6]*uv[0]+h[7]*uv[1]+h[8];corners.push_back({(h[0]*uv[0]+h[1]*uv[1]+h[2])/z/width,(h[3]*uv[0]+h[4]*uv[1]+h[5])/z/height});}
            rects.push_back({{"id",std::to_string(rects.size())},{"source","out1"},{"corners",corners},{"uvs",{{0,1},{1,1},{1,0},{0,0}}},{"mode","grid"},{"graphic","grid"},{"config",{{"color","#00ff00"},{"thickness",3}}}});
        }
        impl_->render({{"rects",rects}},width,height,lookup,traces);return;
    }
    impl_->render(mapping,width,height,lookup,traces,ignoreOutputRotation,graph);
}
}

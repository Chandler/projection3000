#include "trace_render_geometry.hpp"
#include <algorithm>
#include <array>
#include <cmath>
namespace vj {
std::vector<TraceGpuVertex> traceRenderGeometry(const nlohmann::json& trace,const std::vector<std::uint8_t>& rgb,int width,int height,int rotation){
    using Point=std::array<float,2>;std::vector<TraceGpuVertex> result;
    if(width<1||height<1||!trace.value("enabled",true)||!trace.contains("points")||!trace["points"].is_array())return result;
    std::vector<Point> points;
    for(const auto& p:trace["points"]){if(!p.is_array()||p.size()!=2||!p[0].is_number()||!p[1].is_number())continue;float x=p[0],y=p[1];if(std::isfinite(x)&&std::isfinite(y))points.push_back({std::clamp(x,0.f,1.f),std::clamp(y,0.f,1.f)});}
    if(points.size()<2)return result;
    std::vector<float> cumulative(points.size(),0);
    for(size_t i=1;i<points.size();++i)cumulative[i]=cumulative[i-1]+std::hypot(points[i][0]-points[i-1][0],points[i][1]-points[i-1][1]);
    const float total=cumulative.back();if(total<=.000001f)return result;
    auto pointAt=[&](float fraction){float distance=std::clamp(fraction,0.f,1.f)*total;size_t end=std::clamp<size_t>(std::upper_bound(cumulative.begin(),cumulative.end(),distance)-cumulative.begin(),1,points.size()-1),start=end-1;float span=cumulative[end]-cumulative[start],t=span>.000001f?(distance-cumulative[start])/span:0;Point p={points[start][0]+(points[end][0]-points[start][0])*t,points[start][1]+(points[end][1]-points[start][1])*t};
        const float x=p[0],y=p[1];switch((rotation%360+360)%360){case 90:p={1-y,x};break;case 180:p={1-x,1-y};break;case 270:p={y,1-x};break;}return Point{p[0]*width,p[1]*height};};
    const int pixels=std::clamp(trace.value("pixels",60),2,2000);
    const float normalized=std::clamp(trace.value("width",.015f),.001f,.2f),glow=std::clamp(trace.value("glow",.35f),0.f,1.f);
    const float coreWidth=std::max(.6f,normalized*height),glowWidth=normalized*(.25f+glow*.75f)*height;
    const float outer=std::max(coreWidth*.5f+1.5f,coreWidth*.5f+glowWidth*1.85f);
    result.reserve(pixels*6);
    for(int i=0;i<pixels;i++){
        size_t offset=i*3;if(offset+2>=rgb.size())continue;float r=rgb[offset]/255.f,g=rgb[offset+1]/255.f,b=rgb[offset+2]/255.f,brightness=std::max({r,g,b});if(brightness<=.001f)continue;
        auto a=pointAt(float(i)/pixels),z=pointAt(float(i+1)/pixels);float dx=z[0]-a[0],dy=z[1]-a[1],length=std::hypot(dx,dy);if(length<.01f)continue;
        float tx=dx/length,ty=dy/length,nx=-ty,ny=tx;
        const std::array<std::array<float,4>,4> corners={{{a[0]-tx*1.5f+nx*outer,a[1]-ty*1.5f+ny*outer,-1.5f,outer},{a[0]-tx*1.5f-nx*outer,a[1]-ty*1.5f-ny*outer,-1.5f,-outer},{z[0]+tx*1.5f+nx*outer,z[1]+ty*1.5f+ny*outer,length+1.5f,outer},{z[0]+tx*1.5f-nx*outer,z[1]+ty*1.5f-ny*outer,length+1.5f,-outer}}};
        for(int index:{0,1,2,1,3,2}){const auto& c=corners[index];TraceGpuVertex v={{c[0]/width*2-1,1-c[1]/height*2},{c[2],c[3],length},{r,g,b,brightness},{r*glow,g*glow,b*glow,brightness*glow},{coreWidth,glowWidth,1,1}};result.push_back(v);}
    }
    return result;
}
}

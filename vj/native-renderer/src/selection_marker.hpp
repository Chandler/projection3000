#pragma once
#include "surface_curvature.hpp"

namespace selection_marker {
// A small projector-space square centered on the warped surface, with no glow.
inline std::vector<surface_curvature::Point> square(
    const std::vector<surface_curvature::Point>& corners,
    const surface_curvature::Settings& curve, int width, int height, int rotation) {
    if(corners.empty()||width<=0||height<=0)return {};
    const double w=(rotation==90||rotation==270)?height:width;
    const double h=(rotation==90||rotation==270)?width:height;
    double x=0,y=0,minx=1e9,miny=1e9,maxx=-1e9,maxy=-1e9;
    for(const auto& p:corners){x+=p[0];y+=p[1];minx=std::min(minx,double(p[0]));miny=std::min(miny,double(p[1]));maxx=std::max(maxx,double(p[0]));maxy=std::max(maxy,double(p[1]));}
    x/=corners.size();y/=corners.size();
    if(const auto matrix=surface_curvature::quad_matrix(corners)){
        const auto p=surface_curvature::point(.5,.5,curve);const auto& m=*matrix;
        const double q=m[6]*p[0]+m[7]*p[1]+m[8];
        if(std::abs(q)<1e-9)return {};
        x=(m[0]*p[0]+m[1]*p[1]+m[2])/q;y=(m[3]*p[0]+m[4]*p[1]+m[5])/q;
    }
    const double size=std::min(8.0,std::min((maxx-minx)*w,(maxy-miny)*h)*.15);
    if(!std::isfinite(x)||!std::isfinite(y)||size<1)return {};
    const float dx=size/2/w,dy=size/2/h;
    return {{{float(x)-dx,float(y)-dy},{float(x)+dx,float(y)-dy},
             {float(x)+dx,float(y)+dy},{float(x)-dx,float(y)+dy}}};
}
}

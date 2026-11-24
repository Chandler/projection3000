#pragma once
#include "surface_curvature.hpp"
namespace rounded_surface {
using surface_curvature::Point;
inline std::vector<Point> outline(const std::vector<Point>& p,
    const surface_curvature::Settings& curve, double radius, double aspect) {
    const auto h=surface_curvature::quad_matrix(p);
    if(!h || radius<=0)return p;
    auto edge=[&](int a,int b){return std::hypot((p[a][0]-p[b][0])*aspect,p[a][1]-p[b][1]);};
    const double w=(edge(0,1)+edge(3,2))/2,height=(edge(0,3)+edge(1,2))/2;
    if(std::min(w,height)<1e-9)return p;
    const double r=std::clamp(radius,0.0,.5)*std::min(w,height),rx=r/w,ry=r/height;
    const std::array<std::array<double,2>,4> centers{{{1-rx,ry},{1-rx,1-ry},{rx,1-ry},{rx,ry}}};
    std::vector<Point> result;
    auto append=[&](double u,double v){
        const auto xy=surface_curvature::point(u,v,curve);
        const auto& m=*h;const double q=m[6]*xy[0]+m[7]*xy[1]+m[8];
        result.push_back({float((m[0]*xy[0]+m[1]*xy[1]+m[2])/q),float((m[3]*xy[0]+m[4]*xy[1]+m[5])/q)});
    };
    constexpr double pi=3.14159265358979323846;
    for(int corner=0;corner<4;corner++){
        const double angle=(corner-1)*pi/2;
        const auto center=centers[corner];
        for(int step=0;step<=16;step++){
            const double a=angle+step/16.0*pi/2;
            append(center[0]+rx*std::cos(a),center[1]+ry*std::sin(a));
        }
        const double a=angle+pi/2;
        const auto next=centers[(corner+1)%4];
        for(int step=1;step<16;step++){
            const double t=step/16.0;
            append(center[0]+rx*std::cos(a)+(next[0]-center[0])*t,
                   center[1]+ry*std::sin(a)+(next[1]-center[1])*t);
        }
    }
    return result;
}

// The circle inscribed in a hemisphere surface's unit square, shrunk by its inset.
inline std::vector<Point> ellipse_outline(const std::vector<Point>& p,
    const surface_curvature::Settings& curve, double inset) {
    const auto h=surface_curvature::quad_matrix(p);
    if(!h)return p;
    constexpr double pi=3.14159265358979323846;
    const double r=.5*(1-std::clamp(inset,0.0,.5));
    std::vector<Point> result;
    for(int step=0;step<96;step++){
        const double a=step*2*pi/96;
        const auto xy=surface_curvature::point(.5+r*std::cos(a),.5+r*std::sin(a),curve);
        const auto& m=*h;const double q=m[6]*xy[0]+m[7]*xy[1]+m[8];
        result.push_back({float((m[0]*xy[0]+m[1]*xy[1]+m[2])/q),float((m[3]*xy[0]+m[4]*xy[1]+m[5])/q)});
    }
    return result;
}

// Ear clipping also handles rounded outlines bent inward by curvature.
inline std::vector<Point> triangles(const std::vector<Point>& outline) {
    // A fully rounded square (radius .5) has zero-length straight edges whose repeated
    // points stall ear clipping and leave a hole; drop them first.
    std::vector<Point> p;
    for(const auto& q:outline)if(p.empty()||std::hypot(q[0]-p.back()[0],q[1]-p.back()[1])>1e-7)p.push_back(q);
    while(p.size()>1&&std::hypot(p.front()[0]-p.back()[0],p.front()[1]-p.back()[1])<=1e-7)p.pop_back();
    std::vector<unsigned> remaining;std::vector<Point> result;
    double area=0;
    for(unsigned i=0;i<p.size();i++){remaining.push_back(i);const auto& b=p[(i+1)%p.size()];area+=p[i][0]*b[1]-p[i][1]*b[0];}
    const double sign=area>=0?1:-1;
    auto cross=[](Point a,Point b,Point c){return double(b[0]-a[0])*(c[1]-a[1])-double(b[1]-a[1])*(c[0]-a[0]);};
    while(remaining.size()>2){
        bool found=false;
        for(unsigned i=0;i<remaining.size();i++){
            const unsigned a=remaining[(i+remaining.size()-1)%remaining.size()],b=remaining[i],c=remaining[(i+1)%remaining.size()];
            if(sign*cross(p[a],p[b],p[c])<=1e-12)continue;
            bool occupied=false;
            for(auto j:remaining){if(j==a||j==b||j==c)continue;
                if(sign*cross(p[a],p[b],p[j])>1e-12&&sign*cross(p[b],p[c],p[j])>1e-12&&sign*cross(p[c],p[a],p[j])>1e-12){occupied=true;break;}}
            if(occupied)continue;
            result.insert(result.end(),{p[a],p[b],p[c]});remaining.erase(remaining.begin()+i);found=true;break;
        }
        if(!found)break; // collinear final vertices have no area
    }
    return result;
}
}

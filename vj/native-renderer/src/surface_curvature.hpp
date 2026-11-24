#pragma once
#include <array>
#include <algorithm>
#include <limits>
#include <cmath>
#include <optional>
#include <vector>

namespace surface_curvature {
using Point=std::array<float,2>;
using Matrix=std::array<double,9>;
struct Pin { int side=0; double t=0.5; std::array<double,2> target{}; bool enabled=true; };
struct Spline { std::vector<std::array<double,3>> nodes; std::vector<std::array<double,2>> second; };
struct Settings {
    double top=0,right=0,bottom=0,left=0,wrap_x=0,wrap_y=0;
    double spacing_x=0,spacing_y=0;
    std::array<double,4> skew{},shape{}; // top, right, bottom, left
    bool pins_enabled=true, local_pins=false;
    std::vector<Pin> pins;
    std::array<Spline,4> splines;
    bool active() const {
        if(pins_enabled)for(const auto& p:pins)if(p.enabled)return true;
        if(top||right||bottom||left||wrap_x||wrap_y||spacing_x||spacing_y)return true;
        for(int i=0;i<4;i++)if(skew[i]||shape[i])return true;
        return false;
    }
};
constexpr int steps=32;
inline std::optional<Matrix> quad_matrix(const std::vector<Point>& p) {
    if(p.size()!=4)return std::nullopt;
    const auto &a=p[0],&b=p[1],&c=p[2],&d=p[3];
    const double x1=b[0]-c[0],y1=b[1]-c[1],x2=d[0]-c[0],y2=d[1]-c[1];
    const double x3=double(a[0])-b[0]+c[0]-d[0],y3=double(a[1])-b[1]+c[1]-d[1];
    double g=0,h=0;
    if(std::abs(x3)+std::abs(y3)>=1e-12){
        const double det=x1*y2-x2*y1;if(std::abs(det)<1e-12)return std::nullopt;
        g=(x3*y2-x2*y3)/det;h=(x1*y3-x3*y1)/det;
    }
    return Matrix{b[0]-a[0]+g*b[0],d[0]-a[0]+h*d[0],a[0],
        b[1]-a[1]+g*b[1],d[1]-a[1]+h*d[1],a[1],g,h,1};
}
inline double arc(double t,double degrees){
    if(degrees==0)return t;
    const double angle=degrees*3.14159265358979323846/180;
    return .5+std::sin((t-.5)*angle)/(2*std::sin(angle/2));
}
inline double profile(double t,double degrees){
    if(degrees<.01)return 4*t*(1-t);
    const double angle=degrees*3.14159265358979323846/180;
    return (std::cos((t-.5)*angle)-std::cos(angle/2))/(1-std::cos(angle/2));
}
inline double spacing_parameter(double t,double bias){
    if(bias==0||t==0||t==1)return t;
    return std::expm1(bias*t)/std::expm1(bias);
}
inline double inverse_spacing(double t,double bias){
    if(bias==0||t==0||t==1)return t;
    return std::log1p(t*std::expm1(bias))/bias;
}
inline double edge_bend(double t,double degrees,double amount,double skew,double shape){
    const double z=2*t-1;
    return amount*profile(t,degrees)*std::exp(2*skew*z+2*shape*z*z);
}
inline std::array<double,2> base_point(double u,double v,const Settings& c){
    const double x=arc(u,c.wrap_x),y=arc(v,c.wrap_y);
    return {x+edge_bend(v,c.wrap_y,c.right,c.skew[1],c.shape[1])*x-edge_bend(v,c.wrap_y,c.left,c.skew[3],c.shape[3])*(1-x),
        y+edge_bend(u,c.wrap_x,c.bottom,c.skew[2],c.shape[2])*y-edge_bend(u,c.wrap_x,c.top,c.skew[0],c.shape[0])*(1-y)};
}
inline std::array<double,2> pin_uv(int side,double t){
    if(side==0)return {t,0};if(side==1)return {1,t};if(side==2)return {t,1};return {0,t};
}
inline Spline make_spline(std::vector<std::array<double,3>> nodes){
    Spline s;s.nodes=std::move(nodes);const int n=s.nodes.size();s.second.resize(n);
    for(int k=0;k<2;k++){
        std::vector<double> upper(n),rhs(n);
        for(int i=1;i<n-1;i++){
            const double a=s.nodes[i][0]-s.nodes[i-1][0],b=s.nodes[i+1][0]-s.nodes[i][0],d=2*(a+b)-a*upper[i-1];
            upper[i]=b/d;rhs[i]=(6*((s.nodes[i+1][k+1]-s.nodes[i][k+1])/b-(s.nodes[i][k+1]-s.nodes[i-1][k+1])/a)-a*rhs[i-1])/d;
        }
        for(int i=n-2;i>0;i--)s.second[i][k]=rhs[i]-upper[i]*s.second[i+1][k];
    }
    return s;
}
inline std::array<double,2> sample_spline(const Spline& s,double t){
    if(s.nodes.empty())return {0,0};size_t i=0;
    while(i<s.nodes.size()-2&&t>s.nodes[i+1][0])i++;
    const double h=s.nodes[i+1][0]-s.nodes[i][0],a=(s.nodes[i+1][0]-t)/h,b=(t-s.nodes[i][0])/h;
    std::array<double,2> out{};
    for(int k=0;k<2;k++)out[k]=a*s.nodes[i][k+1]+b*s.nodes[i+1][k+1]+((a*a*a-a)*s.second[i][k]+(b*b*b-b)*s.second[i+1][k])*h*h/6;
    return out;
}
inline void prepare_pins(Settings& c){
    if(!c.pins_enabled)return;
    for(int side=0;side<4;side++){
        std::vector<Pin> edge;for(const auto& p:c.pins)if(p.enabled&&p.side==side)edge.push_back(p);
        if(edge.empty())continue;
        std::sort(edge.begin(),edge.end(),[](const Pin& a,const Pin& b){return a.t<b.t;});
        double* amount=side==0?&c.top:side==1?&c.right:side==2?&c.bottom:&c.left;
        if(c.local_pins){
            std::vector<std::array<double,3>> nodes{{0,0,0}};
            for(const auto& p:edge){const auto uv=pin_uv(side,p.t),q=base_point(uv[0],uv[1],c);nodes.push_back({p.t,p.target[0]-q[0],p.target[1]-q[1]});}
            nodes.push_back({1,0,0});c.splines[side]=make_spline(std::move(nodes));continue;
        }
        const std::array<double,3> base{*amount,c.skew[side],c.shape[side]};
        const double reg=1e-6*edge.size(),degrees=side==0||side==2?c.wrap_x:c.wrap_y;
        auto evaluate=[&](double skew,double shape){
            std::vector<double> f,y;double num=reg*base[0],den=reg;
            for(const auto& p:edge){const double z=2*p.t-1,a=profile(p.t,degrees)*std::exp(2*skew*z+2*shape*z*z);
                const double b=side==0?-p.target[1]:side==2?p.target[1]-1:side==3?-p.target[0]:p.target[0]-1;
                f.push_back(a);y.push_back(b);num+=a*b;den+=a*a;}
            const double a=std::clamp(num/den,-2.0,2.0);
            double cost=reg*(a-base[0])*(a-base[0])+reg*.1*((skew-base[1])*(skew-base[1])+(shape-base[2])*(shape-base[2]));
            for(size_t i=0;i<f.size();i++)cost+=(a*f[i]-y[i])*(a*f[i]-y[i]);
            return std::array<double,4>{cost,a,skew,shape};
        };
        auto best=evaluate(base[1],base[2]);
        auto consider=[&](double skew,double shape){const auto next=evaluate(std::clamp(skew,-1.0,1.0),std::clamp(shape,-1.0,1.0));if(next[0]<best[0])best=next;};
        for(int i=0;i<=8;i++)for(int j=0;j<=8;j++)consider(-1+i/4.0,-1+j/4.0);
        for(double step=.125;step>=.0009765625;step/=2){const double skew=best[2],shape=best[3];for(int i=-1;i<=1;i++)for(int j=-1;j<=1;j++)consider(skew+i*step,shape+j*step);}
        *amount=best[1];c.skew[side]=best[2];c.shape[side]=best[3];
    }
}
inline std::array<double,2> point(double u,double v,const Settings& c){
    auto p=base_point(u,v,c);
    if(c.pins_enabled&&c.local_pins){
        const auto top=sample_spline(c.splines[0],u),right=sample_spline(c.splines[1],v),bottom=sample_spline(c.splines[2],u),left=sample_spline(c.splines[3],v);
        for(int k=0;k<2;k++)p[k]+=(1-v)*top[k]+v*bottom[k]+(1-u)*left[k]+u*right[k];
    }
    return p;
}
inline std::array<std::vector<double>,2> pin_axes(const Settings& c){
    std::array<std::vector<double>,2> axes;
    for(int axis=0;axis<2;axis++){
        std::vector<double> knots;
        if(c.pins_enabled)for(const auto& p:c.pins)if(p.enabled&&(p.side==0||p.side==2?0:1)==axis)knots.push_back(p.t);
        std::vector<double> values=knots;
        for(int i=0;i<=steps;i++){
            const double t=double(i)/steps;
            if(std::none_of(knots.begin(),knots.end(),[&](double k){return std::abs(t-k)<1e-5;}))values.push_back(t);
        }
        std::sort(values.begin(),values.end());
        for(size_t i=0;i<values.size();i++)if(!i||values[i]-values[i-1]>=1e-5)axes[axis].push_back(values[i]);
    }
    return axes;
}
inline std::array<double,2> source_point(double u,double v,const Settings& c){
    return point(spacing_parameter(u,c.spacing_x),spacing_parameter(v,c.spacing_y),c);
}
struct Mesh {
    std::vector<Point> points;
    std::vector<std::array<float,3>> uvqs;
    std::vector<unsigned int> indices;
};
inline std::optional<Mesh> build(const std::vector<Point>& corners,const std::vector<Point>& uvs,const Settings& c){
    const auto h=quad_matrix(corners),t=quad_matrix(uvs);
    if(!h||!t)return std::nullopt;
    Mesh mesh;
    const auto axes=pin_axes(c);const auto& us=axes[0];const auto& vs=axes[1];
    for(double v:vs)for(double u:us){
        const auto p=point(u,v,c);const double x=p[0],y=p[1];
        const double su=inverse_spacing(u,c.spacing_x),sv=inverse_spacing(v,c.spacing_y);
        const double q=(*h)[6]*x+(*h)[7]*y+1,tq=(*t)[6]*su+(*t)[7]*sv+1;
        if(q<=1e-8||tq<=1e-8)return std::nullopt;
        mesh.points.push_back({float(((*h)[0]*x+(*h)[1]*y+(*h)[2])/q),float(((*h)[3]*x+(*h)[4]*y+(*h)[5])/q)});
        mesh.uvqs.push_back({float(((*t)[0]*su+(*t)[1]*sv+(*t)[2])/q),float(((*t)[3]*su+(*t)[4]*sv+(*t)[5])/q),float(tq/q)});
    }
    int winding=0;
    for(size_t row=0;row<vs.size()-1;row++)for(size_t col=0;col<us.size()-1;col++){
        const unsigned int n=us.size(),a=row*n+col;
        for(const auto tri:std::array<std::array<unsigned int,3>,2>{{{{a,a+1,a+n+1}},{{a,a+n+1,a+n}}}}){
            const auto &p=mesh.points[tri[0]],&q=mesh.points[tri[1]],&r=mesh.points[tri[2]];
            const double cross=double(q[0]-p[0])*(r[1]-p[1])-double(q[1]-p[1])*(r[0]-p[0]);
            const int sign=cross>0?1:-1;
            if(!std::isfinite(cross)||std::abs(cross)<1e-12||(winding&&winding!=sign))return std::nullopt;
            winding=sign;mesh.indices.insert(mesh.indices.end(),tri.begin(),tri.end());
        }
    }
    return mesh;
}
} // namespace surface_curvature

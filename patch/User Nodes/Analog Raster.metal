#include <metal_stdlib>
using namespace metal;
struct RasterUniforms { float4 scan; float4 levels; float4 style; float4 color; };
float wave(const device float2 *p, float phase, uint channel, uint count) {
    float f=fract(phase)*float(count); uint a=uint(f)%count,b=(a+1)%count;
    return mix(p[a][channel],p[b][channel],fract(f));
}
kernel void analogRaster(texture2d<float,access::write> out [[texture(0)]],
                         const device float2 *p [[buffer(0)]],
                         constant RasterUniforms &u [[buffer(1)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=out.get_width() || pos.y>=out.get_height())return;
    uint n=uint(u.scan.w);
    if(n<2){out.write(float4(0,0,0,1),pos);return;}
    float2 uv=(float2(pos)+0.5)/float2(out.get_width(),out.get_height())-0.5;
    float a=u.style.z,c=cos(a),s=sin(a); uv=float2(c*uv.x-s*uv.y,s*uv.x+c*uv.y)+0.5;
    float x=uv.x*u.scan.x+u.scan.z,y=uv.y*u.scan.y-u.scan.z*0.71;
    float wx=tanh(wave(p,x,0,n)*u.levels.x),wy=tanh(wave(p,y,1,n)*u.levels.y);
    float v;
    if(u.style.x<0.5)v=(wx+wy)*0.5;
    else if(u.style.x<1.5)v=wx*wy;
    else if(u.style.x<2.5)v=sin((wx+wy)*u.style.y*3.14159265);
    else v=tanh(wave(p,x+wy*u.levels.z,0,n)*u.levels.x);
    if(u.style.x<2.5 && u.levels.z>0) {
        float cross=tanh(wave(p,x+wy*u.levels.z,0,n)*u.levels.x)*tanh(wave(p,y+wx*u.levels.z,1,n)*u.levels.y);
        v=mix(v,cross,min(u.levels.z,1.0)*0.6);
    }
    float value=clamp(0.5+0.5*tanh(v*u.levels.w),0.0,1.0);
    float hue=u.color.x+0.17*(wx-wy);
    float3 rgb=clamp(abs(fract(hue+float3(0,2.0/3.0,1.0/3.0))*6.0-3.0)-1.0,0.0,1.0);
    rgb=mix(float3(1),rgb,u.color.y)*value*u.color.z;
    if(u.style.x>3.5) {
        float3 left=clamp(abs(fract(u.color.x+float3(0,2.0/3.0,1.0/3.0))*6.0-3.0)-1.0,0.0,1.0);
        float3 right=clamp(abs(fract(u.color.w+float3(0,2.0/3.0,1.0/3.0))*6.0-3.0)-1.0,0.0,1.0);
        float lx=0.5+0.5*tanh(wx*u.levels.w),ry=0.5+0.5*tanh(wy*u.levels.w);
        float3 l=mix(float3(1),left,u.color.y)*lx;
        float3 r=mix(float3(1),right,u.color.y)*ry;
        rgb=(1.0-(1.0-l)*(1.0-r))*u.color.z;
    }
    out.write(float4(clamp(rgb,0.0,1.0),1),pos);
}

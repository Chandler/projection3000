#include <metal_stdlib>
using namespace metal;
struct ProfileParams {float4 signal;float4 oscillator;float4 slots;};
// W RGB column averages followed by H RGB row averages. All work stays on GPU.
kernel void profileExtract(texture2d<float,access::read> src [[texture(0)]],device float4 *profiles [[buffer(0)]],uint i [[thread_position_in_grid]]) {
    uint w=src.get_width(),h=src.get_height(); if(i>=w+h)return;
    float3 sum=0;
    if(i<w){for(uint y=0;y<h;y++)sum+=src.read(uint2(i,y)).rgb;sum/=float(h);}
    else{for(uint x=0;x<w;x++)sum+=src.read(uint2(x,i-w)).rgb;sum/=float(w);}
    profiles[i]=float4(sum,0);
}
kernel void profileMean(const device float4 *p [[buffer(0)]],device float4 *mean [[buffer(1)]],constant uint &width [[buffer(2)]],uint i [[thread_position_in_grid]]) {
    if(i)return;float3 sum=0;for(uint x=0;x<width;x++)sum+=p[x].rgb;mean[0]=float4(sum/float(width),0);
}
float3 readProfile(const device float4 *p,uint offset,uint count,float pos) {
    float f=fract(pos)*float(count);uint lo=uint(f)%count;return mix(p[offset+lo].rgb,p[offset+(lo+1)%count].rgb,fract(f));
}
kernel void profileProcess(const device float4 *src [[buffer(0)]],device float4 *dst [[buffer(1)]],const device float4 *mean [[buffer(2)]],constant uint2 &size [[buffer(3)]],constant ProfileParams &u [[buffer(4)]],uint i [[thread_position_in_grid]]) {
    if(i>=size.x+size.y)return;
    if(u.slots.z==0){dst[i]=src[i];return;}
    bool vertical=i>=size.x;uint offset=vertical?size.x:0,count=vertical?size.y:size.x,index=i-offset;
    float pos=float(index)/float(count)+u.signal.w;
    int radius=int(u.oscillator.w);float3 filtered=0;float weight=0;
    for(int j=-radius;j<=radius;j++){float k=float(radius+1-abs(j));filtered+=readProfile(src,offset,count,pos+float(j)/count)*k;weight+=k;}
    filtered=filtered/weight-mean[0].rgb;
    float3 shaped=filtered*u.signal.x+u.signal.z;
    if(u.signal.y>0)shaped=tanh(shaped*u.signal.y)/u.signal.y;
    float osc=sin(6.2831853*(pos*u.oscillator.x+u.slots.w+(vertical?0.25:0)))*u.oscillator.y;
    shaped=mix(shaped,float3(osc),u.oscillator.z)+mean[0].rgb;
    float3 original=src[i].rgb;
    for(uint c=0;c<3;c++) {
        uint channel=c+(vertical?3:0);
        if(channel==uint(u.slots.x)||channel==uint(u.slots.y))original[c]=mix(original[c],shaped[c],u.slots.z);
    }
    dst[i]=float4(original,0);
}
kernel void profileDecode(texture2d<float,access::sample> src [[texture(0)]],texture2d<float,access::write> out [[texture(1)]],const device float4 *base [[buffer(0)]],const device float4 *current [[buffer(1)]],const device float4 *mean [[buffer(2)]],constant uint2 &size [[buffer(3)]],constant float2 &controls [[buffer(4)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=out.get_width()||p.y>=out.get_height())return;
    float2 uv=(float2(p)+0.5)/float2(out.get_width(),out.get_height());
    constexpr sampler s(coord::normalized,filter::nearest,address::clamp_to_edge);
    uint x=min(uint(uv.x*size.x),size.x-1),y=min(uint(uv.y*size.y),size.y-1);
    float4 original=src.sample(s,uv);float3 rgb=original.rgb;
    int mode=int(controls.x);
    if(mode==0 || (mode==2 && uv.x>=0.5))rgb+=(current[x].rgb-base[x].rgb+current[size.x+y].rgb-base[size.x+y].rgb)*controls.y;
    if(mode==3)rgb=original.rgb-base[x].rgb-base[size.x+y].rgb+mean[0].rgb+0.5;
    if(mode==4) {
        uint lane=min(uint(uv.y*6),5u),c=lane%3,offset=lane<3?0:size.x,count=lane<3?size.x:size.y;
        uint index=min(uint(uv.x*count),count-1);
        float local=fract(uv.y*6),v=current[offset+index][c]-mean[0][c],b=base[offset+index][c]-mean[0][c];
        float thickness=9.0/out.get_height();
        float line=1-smoothstep(thickness,thickness*2,abs(local-(0.5-v*0.8)));
        float reference=1-smoothstep(thickness,thickness*2,abs(local-(0.5-b*0.8)));
        float3 ink=c==0?float3(1,0.25,0.2):c==1?float3(0.2,1,0.4):float3(0.3,0.5,1);
        rgb=float3(0.025)+reference*0.2+ink*line;
    }
    if(mode==2 && abs(uv.x-0.5)<1.0/out.get_width())rgb=1;
    out.write(float4(clamp(rgb,0.0,1.0),original.a),p);
}

#pragma once
#ifdef __cplusplus
static constexpr char patchMappedSurfaceMSL[]=R"METAL(
struct SurfaceUniforms {
    float4 tintBrightness,stroke,pulse,animation,flow,sphere,pose,rotation;
};
float surfacePulse(float distance,constant SurfaceUniforms& u) {
    if(u.stroke.w==0)return 1;
    if(distance<0)return mix(1.f,.12f,u.pulse.w);
    const float duration=u.animation.y/max(.01f,u.pulse.x)+1.f/max(.1f,u.pulse.y);
    if(u.animation.z==1 || (u.animation.z==2 && fmod(floor(u.animation.x/duration),2.f)>.5f))distance=u.animation.y-distance;
    const float phase=fract((u.animation.x-distance/max(.01f,u.pulse.x))*u.pulse.y);
    const float d=min(phase,1.f-phase)/max(.01f,u.pulse.z);
    const float flicker=fract(sin(floor(u.animation.x*30.f)+floor(distance*80.f)*12.9898f)*43758.5453f);
    return mix(1.f,.12f+.88f*exp(-4.f*d*d)*mix(1.f,.2f+.8f*flicker,u.animation.w),u.pulse.w);
}
float lineCoverage(float3 uv, float thickness) {
    float d=length(float2(max(max(-uv.x,uv.x-uv.z),0.f),uv.y));
    return 1.f-smoothstep(max(0.f,thickness*.5f-.65f),thickness*.5f+.65f,d);
}
fragment float4 mappedBoxEdges(MappedVertexOut in [[stage_in]],constant SurfaceUniforms& u [[buffer(0)]],constant MappedBlend& blend [[buffer(2)]]) {
    return mappedColor(float4(u.tintBrightness.rgb,lineCoverage(in.uv,u.stroke.x)*u.tintBrightness.w),blend);
}
fragment float4 mappedTriangulate(MappedVertexOut in [[stage_in]],constant SurfaceUniforms& u [[buffer(0)]],constant MappedBlend& blend [[buffer(2)]]) {
    float d=length(float2(max(max(-in.uv.x,in.uv.x-in.uv.z),0.f),in.uv.y));
    float halo=u.stroke.y>0?u.stroke.z*exp(-3.f*d*d/(u.stroke.y*u.stroke.y)):0;
    float along=clamp(in.uv.x/max(in.uv.z,.001f),0.f,1.f)*in.graph.z;
    float route=in.graph.x<0?-1.f:min(in.graph.x+along,in.graph.y+in.graph.z-along);
    return mappedColor(float4(u.tintBrightness.rgb,max(lineCoverage(in.uv,u.stroke.x),halo)*surfacePulse(route,u)),blend);
}
fragment float4 mappedWaterfall(MappedVertexOut in [[stage_in]],constant SurfaceUniforms& u [[buffer(0)]],constant MappedBlend& blend [[buffer(2)]]) {
    float3 w=float3(in.uv.x,in.graph.x,in.uv.y)/in.uv.z;
    float top=clamp(in.graph.y/in.uv.z,0.f,1.f);
    float phase=w.y+.24f*w.x+.13f*w.z+u.animation.x*u.sphere.x;
    float bend=sin(w.y*7.f+u.animation.x*1.3f)*u.flow.w*.09f;
    float stripes=sin((w.x+w.z*.71f+bend)*u.flow.x*6.28318f);
    float streams=smoothstep(1.f-u.flow.y*2.f,1.f,stripes);
    float wave=pow(.5f+.5f*sin(phase*18.f),5.f);
    float ripples=.5f+.5f*sin((w.x+w.z)*19.f+phase*8.f);
    float foam=u.flow.z*wave*mix(.2f,.9f,top);
    float water=(.08f+streams*(.3f+.5f*wave)+top*ripples*.15f)*u.tintBrightness.w;
    return mappedColor(float4(mix(u.tintBrightness.rgb*water,float3(u.tintBrightness.w),clamp(foam,0.f,1.f)),in.graph.z),blend);
}
fragment float4 mappedSphere(MappedVertexOut in [[stage_in]],constant SurfaceUniforms& u [[buffer(0)]],constant MappedBlend& blend [[buffer(2)]]) {
    float3 d=normalize(float3(in.uv.xy/in.uv.z,in.graph.x/in.uv.z));
    float3 angles=-(u.pose.xyz+u.animation.x*u.rotation.xyz),c=cos(angles),s=sin(angles);
    d.xy=float2(c.z*d.x-s.z*d.y,s.z*d.x+c.z*d.y);
    d.xz=float2(c.y*d.x+s.y*d.z,-s.y*d.x+c.y*d.z);
    d.yz=float2(c.x*d.y-s.x*d.z,s.x*d.y+c.x*d.z);
    float energy=0;
    int count=clamp(int(round(u.sphere.y)),1,32);
    for(int i=0;i<count;++i){
        float lane=(fract(sin((i+1.f)*127.1f)*43758.5453f)*2.f-1.f)*u.sphere.w;
        float phase=u.animation.x*u.sphere.x*6.2831853f+i*6.2831853f/count;
        float behind=fract((phase-atan2(d.z,d.x))/6.2831853f)*6.2831853f;
        float tailSpan=max(.001f,u.sphere.z*6.2831853f);
        float progress=clamp(behind/tailSpan,0.f,1.f);
        float fade=1.f-clamp((progress-u.pose.w)/max(.001f,1.f-u.pose.w),0.f,1.f);
        float tail=mix(1.f,fade,u.rotation.w)*(1.f-smoothstep(tailSpan-.002f,tailSpan+.002f,behind));
        float head=1.f-step(max(.0005f,tailSpan*.01f),behind);
        energy=max(energy,(1.f-step(u.flow.y,abs(d.y-lane)))*max(tail,head)*u.tintBrightness.w);
    }
    return mappedColor(float4(u.tintBrightness.rgb*u.tintBrightness.w,clamp(energy,0.f,1.f)),blend);
}
struct FaceUniforms { float4 clock,style,field; };
uint mappedFaceHash(uint x){x^=x>>16;x*=0x7feb352du;x^=x>>15;x*=0x846ca68bu;return x^(x>>16);}
int faceModulo(int a,int b){return (a%b+b)%b;}
int flashIndex(int pattern,int tick,int face,int count,int colors,uint seed){
    if(pattern==3||pattern==5)return int(mappedFaceHash(uint(tick)*131u+uint(face)*977u+seed*101u)%uint(colors));
    if(pattern==1)return faceModulo(tick,colors);
    if(pattern==2)return faceModulo(tick/count+face,colors);
    return faceModulo(tick+face,colors);
}
fragment float4 mappedFlashFaces(MappedVertexOut in [[stage_in]],constant FaceUniforms& u [[buffer(0)]],constant float4* palette [[buffer(1)]],constant MappedBlend& blend [[buffer(2)]]){
    if(u.field.z!=0 && length(in.uv.xy/in.uv.z*2.f-1.f)>1.f)discard_fragment();
    int face=int(round(in.graph.x)),count=max(1,int(u.field.x)),colors=max(1,int(u.field.y)),pattern=int(u.clock.y);
    uint seed=uint(u.clock.w);float phase=max(0.f,u.clock.x)*clamp(u.clock.z,0.f,16.f);
    if(pattern==3)phase+=float(mappedFaceHash(uint(face)+seed*101u)%65536u)/65536.f;
    if(pattern==4)phase-=float(face)/float(count);
    int tick=int(floor(phase));float fraction=fract(phase),on=clamp(u.style.x,.05f,1.f),fade=clamp(u.style.y,0.f,1.f);
    float level=fraction<on?1.f:0.f;
    if(fade>0&&on<1){float edge=on*.5f*fade;level=smoothstep(0.f,edge,fraction)*smoothstep(0.f,edge,on-fraction);}
    if(pattern==2&&faceModulo(tick,count)!=face)level=0;
    if(pattern==4)level*=.5f-.5f*cos(fraction*6.2831853f);
    level*=clamp(u.style.z,0.f,1.f);
    float3 a=palette[flashIndex(pattern,tick-1,face,count,colors,seed)].rgb;
    float3 b=palette[flashIndex(pattern,tick,face,count,colors,seed)].rgb;
    float3 rgb=mix(a,b,fade>0?smoothstep(0.f,fade*.5f,fraction):1.f);
    return mappedColor(u.field.w>0?float4(rgb,level):float4(rgb*level,1),blend);
}
fragment float4 mappedGlowFaces(MappedVertexOut in [[stage_in]],constant FaceUniforms& u [[buffer(0)]],constant float4* palette [[buffer(1)]],constant MappedBlend& blend [[buffer(2)]]){
    float2 p=in.uv.xy/in.uv.z*2.f-1.f;float r=dot(p,p);
    if(u.field.z!=0 && r>1)discard_fragment();
    float profile=u.field.z!=0?1.f-r:(1.f-p.x*p.x)*(1.f-p.y*p.y);
    float alpha=u.style.z*mix(1.f,pow(max(0.f,profile),u.style.y),u.style.x);
    return mappedColor(float4(palette[faceModulo(int(round(in.graph.x)),int(u.field.y))].rgb,alpha),blend);
}
)METAL";
extern "C" {
#endif
const char *PatchMappedSurfaceSource(void);
#ifdef __cplusplus
}
#endif

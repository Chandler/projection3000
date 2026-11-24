// A procedural brightness field, sampled directly at LED positions.
// a: rows, flow rate, packets, pulse length
// b: density, row variation, mask depth, mask scale
// c: mask speed, rising bands, flicker amount, flicker Hz
// d: seed, algorithm (0 packets / 1 waves / 2 drifting mask / 3 staggered pulses)
float dataHash(float2 p) { return fract(sin(dot(p,float2(127.1,311.7)))*43758.5453); }
float dataNoise(float2 p) {
    float2 i=floor(p),f=fract(p); f=f*f*(3-2*f);
    return mix(mix(dataHash(i),dataHash(i+float2(1,0)),f.x),mix(dataHash(i+float2(0,1)),dataHash(i+1),f.x),f.y);
}
float3 animation(float2 uv,float time,float4 a,float4 b,float4 c,float4 d) {
    float row=floor(uv.y*max(1.0,a.x)), seed=d.x;
    float random=dataHash(float2(row+seed,13));
    float flow=time*a.y*mix(1.0,0.3+random*1.5,b.y);
    float phase=uv.x*a.z-flow+random*5;
    float cell=floor(phase),fraction=fract(phase);
    float packet=step(1-b.x,dataHash(float2(cell+seed,row)));
    float tail=exp(-fraction/max(0.015,a.w*0.32));
    float signal=packet*tail*(0.2+0.8*dataHash(float2(cell,row+seed+63)));
    if(d.y>0.5 && d.y<1.5) {
        float wave=0.5+0.5*sin(uv.x*a.z*6.28318-time*a.y*4+sin(row*0.17+time)*2);
        signal=pow(wave,mix(12.0,1.2,a.w))*mix(0.2,1.0,b.x);
    } else if(d.y>1.5 && d.y<2.5) {
        float n=dataNoise(float2(uv.x*a.z-time*a.y*0.8,row*0.31)+seed);
        signal=smoothstep(1-b.x,1.0,n)*mix(0.2,1.0,0.5+0.5*sin(uv.x*18+time*4));
    } else if(d.y>2.5) {
        float p=fract(time*a.y*0.7+random*4+floor(uv.x*a.z)*0.09);
        signal=exp(-p/max(0.02,a.w*0.3))*step(1-b.x,dataHash(float2(row,floor(uv.x*a.z)+seed)));
    }
    float2 maskUV=float2(uv.x*b.w,uv.y*b.w*0.7+time*c.x*0.5);
    float cloud=dataNoise(maskUV+seed)+0.35*dataNoise(maskUV*2.7-time*c.x*0.3);
    float mask=smoothstep(0.28,0.85,cloud);
    if(c.y>0.01) {
        float band=abs(fract(uv.y*c.y+time*c.x*0.2)-0.5);
        mask*=smoothstep(0.07,0.23,band);
    }
    float flicker=dataHash(float2(floor(uv.x*112)+row*131+seed,floor(time*c.w)));
    signal*=mix(1.0,mask,b.z)*mix(1.0,flicker*1.6,c.z);
    return float3(clamp(signal,0.0,1.0));
}

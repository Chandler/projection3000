// Example 08: discrete row intervals and a bottom-up curtain, no sinusoidal blockers.
// Same control layout as Flow Blockers. Obstruction history is sampled at passage time.
float geometricHash(float2 p) { return fract(sin(dot(p,float2(127.1,311.7)))*43758.5453); }
float3 animation(float2 uv,float time,float4 a,float4 b,float4 c,float4 d) {
    float row=floor(uv.y*a.x),r=geometricHash(float2(row,d.x));
    float velocity=max(0.01,a.y)*mix(1.0,0.65+0.7*r,b.y);
    float entered=time-uv.x/velocity,launch=entered*a.z+r*13;
    float duty=clamp(a.w*(0.75+0.25*geometricHash(float2(row,floor(launch)+d.x))),0.01,1.0);
    float signal=step(1-b.x,geometricHash(float2(row+71,floor(launch)+d.x)))*(1-smoothstep(max(0.0,duty-0.035),duty,fract(launch)));
    for(int i=0;i<int(round(b.w));i++) {
        float seed=d.x+float(i)*31.17;
        float bx=i==0 ? 0.035 : 0.1+0.7*geometricHash(float2(seed,3));
        if(uv.x<bx) continue;
        float passed=time-(uv.x-bx)/velocity;
        float blocked=0;
        if(i==0) {
            // Build upwards, one row at a time, hold the whole display, then release.
            float phase=fract(passed*c.x/7.0+0.12);
            float count=phase<0.25 || phase>=0.7 ? 0 : floor(clamp((phase-0.25)/0.28,0.0,1.0)*a.x);
            blocked=step(a.x-count,row);
        } else {
            // Rectangular interruptions jump between positions and vary their height.
            float eventTime=passed*c.x*(0.45+0.65*geometricHash(float2(seed,7)));
            float event=floor(eventTime),phase=fract(eventTime);
            float active=step(0.18,phase)*step(phase,0.92)*step(0.15,geometricHash(float2(seed,event)));
            float height=1+floor(c.y*(0.25+2.75*geometricHash(float2(seed+5,event))));
            height=min(a.x,height);
            float first=floor(geometricHash(float2(seed+12,event))*max(1.0,a.x-height+1));
            if(geometricHash(float2(seed+25,event))>0.72) {
                // Some blocks accumulate upwards instead of simply switching on.
                height=min(a.x,floor(phase*a.x)); first=a.x-height;
            }
            blocked=active*step(first,row)*(1-step(first+height,row));
        }
        signal*=1-b.z*blocked;
    }
    float flicker=geometricHash(float2(row+d.x,floor(entered*c.w)));
    signal*=mix(1.0,0.55+0.45*flicker,c.z)*(0.45+0.45*r);
    return float3(signal);
}

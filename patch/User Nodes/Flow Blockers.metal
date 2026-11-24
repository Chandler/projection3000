// Advected gaps: evaluate each obstruction at the time this sample passed it.
// a: rows, flow speed, launch frequency, stream duty
// b: launch probability, row speed variation, block strength, blocker count
// c: blocker motion, blocker height in rows, brightness jitter, jitter Hz
// d.x: seed. Each field has an independent playback clock.
float blockerHash(float2 p) { return fract(sin(dot(p,float2(127.1,311.7)))*43758.5453); }
float3 animation(float2 uv,float time,float4 a,float4 b,float4 c,float4 d) {
    float row=floor(uv.y*a.x), y=(row+0.5)/a.x;
    float r=blockerHash(float2(row,d.x));
    float velocity=max(0.01,a.y)*mix(1.0,0.65+0.7*r,b.y);
    float entryTime=time-uv.x/velocity;
    float launch=entryTime*a.z+r*13;
    float event=floor(launch), phase=fract(launch);
    float duty=clamp(a.w*(0.7+0.3*blockerHash(float2(row,event+d.x))),0.01,1.0);
    float feed=step(1-b.x,blockerHash(float2(row+71,event+d.x)));
    // Finite runs have a crisp leading edge and a short fade at the tail.
    float signal=feed*(1-smoothstep(max(0.0,duty-0.06),duty,phase));
    for(int i=0;i<int(round(b.w));i++) {
        float seed=d.x+float(i)*31.17;
        float bx=0.08+0.77*blockerHash(float2(seed,3));
        if(uv.x<bx) continue;
        float passed=time-(uv.x-bx)/velocity;
        float p=blockerHash(float2(seed,8))*6.28318;
        float by=0.5+0.57*sin(passed*c.x*(0.65+0.35*blockerHash(float2(seed,5)))+p);
        float active=step(0.18,blockerHash(float2(seed,floor(passed*0.65))));
        float hit=step(abs(y-by),c.y/(2*a.x))*active;
        signal*=1-b.z*hit;
    }
    float flicker=blockerHash(float2(row+d.x,floor(entryTime*c.w)));
    signal*=mix(1.0,0.55+0.45*flicker,c.z)*(0.45+0.45*r);
    return float3(signal);
}

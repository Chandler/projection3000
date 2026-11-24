// A full stream enters at x=0. Only inlet obstructions change its brightness.
// Each LED asks what was blocked when its water passed the inlet.
// a: rows, widths/second, blocker count, minimum gap seconds
// b: width min/max in rows, duration min/max in seconds
// c: movement rows, movement Hz, behavior, soft-tail length in matrix widths
// d: seed, event probability, unused, field clock
uint waterfallMix(uint x) {
    x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15;
    x *= 0x846ca68bu; return x ^ (x >> 16);
}
float waterfallRandom(int event, int lane, float seed, uint salt) {
    uint x = as_type<uint>(event) ^ (uint(lane + 1) * 0x9e3779b9u);
    return float(waterfallMix(x ^ uint(seed) ^ salt) >> 8) / 16777216.0;
}
float waterfallWander(float t, int lane, float seed) {
    int k = int(floor(t)); float f = fract(t); f = f*f*(3.0-2.0*f);
    return mix(waterfallRandom(k,lane,seed,71u),waterfallRandom(k+1,lane,seed,71u),f)*2.0-1.0;
}
float3 animation(float2 uv, float time, float4 a, float4 b, float4 c, float4 d) {
    float rows = max(1.0,round(a.x));
    float y = floor(clamp(uv.y,0.0,0.999999)*rows)+0.5;
    float velocity = max(0.05,a.y);
    float passed = time-uv.x/velocity;
    float minDuration = max(0.02,min(b.z,b.w)), maxDuration = max(minDuration,max(b.z,b.w));
    float cycle = maxDuration+max(0.0,a.w);
    float minWidth = clamp(min(b.x,b.y),1.0,rows), maxWidth = clamp(max(b.x,b.y),minWidth,rows);
    float signal = 1.0;
    int behavior = int(round(c.z));
    int count = clamp(int(round(a.z)),0,8);
    for (int lane=0; lane<count; ++lane) {
        // Independent lanes allow multiple overlapping fingers. Randomized phase
        // removes a common beat; structured modes retain evenly staggered timing.
        float phase = behavior == 0 || behavior == 3
            ? waterfallRandom(0,lane,d.x,3u) : float(lane)/float(max(1,count));
        float clock = passed+phase*cycle;
        int event = int(floor(clock/cycle));
        float duration = mix(minDuration,maxDuration,waterfallRandom(event,lane,d.x,11u));
        float delay = (maxDuration-duration)*waterfallRandom(event,lane,d.x,17u);
        float age = clock-float(event)*cycle-delay;
        if (age<0.0 || age>=duration || waterfallRandom(event,lane,d.x,23u)>=d.y) continue;
        float width = mix(minWidth,maxWidth,waterfallRandom(event,lane,d.x,31u));
        float center = waterfallRandom(event,lane,d.x,41u);
        float movement = 0.0;
        float motionClock = passed*max(0.0,c.y);
        if (behavior == 0) {
            movement = waterfallRandom(int(floor(motionClock)),lane,d.x,53u)*2.0-1.0;
        } else if (behavior == 1) {
            center = ((event+lane)&1) == 0 ? 0.25 : 0.75;
            movement = sin(motionClock*6.2831853+float(lane)*2.399963);
        } else if (behavior == 2) {
            center = 0.5;
            movement = sin(motionClock*6.2831853+float(lane)*2.399963);
        } else {
            movement = waterfallWander(motionClock,lane,d.x);
        }
        // Reflect at the boundaries instead of clipping fingers at the edges.
        float available = max(1.0,rows-width);
        center += movement*c.x/available;
        center = 1.0-abs(fract(center*0.5)*2.0-1.0);
        center = width*0.5+center*(rows-width);
        float hit = step(abs(y-center),width*0.5);
        float fade = min(max(0.0,c.w)/velocity,duration*0.5);
        float envelope = fade>0.00001 ? smoothstep(0.0,fade,age)*(1.0-smoothstep(duration-fade,duration,age)) : 1.0;
        signal *= 1.0-hit*envelope;
    }
    return float3(signal);
}

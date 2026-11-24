// Port of events/streaks: fixed rows carrying finite, coordinated packets.
// a: rows, travel widths/s, length, launches/s
// b: grouping, row stagger seconds, tail fade, seed
float streakHash(int n, uint seed) {
    uint x=uint(n)^(seed*0x045d9f3bu);
    x=(x^(x>>16))*0x7feb352du;
    x=(x^(x>>15))*0x846ca68bu;
    return float(x^(x>>16))/4294967296.0;
}
float3 animation(float2 uv,float time,float4 a,float4 b,float4 c,float4 d) {
    int rows=int(round(a.x));
    int row=clamp(int(floor(uv.y*float(rows))),0,rows-1);
    uint seed=uint(round(b.w));
    float t=time+7.3, rate=max(a.w,1.0), value=0;
    // Keep long tails alive even at the slowest travel setting.
    float history=max(5.0,(1.0+a.z*1.65*1.22)/(a.y*.8)+float(rows)*b.y*1.65);
    int first=int(floor((t-history)*rate)), last=int(floor(t*rate))+1;
    for(int e=first;e<=last;e++) {
        int key=e*137;
        float launch=(float(e)+.82*streakHash(key+1,seed))/rate;
        float center=streakHash(key+2,seed)*float(rows-1);
        bool wide=streakHash(key+3,seed)<.17;
        float span=1.0+b.x*(wide?float(rows)*.9:3.0+streakHash(key+4,seed)*10.0);
        int low=max(0,int(floor(center-span*.5)));
        int high=min(rows-1,int(ceil(center+span*.5)));
        if(row<low||row>high||streakHash(key+row*47+9,seed)<.09)continue;
        float slant=(streakHash(key+5,seed)<.5?-1.0:1.0)*b.y*(.45+streakHash(key+6,seed)*1.2);
        float velocity=a.y*(.8+.45*streakHash(key+7,seed));
        float len=a.z*(.5+streakHash(key+8,seed)*1.15)*(.72+.5*streakHash(key+row*47+11,seed));
        float offset=float(row-low)*slant+(streakHash(key+row*47+10,seed)-.5)*.024;
        float head=(t-launch-offset)*velocity, distance=head-uv.x;
        if(distance<0||distance>len)continue;
        float q=distance/len;
        float tail=(1.0-b.z)+b.z*pow(1.0-q,1.35);
        value+=(.6+.65*streakHash(key+row*47+12,seed))*tail*(1.0+.8*exp(-q*28.0))*smoothstep(0.0,.055,1.0-q);
    }
    return float3(value);
}

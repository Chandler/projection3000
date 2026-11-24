// Independent display-space gain. a: depth, spatial scale, gain, exposure mode.
// b.x: invert regions. Modes: 0 darken only, 1 brighten only, 2 both.
// Connect to LED Matrix's Light input; the streak field feeds Field.
float3 animation(float2 uv,float time,float4 a,float4 b,float4 c,float4 d) {
    float t=time+7.3;
    float field=sin(uv.x*8.1*a.y-t*.46)+.53*sin(uv.x*18.0*a.y+t*.23+2.1)+.32*sin(uv.y*7.0*a.y+t*.37);
    float exposure=field*.61-.22;
    if(b.x>0.5) exposure=-exposure;
    if(a.w<0.5) exposure=min(0.0,exposure);
    else if(a.w<1.5) exposure=max(0.0,exposure);
    return float3(exp(a.x*exposure)*a.z);
}

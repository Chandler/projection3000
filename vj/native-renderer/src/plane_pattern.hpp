#pragma once
// Pattern UVs have +Y at the top; the two axes are intentionally asymmetric.
#define VJ_PLANE_PATTERN_GLSL R"GLSL(
float planeSegment(vec2 p,vec2 a,vec2 b){
    vec2 d=b-a;return length(p-a-d*clamp(dot(p-a,d)/dot(d,d),0.0,1.0));
}
vec4 planePattern(vec2 uv,vec2 extent,bool circle){
    vec2 p=(uv*2.0-1.0)*extent;
    float pixel=max(length(fwidth(p)),.0001);
    float square=max(abs(p.x),abs(p.y));
    float frame=1.0-smoothstep(pixel,2.0*pixel,abs(square-1.0));
    float x=min(planeSegment(p,vec2(-.8,0),vec2(.8,0)),min(planeSegment(p,vec2(.8,0),vec2(.6,.14)),planeSegment(p,vec2(.8,0),vec2(.6,-.14))));
    float y=min(planeSegment(p,vec2(0,-.8),vec2(0,.8)),min(planeSegment(p,vec2(0,.8),vec2(-.14,.6)),planeSegment(p,vec2(0,.8),vec2(.14,.6))));
    // T at the top, R on the right.
    y=min(y,min(planeSegment(p,vec2(-.1,.93),vec2(.1,.93)),planeSegment(p,vec2(0,.93),vec2(0,.83))));
    x=min(x,min(planeSegment(p,vec2(.8,-.4),vec2(.8,-.18)),min(planeSegment(p,vec2(.8,-.18),vec2(.94,-.18)),min(planeSegment(p,vec2(.94,-.18),vec2(.94,-.29)),min(planeSegment(p,vec2(.94,-.29),vec2(.8,-.29)),planeSegment(p,vec2(.8,-.29),vec2(.94,-.4)))))));
    vec2 coverage=uv*2.0-1.0;
    float edge=circle?length(coverage):max(abs(coverage.x),abs(coverage.y));
    float border=1.0-smoothstep(.006,.014,abs(edge-.99));
    vec3 color=vec3(frame*.8);
    color=max(color,vec3(1,.4,.33)*(1.0-smoothstep(pixel,pixel*2.0,x)));
    color=max(color,vec3(.33,.86,1)*(1.0-smoothstep(pixel,pixel*2.0,y)));
    color=max(color,vec3(0,1,.4)*border);
    return vec4(color,1);
}
)GLSL"

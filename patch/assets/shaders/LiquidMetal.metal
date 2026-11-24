// Liquid Metal — smooth-union spheres, raymarched live in Patch.
// External user-node source; packed controls defined by LiquidMetalStyle.swift.
#if PATCH_LIQUID_METAL_CONTROLS_VERSION >= 1
#define PATCH_EFFECT_RGBA(uv,t,input,c) liquidMetal(uv,t,input,c)
#endif
// Legacy installation preflight entry point (the full renderer uses RGBA above).
float3 effect(float2 uv,float time,texture2d<float,access::sample> input,float4 controls) { return float3(0); }

float lmUnion(float a,float b,float k) {
    if(k<0.0001) return min(a,b);
    float h=clamp(0.5+0.5*(b-a)/k,0.0,1.0);
    return mix(b,a,h)-k*h*(1.0-h);
}
#if PATCH_LIQUID_METAL_CONTROLS_VERSION >= 3
// Continuous low-frequency surfaces, without bead junctions or polygonal bridges.
float lmEllipsoid(float3 p,float3 radius) {
    return (length(p/radius)-1.0)*min(radius.x,min(radius.y,radius.z));
}
#if PATCH_LIQUID_METAL_CONTROLS_VERSION >= 5
float lmSweep(float3 p,float4 a,float4 b,float4 c) {
    float4 ab=b-a, bend=a-2.0*b+c;
    float best=1e10,t=0;
    // Locate the nearest basin before Newton refinement; radius participates in the minimization.
    for(int j=0;j<=4;j++) {
        float u=float(j)*0.25;
        float4 v=a+2.0*u*ab+u*u*bend;
        float score=dot(v.xyz-p,v.xyz-p)-v.w*v.w;
        if(score<best) { best=score;t=u; }
    }
    for(int j=0;j<4;j++) {
        float4 v=a+2.0*t*ab+t*t*bend;
        float4 velocity=2.0*(ab+t*bend);
        float numerator=dot(v.xyz-p,velocity.xyz)-v.w*velocity.w;
        float denominator=dot(velocity.xyz,velocity.xyz)+2.0*dot(v.xyz-p,bend.xyz)-velocity.w*velocity.w-2.0*v.w*bend.w;
        if(denominator>0.00001) t=clamp(t-clamp(numerator/denominator,-0.2,0.2),0.0,1.0);
    }
    float4 nearest=a+2.0*t*ab+t*t*bend;
    float distance=length(p-nearest.xyz)-nearest.w;
    // Endpoints matter when radius changes strongly along the pulled branch.
    distance=min(distance,min(length(p-a.xyz)-a.w,length(p-c.xyz)-c.w));
    return distance*0.55;
}
float lmFlow(float3 p,float time,constant float4 *c) {
    float span=max(0.3,c[15].x)*0.82,height=max(0.4,c[15].y);
    float depth=0.60+min(c[15].z,1.5)*0.35;
    float3 q=p/float3(span,span*height,span*depth);
    q+=c[3].z*0.04*sin(q.yzx*1.3+time*0.5);
    float d=100;
    float fusion=(0.20+c[13].z*0.32)*0.55;
    int count=clamp(int(c[13].x),0,32);
    for(int i=0;i<count;i++) {
        int index=17+i*4;
        float4 bound=c[index+3];
        if((length(q-bound.xyz)-bound.w)*0.55>d+fusion) continue;
        d=lmUnion(d,lmSweep(q,c[index],c[index+1],c[index+2]),fusion);
    }
    return d*min(span,min(span*height,span*depth))/(1.0+c[3].z*0.1);
}
#endif

float lmMolten(float3 p,float time,constant float4 *c) {
#if PATCH_LIQUID_METAL_CONTROLS_VERSION >= 5
    return lmFlow(p,time,c);
#endif
    float span=max(c[15].x,0.3),height=max(c[15].y,0.4);
    float full=c[13].z,flow=c[13].w,variation=c[16].x;
    float phase=fract(c[4].w*0.61803398875)*6.2831853;
    float3 q=p/float3(span,span*height,span);
    float zScale=0.65+c[15].z*0.5;
    q.z/=zScale;
    // A smooth bend and twist move the entire surface and its openings together.
    float twist=flow*0.48*sin(q.y*1.3+phase);
    float co=cos(twist),si=sin(twist);
    q.xz=float2(co*q.x-si*q.z,si*q.x+co*q.z);
    q.x+=flow*0.20*sin(q.y*2.1+phase);
    q.z+=flow*0.12*sin(q.y*1.6+q.x+phase);
    q+=c[3].z*0.045*sin(q.yzx*1.2+time*0.5);
    int complexity=1;
#if PATCH_LIQUID_METAL_CONTROLS_VERSION >= 4
    complexity=clamp(int(round(c[16].w)),1,6);
#endif
    float assemblyScale=1.0+0.42*float(complexity-1);
    float3 assemblyPoint=q*assemblyScale;
    float combined=100.0;
    for(int component=0;component<complexity;component++) {
        float i=float(component);
        float3 center=float3(0);
        if(complexity>1) center=float3(0.30*sin(i*2.4+phase), (i-float(complexity-1)*0.5)*1.45, 0.12*sin(i*1.7+phase));
        float3 q=assemblyPoint-center;
        float angleOffset=complexity>1 ? 0.18*sin(i*1.8+phase):0.0;
        q.xy=float2(cos(angleOffset)*q.x+sin(angleOffset)*q.y,-sin(angleOffset)*q.x+cos(angleOffset)*q.y);
    float d;
    if(c[13].y<3.5) {
        float angle=atan2(q.y,q.x);
        float ring=0.75+c[16].y*0.35+variation*0.14*sin(angle*3.0+phase);
        float tube=0.20+c[15].w*0.38+full*0.13;
        tube*=1.0+variation*0.27*cos(angle*2.0+phase+0.8);
        // The opening stays rounded as the rim swells into broad liquid lobes.
        float2 section=float2(length(q.xy)-ring,q.z);
        d=length(section)-tube;
    } else {
        // A small number of broad merged masses gives poured metal its long gradients.
        float belly=0.66+c[15].w*0.3+full*0.12;
        d=lmEllipsoid(q-float3(-0.10,-0.48,0),float3(belly,0.86,0.54+full*0.18));
        float crown=lmEllipsoid(q-float3(0.18,0.63,0.03),float3(0.55+variation*0.18,0.65,0.48));
        d=lmUnion(d,crown,0.38+full*0.35);
        float side=lmEllipsoid(q-float3(-0.40,0.05,0),float3(0.46,0.58,0.47));
        d=lmUnion(d,side,0.32+full*0.22);
    }
    int holes=clamp(int(c[16].z),0,6);
    // Loop already supplies one opening; further holes are optional.
    int start=c[13].y<3.5 ? 1:0;
    for(int i=start;i<holes;i++) {
        float index=float(i);
        float2 center=c[13].y<3.5 ? float2(cos(phase+index*2.4),sin(phase+index*2.4))*0.86 : float2(-0.18+0.13*sin(phase+index),-0.28+index*0.38);
        float size=c[16].y*(i==0 ? 1.0:0.65);
        float cut=lmEllipsoid(q-float3(center,0),float3(size,size*1.25,3));
        d=-lmUnion(-d,cut,0.12+full*0.10);
    }
        combined=lmUnion(combined,d,0.16+full*0.12);
    }
    float d=combined/assemblyScale;
    // Conservative step for the smooth coordinate deformation.
    return d*min(span,min(span*height,span*zScale))/(1.0+flow*1.6+c[3].z*0.15);
}
#endif

float lmDistance(float3 p,float time,constant float4 *c) {
#if PATCH_LIQUID_METAL_CONTROLS_VERSION >= 3
    if(c[13].y>=3) return lmMolten(p,time,c);
#endif
#if PATCH_LIQUID_METAL_CONTROLS_VERSION >= 2
    // One continuous deformation field keeps joins together during motion.
    p += c[3].z*0.09*sin(p.yzx*1.7+float3(time*0.8,time*0.65,time*0.5));
    float d=100.0;
    int count=clamp(int(c[13].x),0,150);
    for(int i=0;i<count;i++) {
        float4 a=c[15+i*3],b=c[16+i*3],shape=c[17+i*3];
        float distance;
        if(shape.w>0.5 && shape.w<1.5) {
            float3 segment=b.xyz-a.xyz, q=p-a.xyz;
            float len2=max(dot(segment,segment),0.000001);
            float h=clamp(dot(q,segment)/len2,0.0,1.0);
            distance=(length(q-segment*h)-mix(a.w,b.w,h))/(1.0+abs(b.w-a.w)/sqrt(len2));
        } else {
            float3 q=p-a.xyz;
            float co=cos(shape.z),si=sin(shape.z);
            q.xy=float2(co*q.x+si*q.y,-si*q.x+co*q.y);
            float3 axes=max(b.xyz,float3(0.005));
            distance=(length(q/axes)-1.0)*min(axes.x,min(axes.y,axes.z));
        }
        if(shape.w>1.5) d=-lmUnion(-d,distance,min(c[0].y*0.25,0.12));
        else d=lmUnion(d,distance,c[0].y);
    }
    // Domain warp's derivative bounds the conservative march step.
    return d/(1.0+c[3].z*0.3);
#else
    float d=100.0;
    int count=clamp(int(round(c[0].x)),1,8);
    for(int i=0;i<count;i++) {
        float4 ball=c[5+i];
        float phase=float(i)*2.39996;
        ball.xyz+=c[3].z*0.18*float3(sin(time*0.8+phase),cos(time*0.65+phase),sin(time*0.5+phase));
        d=lmUnion(d,length(p-ball.xyz)-ball.w,c[0].y);
    }
    return d;
#endif
}
float3 lmNormal(float3 p,float time,constant float4 *c) {
    float e=0.0015;
    float3 a=float3(1,-1,-1),b=float3(-1,-1,1),d=float3(-1,1,-1),f=float3(1,1,1);
    return normalize(a*lmDistance(p+a*e,time,c)+b*lmDistance(p+b*e,time,c)+d*lmDistance(p+d*e,time,c)+f*lmDistance(p+f*e,time,c));
}
float3 lmRotate(float3 p,float yaw,float pitch) {
    p=float3(p.x,cos(pitch)*p.y-sin(pitch)*p.z,sin(pitch)*p.y+cos(pitch)*p.z);
    return float3(cos(yaw)*p.x+sin(yaw)*p.z,p.y,-sin(yaw)*p.x+cos(yaw)*p.z);
}
float3 lmEnvironment(float3 r,float rough,texture2d<float,access::sample> input,constant float4 *c) {
    r=lmRotate(r,c[2].x*0.0174532925,0);
    float width=1.0,contrast=0.0,cool=0.0;
#if PATCH_LIQUID_METAL_CONTROLS_VERSION >= 2
    width=c[14].x;contrast=c[14].y;cool=c[14].z;
#endif
    float softness=0.004+rough*0.32+width*0.021;
    // Broad photographic softboxes reflected in the metal, with dark gaps.
    float key=smoothstep(0.96-width*0.18-softness,0.96-width*0.18+softness,dot(r,normalize(float3(-1,1.2,1.5))));
    float strip=(1.0-smoothstep(0.012+width*0.028,0.025+width*0.095+softness,abs(r.x-0.65)))*smoothstep(-0.6,-0.2,r.y);
    float rim=smoothstep(0.87-softness,0.87+softness,dot(r,normalize(float3(-1,0,-1))));
    float3 studio=float3(0.045,0.055,0.075)+float3(0.22,0.25,0.30)*smoothstep(-0.2,0.8,r.y);
    studio*=1.0-contrast*0.92;
    studio+=key*float3(2.6,2.45,2.2)+strip*float3(1.8,2.1,2.6)+rim*float3(1.8);
    studio*=mix(float3(1),float3(0.76,0.86,1.15),cool);
    float3 env=studio*c[2].y;
    if(c[4].y>0.5 && c[1].w>0.0) {
        float2 uv=c[4].z<0.5 ? float2(atan2(r.x,r.z)/6.2831853+0.5,acos(clamp(r.y,-1.0,1.0))/3.14159265) : float2(r.x*0.5+0.5,0.5-r.y*0.5);
        constexpr sampler panorama(coord::normalized,s_address::repeat,t_address::clamp_to_edge,filter::linear);
        constexpr sampler mirrorImage(coord::normalized,address::clamp_to_edge,filter::linear);
        float3 media=float3(0);
        for(int j=0;j<9;j++) {
            float angle=float(j)*2.39996;
            float2 offset=float2(cos(angle),sin(angle))*sqrt(float(j)/8.0)*rough*rough*0.12;
            float3 sample=c[4].z<0.5 ? input.sample(panorama,uv+offset).rgb : input.sample(mirrorImage,uv+offset).rgb;
            media+=pow(max(sample,float3(0)),float3(2.2))/9.0;
        }
        env=mix(env,media*1.8+studio*c[2].y*0.22,c[1].w);
    }
    return env;
}
float4 liquidMetal(float2 uv,float time,texture2d<float,access::sample> input,constant float4 *c) {
    float2 screen=(uv-float2(0.5))*float2(c[4].x,-1.0)*4.8/max(c[0].z,0.1);
    float yaw=c[1].x*0.0174532925,pitch=c[1].y*0.0174532925;
    // Orthographic camera is convenient for graphic/poster composition.
    float3 ro=lmRotate(float3(screen,9),yaw,pitch),rd=lmRotate(float3(0,0,-1),yaw,pitch);
    float t=0,d=1;
    int steps=c[3].w<0.5 ? 64 : (c[3].w<1.5 ? 112 : 176);
    float epsilon=c[3].w<0.5 ? 0.003 : (c[3].w<1.5 ? 0.0012 : 0.0005);
    bool hit=false;
    for(int i=0;i<steps;i++) {
        d=lmDistance(ro+rd*t,time,c);
        if(d<epsilon) { hit=true;break; }
        t+=max(d*0.85,epsilon*0.5);
        if(t>19.0) break;
    }
    float background=c[2].w;
    if(!hit) return background<0.5 ? float4(0) : float4(background<1.5 ? float3(0.035,0.04,0.05) : float3(0.94,0.925,0.89),1);
    float3 p=ro+rd*t,n=lmNormal(p,time,c);
    float frequency=c[3].y;
    float3 ripple=float3(cos(p.x*frequency)*sin(p.y*frequency),cos(p.y*frequency)*sin(p.z*frequency),cos(p.z*frequency)*sin(p.x*frequency));
    n=normalize(n+(ripple-n*dot(ripple,n))*c[3].x*0.3);
    float3 reflected=reflect(rd,n);
    float rough=c[0].w;
    float3 env=lmEnvironment(reflected,rough,input,c);
#if PATCH_LIQUID_METAL_CONTROLS_VERSION >= 2
    if(c[14].w>0.001) {
        // One bounded secondary ray produces reflections between sculpture surfaces.
        float3 origin=p+n*0.015;
        float travel=0.02;
        for(int j=0;j<32;j++) {
            float3 q=origin+reflected*travel;
            float distance=lmDistance(q,time,c);
            if(distance<0.002) {
                float3 secondaryNormal=lmNormal(q,time,c);
                float3 secondary=lmEnvironment(reflect(reflected,secondaryNormal),min(1.0,rough+0.08),input,c);
                env=mix(env,secondary*0.78,c[14].w*(1.0-rough*0.7));
                break;
            }
            travel+=max(distance*0.8,0.004);
            if(travel>10) break;
        }
    }
#endif
    float3 tint=c[1].z<0.5 ? float3(0.91,0.93,0.96) : (c[1].z<1.5 ? float3(1.0,0.71,0.29) : float3(0.95,0.49,0.31));
    float fresnel=pow(1.0-clamp(dot(-rd,n),0.0,1.0),5.0);
    float3 f=mix(tint,float3(1),fresnel);
    float ao=1.0;
    for(int j=1;j<=3;j++) {
        float distance=float(j)*0.16;
        ao-=max(0.0,distance-lmDistance(p+n*distance,time,c))*0.45/float(j);
    }
    float3 color=env*f*clamp(ao,0.35,1.0)*c[2].z;
    color=clamp((color*(2.51*color+0.03))/(color*(2.43*color+0.59)+0.14),0.0,1.0); // filmic highlight rolloff
    color=pow(max(color,float3(0)),float3(1.0/2.2));
    return float4(color,1);
}

// Mesh Gradient: eight editable color anchors, smooth blending and fluid motion.
// c[0]: count / motion / movement / softness; c[1]: warp / grain.
// Each anchor uses two float4s: normalized position, then RGB.
float3 meshLegacyGradient(float2 uv, float time, constant float4 *c, float aspect) {
    int count = clamp(int(c[0].x),3,8), mode = int(c[0].y);
    float t = mode == 0 ? 0.0 : time * 0.42;
    float amount = mode == 0 ? 0.0 : c[0].z;
    float2 flow = float2(sin(uv.y*5.1+t*0.71)+sin(uv.x*3.7-uv.y*2.4-t*0.43),
                        cos(uv.x*4.3-t*0.57)+sin(uv.y*3.1+uv.x*2.2+t*0.37));
    float2 q = uv + flow * c[1].x * 0.075;
    float3 sum = 0; float total = 0;
    float sharpness = mix(38.0,3.0,c[0].w);
    float2 metric = float2(sqrt(clamp(aspect,0.25,4.0)),1.0/sqrt(clamp(aspect,0.25,4.0)));
    for (int i=0;i<count;i++) {
        float2 p = c[2+i*2].xy;
        float phase = float(i)*2.399963;
        if (mode == 1) {
            p += amount * 0.17 * float2(sin(t*0.7+phase),cos(t*0.53+phase*1.3));
        } else if (mode == 2) {
            p += amount * float2(0.16*sin(t*0.67+phase)+0.07*sin(t*1.13-phase),
                                 0.29*sin(t*0.49+phase*1.7)+0.06*cos(t*0.83+phase));
        } else if (mode == 3) {
            float angle = t*0.48, s=sin(angle), co=cos(angle);
            float2 d=p-0.5;
            p=mix(p,0.5+float2(co*d.x-s*d.y,s*d.x+co*d.y),amount);
        }
        float2 d = (q-p)*metric;
        float w = exp2(-dot(d,d)*sharpness) + 0.000001;
        float3 rgb = c[3+i*2].rgb;
        sum += rgb*rgb*w; total += w;
    }
    float3 rgb = sqrt(sum/total);
    float grain = fract(sin(dot(uv,float2(12713.1,31179.7)))*43758.5453)-0.5;
    return clamp(rgb+grain*c[1].y*0.055,0.0,1.0);
}


// Shaped fields are evaluated in canvas-long-side units. The original 18 slots
// remain intact; extension v2 begins at slot 18, with 217 slots per region at 24.
float meshHash(float2 p) {
    float3 q=fract(float3(p.x,p.y,p.x)*0.1031f);
    q+=dot(q,q.yzx+33.33f); return fract((q.x+q.y)*q.z);
}
float3 meshLinear(float3 x) {
    return select(x/12.92f,pow((x+0.055f)/1.055f,float3(2.4f)),x>0.04045f);
}
float3 meshSRGB(float3 x) {
    x=max(x,0.0f); return select(x*12.92f,1.055f*pow(x,float3(1.0f/2.4f))-0.055f,x>0.0031308f);
}
float3 meshLab(float3 rgb) {
    float3 c=meshLinear(rgb);
    float3 lms=float3(dot(c,float3(.4122214708,.5363325363,.0514459929)),dot(c,float3(.2119034982,.6806995451,.1073969566)),dot(c,float3(.0883024619,.2817188376,.6299787005)));
    lms=pow(max(lms,0.0f),float3(1.0f/3.0f));
    return float3(dot(lms,float3(.2104542553,.7936177850,-.0040720468)),dot(lms,float3(1.9779984951,-2.4285922050,.4505937099)),dot(lms,float3(.0259040371,.7827717662,-.8086757660)));
}
float3 meshFromLab(float3 c) {
    float3 x=float3(c.x+.3963377774*c.y+.2158037573*c.z,c.x-.1055613458*c.y-.0638541728*c.z,c.x-.0894841775*c.y-1.2914855480*c.z);x=x*x*x;
    return meshSRGB(float3(dot(x,float3(4.0767416621,-3.3077115913,.2309699292)),dot(x,float3(-1.2684380046,2.6097574011,-.3413193965)),dot(x,float3(-.0041960863,-.7034186147,1.7076147010))));
}
float2 meshDir(float a) { return float2(cos(a),sin(a)); }
float meshSegment(float2 p,float2 a,float2 b,thread float &fraction) {
    float2 d=b-a; fraction=clamp(dot(p-a,d)/max(dot(d,d),1e-10f),0.0f,1.0f);
    return length(p-a-d*fraction);
}
float meshWrap(float a) { return atan2(sin(a),cos(a)); }
float meshArc(float2 p,float2 a,float2 b) {
    // Circle through the centre handle and the two arm ends. Nearly straight
    // or collapsed arms degrade continuously to the two line segments.
    float det=a.x*b.y-a.y*b.x;
    float t;
    if (abs(det)<1e-5f) return min(meshSegment(p,a,float2(0),t),meshSegment(p,float2(0),b,t));
    float2 o=float2(dot(a,a)*b.y-dot(b,b)*a.y,a.x*dot(b,b)-b.x*dot(a,a))/(2.0f*det);
    float radius=length(o), aa=atan2(a.y-o.y,a.x-o.x), ab=atan2(b.y-o.y,b.x-o.x);
    float apex=atan2(-o.y,-o.x), ap=atan2(p.y-o.y,p.x-o.x);
    float span=meshWrap(ab-aa), mid=meshWrap(apex-aa);
    if ((span>=0 && (mid<0 || mid>span)) || (span<0 && (mid>0 || mid<span))) span+=span>=0 ? -2.0f*M_PI_F : 2.0f*M_PI_F;
    float u=meshWrap(ap-aa); if (span>0 && u<0) u+=2.0f*M_PI_F; if (span<0 && u>0) u-=2.0f*M_PI_F;
    return (span>=0 ? u<=span : u>=span) ? abs(length(p-o)-radius) : min(length(p-a),length(p-b));
}
float3 meshGradient(float2 uv,float time,constant float4 *c,float aspect) {
    if (c[18].y<0.5f) return meshLegacyGradient(uv,time,c,aspect);
    float2 scale=aspect>=1 ? float2(1,1/aspect) : float2(aspect,1);
    float ft=c[0].y==0 ? 0:time;
    float2 flow=float2(sin(uv.y*5.1f+ft*.2982f)+sin(uv.x*3.7f-uv.y*2.4f-ft*.1806f),cos(uv.x*4.3f-ft*.2394f)+sin(uv.y*3.1f+uv.x*2.2f+ft*.1554f));
    float2 p=(uv+flow*c[1].x*.075f)*scale;
    float soft=max(c[18].w,0.005f); int blend=int(c[18].z),count=clamp(int(c[0].x),1,40);
    float3 total=0,over=0; float weight=0,alpha=0;
    for(int i=0;i<count;i++) {
        constant float4 *f=c+24+i*217;
        float2 d=p-f[0].xy*scale; int shape=int(f[0].z);
        float radius=1,d2=0,edge=0,k=f[2].z,brushWeight=0;
        float a=f[2].x,b=f[2].y, linked=f[3].x;
        float4 armAngles=linked>0.5f ? float4(a+M_PI_F,a,b+M_PI_F,b) : f[4];
        if(shape==0) {
            if(linked>0.5f) {
                float2 ax=meshDir(a),ay=meshDir(b); float det=ax.x*ay.y-ax.y*ay.x;
                if(abs(det)<.05f) det=det<0 ? -.05f:.05f;
                float2 q=float2(d.x*ay.y-d.y*ay.x,ax.x*d.y-ax.y*d.x)/det;
                float2 r=float2(q.x<0 ? f[1].x:f[1].y,q.y<0 ? f[1].z:f[1].w);
                float2 n=q/max(r*soft,float2(1e-5f));d2=dot(n,n);
                edge=(length(q/max(r*.5f,float2(1e-5f)))-1)*.25f*(r.x+r.y);
                radius=(f[1].x+f[1].y+f[1].z+f[1].w)*.25f;
            } else {
                float ang=atan2(d.y,d.x),rs=0,ws=0;
                for(int j=0;j<4;j++) { float diff=meshWrap(ang-armAngles[j]);float w=1/max(diff*diff,.0001f);rs+=f[1][j]*w;ws+=w; }
                radius=rs/ws;d2=dot(d,d)/max(radius*radius*soft*soft,1e-10f);edge=length(d)-radius*.5f;
            }
        } else if(shape==1 || shape==2) {
            float bend=shape==2 ? f[3].y:0;
            if(linked>0.5f && shape==2) { armAngles.x=a+M_PI_F-bend;armAngles.y=a+bend; }
            float2 left=meshDir(armAngles.x)*f[1].x,right=meshDir(armAngles.y)*f[1].y;
            float t;
            float dist=shape==2 ? meshArc(d,left,right) : linked>0.5f ? meshSegment(d,left,right,t) : min(meshSegment(d,left,float2(0),t),meshSegment(d,float2(0),right,t));
            radius=f[2].w;d2=dist*dist/max(radius*radius*soft*soft,1e-10f);edge=dist-radius*.5f;
            // Fill extent follows the length/curvature rather than the band width.
            radius=0.5f*length(right-left);
            if(shape==2) {
                float det=left.x*right.y-left.y*right.x;
                if(abs(det)>1e-5f) radius=length(float2(dot(left,left)*right.y-dot(right,right)*left.y,left.x*dot(right,right)-right.x*dot(left,left))/(2*det));
            }
        } else {
            int n=clamp(int(f[7].w),0,192);float best=1e10f,nearest=1e10f,extent=0;
            float2 ax=meshDir(a),ay=float2(-ax.y,ax.x),local=float2(dot(d,ax),dot(d,ay));
            for(int j=1;j<n;j++) {
                extent=max(extent,max(length(f[25+j-1].xy),length(f[25+j].xy)));
                float t;float dist=meshSegment(local,f[25+j-1].xy,f[25+j].xy,t);
                float ds=dist*dist/max(f[2].w*f[2].w*soft*soft,1e-10f);
                float e=mix(f[25+j-1].z,f[25+j].z,t)*k/max(f[6].x,1.0f)*log(1+ds);
                float h=max(.2f*min(best,e)+.0001f-abs(best-e),0.0f)/max(.2f*min(best,e)+.0001f,.0001f);
                best=min(best,e)-h*h*(.2f*min(best,e)+.0001f)*.25f;nearest=min(nearest,dist);
            }
            brushWeight=exp(-best)+1e-7f/(1+nearest*nearest/max(f[2].w*f[2].w*soft*soft,1e-10f));radius=f[2].w;edge=nearest-radius*.5f;radius=max(extent,1e-4f);
            if(n<2) continue;
        }
        float w=shape==3 ? brushWeight:pow(1/(1+d2),k)+1e-7f/(1+d2);
        if(f[3].z>0.5f) {
            float facing=length(d)>1e-8f ? dot(normalize(d),meshDir(f[5].z)):0;
            float feather=max(mix(f[5].x,f[5].y,(facing+1)*.5f),1e-6f);
            w=1-smoothstep(-feather,feather,edge);
        }
        float3 rgb=f[7].rgb;float opacity=f[0].w;
        if(f[8].x>0.5f && int(f[8].w)>=2) {
            float t=clamp(.5f+dot(d,meshDir(f[8].y))/(2*max(radius,.0001f)),0.0f,1.0f);
            int n=clamp(int(f[8].w),2,8);rgb=f[10].rgb;float op=f[9].y;
            for(int j=1;j<n;j++) {
                float start=f[9+(j-1)*2].x,end=f[9+j*2].x;
                if(t>=start) {
                    float u=clamp((t-start)/max(end-start,1e-6f),0.0f,1.0f);
                    int ease=int(f[8].z);if(ease==1)u=u*u;if(ease==2)u=u*(2-u);if(ease==3)u=u<.5f ? 2*u*u:1-2*(1-u)*(1-u);
                    rgb=mix(f[10+(j-1)*2].rgb,f[10+j*2].rgb,u);op=mix(f[9+(j-1)*2].y,f[9+j*2].y,u);
                }
            }
            opacity*=op;
        }
        w*=opacity;
        if(f[3].z>0.5f) { float v=clamp(w,0.0f,1.0f);over=rgb*v+over*(1-v);alpha=v+alpha*(1-v);continue; }
        float3 color=rgb;
        if(blend==0)color=rgb*rgb;
        if(blend==2)color=meshLinear(rgb);
        if(blend==3)color=meshLab(rgb);
        if(blend==4)color=log(max(rgb,1e-4f));
        if(blend==5)color=log(max(1-rgb,1e-4f));
        if(blend==8)color=pow(max(rgb,1e-4f),float3(6));
        if(blend==9)color=pow(max(1-rgb,1e-4f),float3(6));
        total+=color*w;weight+=w;
    }
    float3 rgb=weight>1e-12f ? total/weight:float3(.5f);
    if(blend==0)rgb=sqrt(max(rgb,0.0f));if(blend==2)rgb=meshSRGB(rgb);if(blend==3)rgb=meshFromLab(rgb);
    if(blend==4)rgb=exp(rgb);if(blend==5)rgb=1-exp(rgb);
    if(blend==6)rgb=select(2*rgb*rgb,1-2*(1-rgb)*(1-rgb),rgb>=.5f);
    if(blend==7)rgb=rgb*rgb*(3-2*rgb);
    if(blend==8)rgb=pow(max(rgb,0.0f),float3(1.0f/6));if(blend==9)rgb=1-pow(max(rgb,0.0f),float3(1.0f/6));
    rgb=over+rgb*(1-alpha);
    float3 axis=normalize(float3(1)),luma=float3(.2126,.7152,.0722);float angle=c[20].x*M_PI_F/180;
    rgb=rgb*cos(angle)+cross(axis,rgb)*sin(angle)+axis*dot(axis,rgb)*(1-cos(angle));
    rgb=mix(float3(dot(rgb,luma)),rgb,c[20].y)*c[20].z;
    float3 gain=float3(1+.003f*c[20].w,1+.0005f*c[20].w,1-.003f*c[20].w);rgb*=gain/dot(gain,luma);
    // Logical grain size is independent of preview texture resolution.
    float2 cell=floor(uv*scale*1000/max(c[19].x,1.0f));float seed=c[19].w;
    float3 n=float3(meshHash(cell+seed),meshHash(cell+seed+17.23f),meshHash(cell+seed+41.71f));
    float3 noise=c[19].z>1.5f ? n:c[19].z>.5f ? n.x*c[21].rgb+n.y*c[22].rgb:n.x*c[21].rgb;
    float mask=step(1-c[19].y,meshHash(cell+seed+91.13f));
    return clamp(rgb+(noise-.5f)*c[1].y*.15f*mask,0.0f,1.0f);
}

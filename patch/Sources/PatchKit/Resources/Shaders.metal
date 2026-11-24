#include <metal_stdlib>
using namespace metal;
struct Params { float4 a; float4 b; float4 c; uint4 mode; float4 d; float4 e; };
constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
float3 fitSample(texture2d<float, access::sample> tex, float2 uv, float aspect) {
    float sourceAspect = float(tex.get_width()) / max(1.0f, float(tex.get_height()));
    float2 p = uv - 0.5;
    if (sourceAspect > aspect) p.y *= sourceAspect / aspect; else p.x *= aspect / sourceAspect;
    p += 0.5;
    if (any(p < 0) || any(p > 1)) return float3(0);
    return tex.sample(linearSampler, p).rgb;
}
// Ideal subtractive CMYK for creative separation, not an ICC print transform.
float4 splitCMYK(float3 rgb) {
    float v=max(rgb.r,max(rgb.g,rgb.b));
    return float4(v>0.000001 ? (v-rgb)/v : float3(0),1-v);
}
float3 splitSample(texture2d<float,access::sample> tex,float2 uv,uint edges,bool cmyk) {
    if(edges==1) uv=fract(uv);
    else if(edges==2) uv=1-abs(1-2*fract(uv*0.5));
    else if(edges==3 && (any(uv<0) || any(uv>1))) return float3(cmyk ? 1 : 0);
    return tex.sample(linearSampler,uv).rgb;
}
float3 matrixInput(texture2d<float,access::sample> source,texture2d<float,access::sample> lightCells,float2 uv,constant float *data,float time) {
#ifdef MATRIX_FLASH_PRIMARY
    float3 signal=matrixDriver::flash(uv,time,data);
#elif defined(MATRIX_CELL_FIELD)
    constexpr sampler cells(coord::normalized,address::clamp_to_edge,filter::nearest);
    float activity=source.sample(cells,uv).g;
    float3 signal=float3(mix(1.0,data[1]<0.5?1-activity:activity,data[0]));
#elif defined(MATRIX_FIELD)
    float3 signal=matrixDriver::animation(uv,time,float4(data[0],data[1],data[2],data[3]),float4(data[4],data[5],data[6],data[7]),float4(data[8],data[9],data[10],data[11]),float4(data[12],data[13],data[14],data[15]));
#else
    float3 signal=source.sample(linearSampler,uv).rgb;
#endif
#ifdef MATRIX_FLASH_LIGHT
    signal*=matrixLight::flash(uv,data[31],data+16);
#elif defined(MATRIX_CELL_LIGHT)
    constexpr sampler lightSampler(coord::normalized,address::clamp_to_edge,filter::nearest);
    float activityLight=lightCells.sample(lightSampler,uv).g;
    signal*=mix(1.0,data[17]<0.5?1-activityLight:activityLight,data[16]);
#elif defined(MATRIX_LIGHT)
    signal*=max(float3(0),matrixLight::animation(uv,data[31],float4(data[16],data[17],data[18],data[19]),float4(data[20],data[21],data[22],data[23]),float4(data[24],data[25],data[26],data[27]),float4(data[28],data[29],data[30],data[31])));
#endif
    return signal;
}
#ifdef MATRIX_LIGHT
// Node preview for a light field: neutral light (1.0) shows as mid gray.
kernel void lightPreview(texture2d<float,access::write> output [[texture(0)]],constant float *data [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=output.get_width()||gid.y>=output.get_height()) return;
    float2 uv=(float2(gid)+0.5)/float2(output.get_width(),output.get_height());
    float3 light=max(float3(0),matrixLight::animation(uv,data[15],float4(data[0],data[1],data[2],data[3]),float4(data[4],data[5],data[6],data[7]),float4(data[8],data[9],data[10],data[11]),float4(data[12],data[13],data[14],data[15])));
    output.write(float4(light/(light+1),1),gid);
}
#endif
float3 matrixTint(float3 hsv) {
    float3 rgb=clamp(abs(fract(hsv.x+float3(0,2.0/3,1.0/3))*6-3)-1,0.0,1.0);
    return mix(float3(1),rgb,hsv.y)*hsv.z;
}
kernel void process(texture2d<float, access::sample> source [[texture(0)]],
                    texture2d<float, access::sample> second [[texture(1)]],
                    texture2d<float, access::write> output [[texture(2)]],
                    constant Params &p [[buffer(0)]], constant float *audio [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float2 size(output.get_width(), output.get_height());
    float2 uv = (float2(gid) + 0.5) / size;
    float3 col(0);
    uint op = p.mode.x;
    if (op == 0) {
        float t = p.c.x * p.a.y;
        if (p.a.x < 0.5) {
            float2 q = (uv - 0.5) * float2(size.x / size.y, 1);
            float v = sin(q.x * 3.4 + t) + cos(q.y * 4.5 - t * 0.7) + sin(length(q + float2(sin(t)*0.25, cos(t)*0.25)) * 5 - t);
            col = 0.5 + 0.5 * cos(v * 0.8 + float3(0.1, 2.1, 4.2));
            col *= 0.65 + 0.35 * smoothstep(0.9, 0.1, length(q));
        } else if (p.a.x < 1.5) {
            constexpr float3 bars[] = {float3(1), float3(1,1,0),float3(0,1,1),float3(0,1,0),float3(1,0,1),float3(1,0,0),float3(0,0,1)};
            col = bars[min(6, int(uv.x * 7))] * (uv.y > 0.8 ? 0.25 : 0.85);
        } else {
            float2 grid = abs(fract(uv * float2(16,9) + float2(t * 0.2, 0)) - 0.5);
            float line = step(0.475, max(grid.x, grid.y));
            col = mix(float3(0.035,0.048,0.055), float3(0.32,0.82,0.74), line);
            if (length((uv-0.5)*float2(size.x/size.y,1)) < 0.23) col += float3(0.25,0.1,0.02);
        }
    } else if (op == 1) {
        col = fitSample(source, float2(p.b.x > 0.5 ? 1-uv.x : uv.x,uv.y), size.x/size.y);
    } else if (op == 7) {
        // Fit the rotated source bounds, then invert the transform for sampling.
        // Positive angles rotate clockwise in image coordinates; 90° keeps a
        // portrait video fully visible instead of cropping its rotated corners.
        float aspect = size.x/size.y;
        float sourceAspect = float(source.get_width())/float(source.get_height());
        float c = cos(p.a.x), s = sin(p.a.x);
        float2 extent = float2(abs(c)*sourceAspect+abs(s),abs(s)*sourceAspect+abs(c));
        float fit = min(aspect/extent.x,1.0/extent.y)*p.a.y;
        float2 q = (uv-0.5-p.a.zw*0.5)*float2(aspect,1)/fit;
        q = float2(c*q.x+s*q.y,-s*q.x+c*q.y);
        float2 st = q/float2(sourceAspect,1)*p.b.xy+0.5;
        col = all(st>=0) && all(st<=1) ? source.sample(linearSampler,st).rgb : float3(0);
    } else if (op == 14) {
        float2 grid=p.a.xy, cellSize=size/grid;
        float2 cell=floor(uv*grid),center=(cell+0.5)/grid;
        float3 signal=matrixInput(source,second,center,audio,p.c.x);
#if !defined(MATRIX_FIELD) && !defined(MATRIX_CELL_FIELD)
        if(p.mode.w==1) {
            float2 stepSize=0.28/grid;
            signal=(signal+matrixInput(source,second,center+stepSize,audio,p.c.x)+matrixInput(source,second,center-stepSize,audio,p.c.x)+matrixInput(source,second,center+float2(stepSize.x,-stepSize.y),audio,p.c.x)+matrixInput(source,second,center+float2(-stepSize.x,stepSize.y),audio,p.c.x))/5;
        }
#endif
        if(p.e.x>0.5) signal=1-signal;
        float luma=dot(signal,float3(0.2126,0.7152,0.0722));
        // Light fields can exceed one: keep that exposure boost until display mapping.
        float level=pow(max((luma-p.b.z)/max(0.01,1-p.b.z),0.0),p.b.y)*p.b.x;
        float3 color=p.mode.z==0 ? matrixTint(p.d.xyz) : signal/max(0.001,max(signal.r,max(signal.g,signal.b)));
        color=mix(color,float3(1),smoothstep(0.6,1.6,level)*p.d.w);
        float2 q=(uv-center)*size;
        float radius=min(cellSize.x,cellSize.y)*p.a.z*0.5;
        float distance=length(q)-radius;
        if(p.mode.y==1) distance=max(abs(q.x),abs(q.y))-radius;
        else if(p.mode.y==2) distance=(abs(q.x)+abs(q.y)-radius)*0.7071;
        else if(p.mode.y==3) { float2 k=abs(q)-radius*0.68; distance=length(max(k,0.0))+min(max(k.x,k.y),0.0)-radius*0.32; }
        float coverage=1-smoothstep(-0.6,0.6,distance);
        float halo=exp(-max(0.0,distance)*max(0.0,distance)/max(0.5,radius*radius*0.7))*p.a.w;
        col=color*(max(level,p.b.w)*coverage+level*halo*0.35);
        // Fit overbright LEDs into SDR without clipping each channel to white.
        // Desaturation is controlled explicitly by White-hot peaks above.
        col/=max(1.0,max(col.r,max(col.g,col.b)));
    } else if (op == 13) {
        col=source.sample(linearSampler,uv).rgb;
        float2 extent=p.a.zw*size, center=(p.a.xy+p.a.zw*0.5)*size;
        float radius=min(p.b.y,min(extent.x,extent.y)*0.5);
        float2 q=abs(uv*size-center)-(extent*0.5-radius);
        float distance=length(max(q,0.0))+min(max(q.x,q.y),0.0)-radius;
        float2 sq=abs(uv*size-center-float2(0,6))-(extent*0.5-radius);
        float sd=length(max(sq,0.0))+min(max(sq.x,sq.y),0.0)-radius;
        col*=1-p.b.w*p.b.x*(1-smoothstep(-2.0,18.0,sd))*0.65;
        float2 local=(uv-p.a.xy)/p.a.zw;
        float2 st=local-0.5;
        float aspect=extent.x/extent.y, sourceAspect=float(second.get_width())/float(second.get_height());
        if(p.d.x<0.5) {
            if(sourceAspect>aspect) st.y*=sourceAspect/aspect; else st.x*=aspect/sourceAspect;
        } else if(p.d.x<1.5) {
            if(sourceAspect>aspect) st.x*=aspect/sourceAspect; else st.y*=sourceAspect/aspect;
        }
        st+=0.5;
        float3 inset=all(st>=0) && all(st<=1) ? second.sample(linearSampler,st).rgb : float3(0);
        float border=p.b.z>0 ? smoothstep(-p.b.z-0.5,-p.b.z+0.5,distance) : 0;
        inset=mix(inset,float3(1),border);
        col=mix(col,inset,(1-smoothstep(-0.5,0.5,distance))*p.b.x);
    } else if (op == 16) {
        float3 original=source.sample(linearSampler,uv).rgb;
        float3 channels=original*p.d.xyz;
        if(p.mode.y>0) channels*=float3(p.mode.y==1,p.mode.y==2,p.mode.y==3);
        float3 r=channels.r*p.a.rgb,g=channels.g*p.b.rgb,b=channels.b*p.c.rgb;
        float3 recolored=p.mode.z==1 ? 1-(1-saturate(r))*(1-saturate(g))*(1-saturate(b)) : r+g+b;
        col=mix(original,recolored,p.a.w);
    } else if (op == 12) {
        bool cmyk=p.mode.y==1;
        float2 offsets[4]={p.d.xy,p.d.zw,p.e.xy,p.e.zw};
        float weights[4]={-1,0,1,0};
        float4 channels=float4(0);
        float cs=cos(p.a.y),sn=sin(p.a.y);
        for(uint i=0;i<(cmyk ? 4u : 3u);i++) {
            float2 delta=offsets[i]+(uv-0.5)*2*p.a.z*weights[i];
            delta=float2(cs*delta.x-sn*delta.y,sn*delta.x+cs*delta.y)*p.a.x;
            float3 sample=splitSample(source,uv-delta/size,p.mode.z,cmyk);
            channels[i]=cmyk ? splitCMYK(sample)[i] : sample[i];
        }
        float3 separated=cmyk ? (1-channels.rgb)*(1-channels.a) : channels.rgb;
        col=mix(source.sample(linearSampler,uv).rgb,separated,p.a.w);
    } else if (op == 11) {
        float sourceAspect=float(source.get_width())/max(1.0,float(source.get_height()));
        float croppedAspect=sourceAspect*p.a.z/max(p.a.w,0.0001), outputAspect=size.x/size.y;
        float2 q=uv-0.5;
        if(p.b.x<0.5) {
            // Fit the selected rectangle without changing its proportions.
            if(croppedAspect>outputAspect) q.y*=croppedAspect/outputAspect;
            else q.x*=outputAspect/croppedAspect;
        } else if(p.b.x<1.5) {
            // Fill the canvas, cropping further inside the selected rectangle.
            if(croppedAspect>outputAspect) q.x*=outputAspect/croppedAspect;
            else q.y*=croppedAspect/outputAspect;
        }
        float2 local=q+0.5;
        if(p.b.z>0.5) local.x=1-local.x;
        if(p.b.w>0.5) local.y=1-local.y;
        col=all(local>=0) && all(local<=1) ? source.sample(linearSampler,p.a.xy+local*p.a.zw).rgb : float3(p.b.y);
    } else if (op == 9) {
        float c = cos(p.a.y), s = sin(p.a.y), cell = p.a.x;
        float2 screen = float2(c*(gid.x+0.5)+s*(gid.y+0.5),-s*(gid.x+0.5)+c*(gid.y+0.5))/cell;
        float2 center = (floor(screen)+0.5)*cell;
        float2 sampleUV = float2(c*center.x-s*center.y,s*center.x+c*center.y)/size;
        float3 tone = clamp((source.sample(linearSampler,sampleUV).rgb-0.5)*p.b.x+0.5,0.0,1.0);
        if (p.a.w>0.5) tone = float3(dot(tone,float3(0.2126,0.7152,0.0722)));
        float2 q = fract(screen)-0.5;
        float metric = p.a.z<0.5 ? length(q) : (p.a.z<1.5 ? abs(q.y) : abs(q.x)+abs(q.y));
        float inverseMetric = p.a.z<0.5 ? length(0.5-abs(q)) : (p.a.z<1.5 ? 0.5-abs(q.y) : 1-abs(q.x)-abs(q.y));
        float aa = 0.6/cell;
        for (uint channel=0;channel<3;channel++) {
            float t = tone[channel], area = min(t,1-t);
            float radius = p.a.z<0.5 ? sqrt(area/M_PI_F) : (p.a.z<1.5 ? area*0.5 : sqrt(area*0.5));
            float ink = 1-smoothstep(radius-aa,radius+aa,t<=0.5 ? metric : inverseMetric);
            float value = t<=0.5 ? ink : 1-ink;
            col[channel] = t<0.00001 ? 0 : (t>0.99999 ? 1 : value);
        }
        col = mix(source.sample(linearSampler,uv).rgb,col,p.b.y);
    } else if (op == 10) {
        float3 original = source.sample(linearSampler,uv).rgb;
        // Filter luminance before phase displacement to keep high-frequency
        // footage from tearing the carrier into unstable single-pixel noise.
        float3 filtered = (original*2 + source.sample(linearSampler,uv+float2(1,0)/size).rgb + source.sample(linearSampler,uv-float2(1,0)/size).rgb)*0.25;
        float luma = dot(filtered,float3(0.2126,0.7152,0.0722));
        float coordinate = dot(float2(gid)+0.5,float2(sin(p.a.w),cos(p.a.w)));
        float phase = coordinate/p.a.x + p.a.y*luma/(2*M_PI_F);
        float distance = abs(fract(phase)-0.5)*2;
        float aa = min(0.4,1/p.a.x);
        float beam = 1-smoothstep(p.a.z-aa,p.a.z+aa,distance);
        float3 color = p.b.x>0.5 ? float3(luma) : original;
        col = mix(original,color*beam*min(2.5,1/p.a.z),p.b.y);
    } else if (op == 2) {
        float2 q = uv * 2 - 1;
        q *= 1 + p.a.y * float2(q.y*q.y, q.x*q.x) * 0.28;
        float2 st = q * 0.5 + 0.5;
        if (all(st >= 0) && all(st <= 1)) {
            float dx = p.a.z / size.x;
            col = float3(source.sample(linearSampler, st + float2(dx,0)).r, source.sample(linearSampler, st).g, source.sample(linearSampler, st - float2(dx,0)).b);
            float3 blur = (source.sample(linearSampler, st+float2(3,0)/size).rgb + source.sample(linearSampler, st-float2(3,0)/size).rgb + source.sample(linearSampler, st+float2(0,3)/size).rgb + source.sample(linearSampler, st-float2(0,3)/size).rgb) * 0.25;
            col += blur * blur * p.a.w * 0.5;
            col *= 1 - p.a.x * (0.5 + 0.5 * cos(st.y * size.y * M_PI_F * 0.6667));
            float3 mask(0.83); mask[gid.x % 3] = 1;
            col *= mix(float3(1), mask, p.a.x);
            col *= 1 - p.b.x * dot(q, q) * 0.55;
            float noise = fract(sin(dot(float2(gid),float2(12.9898,78.233)) + p.c.x * 91) * 43758.5453);
            col += (noise - 0.5) * p.b.y;
        }
    } else if (op == 3) {
        if(uint(p.a.y)==4) {
            float4 background=source.sample(linearSampler,uv);
            float2 st=(uv-0.5-p.b.xy)/max(p.b.z,0.1)+0.5;
            float4 foreground=all(st>=0) && all(st<=1) ? second.sample(linearSampler,st):float4(0);
            // Premultiplied source-over keeps transparent pixels and edge coverage intact.
            foreground*=p.a.x;
            float4 result=foreground+background*(1.0-foreground.a);
            output.write(clamp(result,0.0,1.0),gid);
            return;
        }
        float3 a = source.sample(linearSampler, uv).rgb, b = second.sample(linearSampler, uv).rgb;
        uint mode = uint(p.a.y);
        float3 combined = mode == 1 ? a + b : (mode == 2 ? a * b : (mode == 3 ? 1 - (1-a)*(1-b) : b));
        col = mix(a, combined, p.a.x);
    } else if (op == 4) {
        float3 original = source.sample(linearSampler, uv).rgb;
        // Input levels, exposure, white balance.
        col = saturate((original - p.b.x) / max(0.001, p.b.y - p.b.x));
        col = pow(col, float3(1.0 / max(0.01, p.b.z))) * exp2(p.a.x);
        col *= float3(1.0 + 0.35*p.c.z + 0.15*p.c.w, 1.0 - 0.25*p.c.w, 1.0 - 0.35*p.c.z + 0.15*p.c.w);
        // Brightness, contrast, saturation.
        col = (col + p.a.w - 0.5) * p.a.z + 0.5;
        col = mix(float3(dot(col, float3(0.2126,0.7152,0.0722))), col, p.a.y);
        // Hue: rotate about the gray axis.
        float hc = cos(p.b.w), hs = sin(p.b.w);
        col = col*hc + cross(float3(0.57735), col)*hs + float3(0.57735)*dot(float3(0.57735), col)*(1.0 - hc);
        // Output levels, invert.
        col = mix(float3(p.c.x), float3(p.c.y), saturate(col));
        if (p.mode.y == 1) col = 1.0 - col;
        col = mix(original, col, p.d.x);

    } else if (op == 15) {
        // Monochrome analysis texture: white signal on exact black for masks.
        if(p.mode.y>=3) {
            float value=0, px=max(1.0,p.a.x);
            if(p.mode.y==3) {
                // Radial: spectrum mirrored around a ring, lows at the top.
                float2 q=(uv-0.5)*float2(size.x/size.y,1);
                float r=length(q),f=atan2(abs(q.x),-q.y)/M_PI_F,x=f*511;
                uint index=min(510u,uint(x));
                float level=mix(audio[index],audio[index+1],fract(x)),ring=0.2+level*0.24;
                if(level>0.0001) {
                    value=1-smoothstep(px*0.5,px*0.5+1,abs(r-ring)*size.y);
                    if(p.a.y>0.5 && r>=0.2 && r<=ring) value=1;
                }
                if(p.a.z>0.5) value=max(value,0.6*(1-smoothstep(0.5,1.5,abs(r-0.2)*size.y)));
            } else if(p.mode.y==4) {
                // Bars: rounded capsules mirrored about the center line.
                float slots=max(1.0,p.b.x),sx=uv.x*slots,slot=floor(sx),level=0;
                for(int k=0;k<4;k++) {
                    float x=min(511.0,(slot+(float(k)+0.5)*0.25)/slots*511);
                    uint index=min(510u,uint(x));
                    level=max(level,mix(audio[index],audio[index+1],fract(x)));
                }
                if(level>0.0001) {
                    float slotWidth=size.x/slots,halfWidth=p.a.y>0.5 ? 0.32*slotWidth : px*0.5;
                    float dx=abs(fract(sx)-0.5)*slotWidth,dy=max(0.0,(abs(uv.y-0.5)-level*0.46)*size.y);
                    value=1-smoothstep(-0.5,0.5,length(float2(dx,dy))-halfWidth);
                }
                if(p.a.z>0.5) value=max(value,0.6*(1-smoothstep(0.5,1.5,abs(uv.y-0.5)*size.y)));
            } else {
                // Ridgelines: recent spectra stacked front to back; nearer ridges occlude farther ones.
                // Only ridges that can reach this pixel are sampled.
                float lines=max(2.0,p.b.y),front=0.92,spacing=0.78/(lines-1),height=0.2,th=(px*0.5+1)/size.y;
                // Lows sit at the center; squaring the mirrored axis keeps the seam smooth.
                float s0=abs(uv.x-0.5)*2,s1=abs(uv.x+1/size.x-0.5)*2,f0=s0*s0,f1=s1*s1;
                float taper0=1-f0*f0,taper1=1-f1*f1;
                int first=max(0,int(ceil((front-height-th-uv.y)/spacing))),last=min(int(lines)-1,int(floor((front+th-uv.y)/spacing)));
                for(int k=first;k<=last;k++) {
                    float base=front-float(k)*spacing,u=1-(float(k)+0.5)/lines;
                    float ridge=base-source.sample(linearSampler,float2(u,1-f0)).r*taper0*height;
                    float slope=(ridge-(base-source.sample(linearSampler,float2(u,1-f1)).r*taper1*height))*size.y;
                    // Perpendicular distance keeps steep flanks as thick as flat lines.
                    float distance=abs(uv.y-ridge)*size.y*rsqrt(1+slope*slope);
                    value=max(value,1-smoothstep(px*0.5,px*0.5+1,distance));
                    if(uv.y>ridge) break;
                }
            }
            col=float3(value);
        } else {
        float margin=p.a.z>0.5 ? 0.06 : 0.0;
        float2 q=(uv-margin)/(1-2*margin);
        float value=0;
        if(all(q>=0) && all(q<=1)) {
            if(p.mode.y==2) value=source.sample(linearSampler,q).r;
            else {
                float x=q.x*511;
                uint index=min(510u,uint(x));
                float sample=mix(audio[index],audio[index+1],fract(x));
                float y=p.mode.y==0 ? 0.5-sample*0.46 : 1-sample*0.94;
                float distance=abs(q.y-y)*size.y*(1-2*margin);
                // Silence has no painted baseline; axes are an independent option.
                if(p.mode.y==0 || sample>0.0001) {
                    value=1-smoothstep(p.a.x*0.5,p.a.x*0.5+1,distance);
                    if(p.mode.y==1 && p.a.y>0.5 && q.y>=y) value=1;
                }
            }
            if(p.a.w>0.5) {
                float2 cells=abs(fract(q*float2(10,4)+0.5)-0.5)/(float2(10,4))*size*(1-2*margin);
                value=max(value,0.15*(1-smoothstep(0.5,1.5,min(cells.x,cells.y))));
            }
        }
        if(p.a.z>0.5) {
            float baseline=p.mode.y==0 ? 0.5 : 1.0;
            float dx=abs(q.x)*size.x*(1-2*margin),dy=abs(q.y-baseline)*size.y*(1-2*margin);
            if((q.y>=0 && q.y<=1 && dx<2) || (q.x>=0 && q.x<=1 && dy<2)) value=max(value,0.6);
        }
        col=float3(value);
        }
    } else if (op == 5) {
        float x = uv.x * 511;
        uint index = min(510u,uint(x));
        float amplitude = mix(audio[index],audio[index+1],fract(x));
        float y = 0.5 - clamp(amplitude*p.a.x,-1.0,1.0)*0.45;
        float line = 1.0-smoothstep(p.a.z,p.a.z+1,abs(uv.y-y)*size.y);
        float3 tint = clamp(abs(fract(p.a.y+float3(0,2.0/3,1.0/3))*6-3)-1,0.0,1.0);
        col = mix(float3(0.015),mix(float3(0.3),tint,0.8),line);
    } else { col = source.sample(linearSampler, uv).rgb; }
    output.write(float4(clamp(col, 0.0, 1.0), 1), gid);
}
struct VertexOut { float4 position [[position]]; float2 uv; };
vertex VertexOut fullscreen(uint id [[vertex_id]]) {
    float2 uv = float2((id << 1) & 2, id & 2);
    return {float4(uv * float2(2,-2) + float2(-1,1),0,1), uv};
}
fragment float4 preview(VertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]], constant float &aspect [[buffer(0)]]) {
    return float4(fitSample(tex, in.uv, aspect),1);
}

struct GeometryParams { float4 camera; float4 style; };
struct GeometryOut { float4 position [[position]]; float4 color; };
float3 hsv(float3 c) {
    float3 p = abs(fract(c.xxx + float3(0,2.0/3,1.0/3))*6-3);
    return c.z * mix(float3(1), clamp(p-1,0.0,1.0),c.y);
}
vertex GeometryOut geometryVertex(uint id [[vertex_id]], constant float4 *points [[buffer(0)]], constant GeometryParams &p [[buffer(1)]]) {
    float4 point = points[id]; float3 v = point.xyz * p.camera.z;
    float a = p.camera.x * p.camera.y;
    v.xz = float2(cos(a)*v.x + sin(a)*v.z, -sin(a)*v.x + cos(a)*v.z);
    float pitch = -0.18;
    v.yz = float2(cos(pitch)*v.y-sin(pitch)*v.z,sin(pitch)*v.y+cos(pitch)*v.z);
    float depth = 3.2-v.z;
    float3 color = hsv(float3(fract(p.style.x + point.w*0.28),0.68, p.style.y));
    float pulse = 0.55+0.45*pow(0.5+0.5*sin(point.w*18-p.camera.x*0.8),2.0);
    return {float4(v.x*4.2/p.camera.w,v.y*4.2,0.5,depth),float4(color*pulse,0.8)};
}
fragment float4 geometryFragment(GeometryOut in [[stage_in]]) { return in.color; }

float3 glowLinear(float3 c) { return select(c/12.92,pow((c+0.055)/1.055,float3(2.4)),c>0.04045); }
float3 glowSRGB(float3 c) { c=max(c,0.0); return select(c*12.92,1.055*pow(c,float3(1.0/2.4))-0.055,c>0.0031308); }
kernel void glowExtract(texture2d<float,access::sample> source [[texture(0)]],texture2d<float,access::write> target [[texture(1)]],constant float4 &p [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
    if (gid.x>=target.get_width() || gid.y>=target.get_height()) return;
    float2 uv=(float2(gid)+0.5)/float2(target.get_width(),target.get_height());
    float2 texel=0.5/float2(source.get_width(),source.get_height());
    float3 v=0;
    for (int y=-1;y<=1;y+=2) for (int x=-1;x<=1;x+=2) {
        float3 sample=glowLinear(source.sample(linearSampler,uv+float2(x,y)*texel).rgb);
        float bright=max(sample.r,max(sample.g,sample.b));
        float soft=clamp(bright-p.x+p.y,0.0,2*p.y); soft=soft*soft/(4*p.y+1e-5);
        v+=sample*max(bright-p.x,soft)/max(bright,1e-5)*0.25;
    }
    target.write(float4(v,1),gid);
}
kernel void glowCombine(texture2d<float,access::sample> source [[texture(0)]],texture2d<float,access::sample> narrow [[texture(1)]],texture2d<float,access::sample> broad [[texture(2)]],texture2d<float,access::write> target [[texture(3)]],constant float4 &p [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
    if (gid.x>=target.get_width() || gid.y>=target.get_height()) return;
    float2 uv=(float2(gid)+0.5)/float2(target.get_width(),target.get_height());
    float3 original=source.sample(linearSampler,uv).rgb;
    float3 halo=narrow.sample(linearSampler,uv).rgb*0.35+broad.sample(linearSampler,uv).rgb*0.65;
    halo=max(0.0,mix(float3(dot(halo,float3(0.2126,0.7152,0.0722))),halo,p.w));
    target.write(float4(p.z==0 ? original : clamp(glowSRGB(glowLinear(original)+halo*p.z),0.0,1.0),1),gid);
}

kernel void faceDownsample(texture2d<float,access::sample> source [[texture(0)]],
                           texture2d<float,access::write> target [[texture(1)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= target.get_width() || p.y >= target.get_height()) return;
    float2 uv = (float2(p)+0.5)/float2(target.get_width(),target.get_height());
    target.write(source.sample(linearSampler,uv),p);
}
kernel void faceBoxes(texture2d<float,access::sample> source [[texture(0)]],
                      texture2d<float,access::write> target [[texture(1)]],
                      constant float4 *rects [[buffer(0)]], constant uint &count [[buffer(1)]],
                      constant float &thickness [[buffer(2)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= target.get_width() || p.y >= target.get_height()) return;
    float2 size = float2(target.get_width(),target.get_height()), pixel = float2(p)+0.5;
    float4 color = source.sample(linearSampler,pixel/size);
    for (uint i=0;i<count;i++) {
        float2 lo=rects[i].xy*size, hi=(rects[i].xy+rects[i].zw)*size;
        if (all(pixel >= lo) && all(pixel <= hi) && min(min(pixel.x-lo.x,hi.x-pixel.x),min(pixel.y-lo.y,hi.y-pixel.y)) < thickness)
            color=float4(0.2,1.0,0.4,1.0);
    }
    target.write(color,p);
}

struct FaceReplaceParams { float4 rowX; float4 rowY; float4 bounds; float4 controls; };
kernel void faceReplace(texture2d<float,access::sample> a [[texture(0)]],
                        texture2d<float,access::sample> b [[texture(1)]],
                        texture2d<float,access::write> target [[texture(2)]],
                        constant FaceReplaceParams *replacements [[buffer(0)]],
                        constant uint &count [[buffer(1)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= target.get_width() || p.y >= target.get_height()) return;
    float2 uv=(float2(p)+0.5)/float2(target.get_width(),target.get_height());
    float4 base=a.sample(linearSampler,uv);
    float3 position=float3(uv,1);
    for (uint i=0;i<count;i++) {
        constant FaceReplaceParams &u=replacements[i];
        if (u.controls.x <= 0) continue;
        float2 donorUV=float2(dot(u.rowX.xyz,position),dot(u.rowY.xyz,position));
        float2 local=(donorUV-u.bounds.xy)/u.bounds.zw;
        // A soft face-shaped oval avoids transferring a rectangular patch of background.
        float radius=length((local-float2(0.5,0.5))/float2(0.5,0.52));
        float mask=(1-smoothstep(1-u.controls.y,1.0,radius))*u.controls.x;
        if (any(donorUV < 0) || any(donorUV > 1)) mask=0;
        if (mask <= 0) continue;
        float4 donor=b.sample(linearSampler,donorUV);
        base.rgb=mix(base.rgb,donor.rgb,mask);
    }
    target.write(base,p);
}

struct DitherParams { float4 render; float4 preparation; float4 tone; float4 mapping; float4 high; float4 mid; float4 low; float4 background; };
constexpr sampler ditherNearest(coord::normalized,address::clamp_to_edge,filter::nearest);
float ditherCubic(float x) {
    x=abs(x);
    return x<1 ? 1.5*x*x*x-2.5*x*x+1 : (x<2 ? -0.5*x*x*x+2.5*x*x-4*x+2 : 0);
}
float ditherHash(float2 p,float seed) { return fract(sin(dot(p,float2(127.1,311.7))+seed*17.31)*43758.5453); }
kernel void ditherResample(texture2d<float,access::sample> source [[texture(0)]],texture2d<float,access::write> target [[texture(1)]],constant DitherParams &p [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=target.get_width() || gid.y>=target.get_height()) return;
    float2 size=float2(target.get_width(),target.get_height()), sourceSize=float2(source.get_width(),source.get_height());
    float2 uv=(float2(gid)+0.5)/size;
    float4 color;
    if(p.render.x>2.5) color=source.sample(ditherNearest,uv);
    else if(p.render.x>1.5) color=source.sample(linearSampler,uv);
    else if(p.render.x>0.5) {
        float2 pos=uv*sourceSize-0.5, origin=floor(pos), f=fract(pos); color=0;
        for(int y=-1;y<=2;y++) for(int x=-1;x<=2;x++) color+=source.sample(linearSampler,(origin+float2(x,y)+0.5)/sourceSize)*ditherCubic(float(x)-f.x)*ditherCubic(float(y)-f.y);
        color=clamp(color,0.0,1.0);
    } else {
        // Edge-aware footprint filter. Unlike an ordinary box average, reduce
        // contributions across strong color edges while suppressing aliasing.
        float4 center=source.sample(linearSampler,uv); float4 sum=0; float total=0;
        float2 footprint=max(sourceSize/size,float2(1));
        for(int y=0;y<4;y++) for(int x=0;x<4;x++) {
            float2 q=(float2(x,y)+0.5)/4-0.5;
            float4 v=source.sample(linearSampler,uv+q*footprint/sourceSize);
            float weight=exp(-dot(v.rgb-center.rgb,v.rgb-center.rgb)*10.0);
            sum+=v*weight; total+=weight;
        }
        color=sum/max(total,1e-6);
    }
    target.write(color,gid);
}
kernel void ditherDenoise(texture2d<float,access::sample> source [[texture(0)]],texture2d<float,access::write> target [[texture(1)]],constant DitherParams &p [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=target.get_width() || gid.y>=target.get_height()) return;
    float2 size=float2(target.get_width(),target.get_height()), uv=(float2(gid)+0.5)/size;
    float4 center=source.sample(linearSampler,uv), sum=0; float weightSum=0;
    float sigma=mix(0.025,0.32,p.preparation.z);
    for(int y=-2;y<=2;y++) for(int x=-2;x<=2;x++) {
        float4 v=source.sample(linearSampler,uv+float2(x,y)/size);
        float weight=exp(-float(x*x+y*y)/5.0-dot(v.rgb-center.rgb,v.rgb-center.rgb)/(2*sigma*sigma));
        sum+=v*weight; weightSum+=weight;
    }
    target.write(mix(center,sum/max(weightSum,1e-6),p.preparation.z),gid);
}
kernel void ditherPrepare(texture2d<float,access::sample> source [[texture(0)]],texture2d<float,access::sample> blurred [[texture(1)]],texture2d<float,access::write> target [[texture(2)]],constant DitherParams &p [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=target.get_width() || gid.y>=target.get_height()) return;
    float2 uv=(float2(gid)+0.5)/float2(target.get_width(),target.get_height());
    float4 original=source.sample(linearSampler,uv);
    float3 v=original.rgb+(original.rgb-blurred.sample(linearSampler,uv).rgb)*p.preparation.x;
    v=(v-0.5)*p.tone.y+0.5+p.tone.x;
    v=pow(clamp(v,0.0,1.0),float3(1/max(0.01,p.tone.z)));
    v+=(ditherHash(float2(gid),p.preparation.w)-0.5)*p.preparation.y;
    target.write(float4(clamp(v,0.0,1.0),original.a),gid);
}
float ditherThreshold(float2 pos,constant DitherParams &p) {
    float c=cos(p.render.w),s=sin(p.render.w);
    float2 point=float2(c*pos.x+s*pos.y,-s*pos.x+c*pos.y);
    int2 pixel=int2(floor(point)); uint algorithm=uint(p.render.y);
    if(algorithm<=2) {
        uint rank=0,bits=algorithm+1,n=1u<<bits;
        uint2 coord=uint2(pixel);
        for(uint bit=0;bit<bits;bit++) { uint x=(coord.x>>bit)&1u,y=(coord.y>>bit)&1u; rank=rank*4u+(x^y)*2u+y; }
        return (float(rank)+0.5)/float(n*n);
    }
    if(algorithm==3) {
        // Ranked, periodic clustered-dot tile with uniform threshold coverage.
        constexpr uint ranks[64]={60,52,44,36,37,45,53,61,51,28,20,12,13,21,29,54,43,19,8,4,5,9,22,46,35,11,3,0,1,6,14,38,34,10,2,7,15,23,30,39,42,18,17,16,24,25,31,47,50,27,26,32,33,40,41,55,59,58,57,56,48,49,62,63};
        return (float(ranks[(uint(pixel.y)&7u)*8u+(uint(pixel.x)&7u)])+0.5)/64;
    }
    if(algorithm==4) return (float(uint(pixel.y)&7u)+0.5)/8;
    return clamp(ditherHash(float2(pixel),p.preparation.w),0.0001,0.9999);
}
kernel void ditherQuantize(texture2d<float,access::sample> prepared [[texture(0)]],texture2d<float,access::sample> source [[texture(1)]],texture2d<float,access::write> target [[texture(2)]],constant DitherParams &p [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=target.get_width() || gid.y>=target.get_height()) return;
    float2 uv=(float2(gid)+0.5)/float2(target.get_width(),target.get_height());
    float2 samplePixel=floor(uv*float2(prepared.get_width(),prepared.get_height()));
    float4 v=prepared.sample(ditherNearest,uv), original=source.sample(linearSampler,uv);
    float threshold=ditherThreshold(samplePixel,p), steps=max(1.0,p.render.z-1);
    float luma=dot(v.rgb,float3(0.2126,0.7152,0.0722));
    float value=clamp((luma-p.low.w)/max(0.001,p.high.w-p.low.w),0.0,1.0);
    float3 bg=p.mapping.y<0.5 ? float3(0) : (p.mapping.y<1.5 ? float3(1) : (p.mapping.y<2.5 ? p.background.rgb : original.rgb));
    float3 color;
    if(p.mapping.x<0.5) color=(floor(v.rgb*steps)+step(float3(threshold),fract(v.rgb*steps)))/steps;
    else if(p.mapping.x<1.5) color=float3((floor(value*steps)+step(threshold,fract(value*steps)))/steps);
    else if(p.mapping.x<2.5) {
        float amount=(floor(value*steps)+step(threshold,fract(value*steps)))/steps;
        color=mix(bg,p.high.rgb,amount);
    } else if(p.mapping.x<3.5) color=value>threshold ? p.high.rgb : p.low.rgb;
    else {
        float middle=clamp((p.mid.w-p.low.w)/max(0.001,p.high.w-p.low.w),0.01,0.99);
        if(value<middle) color=value/middle>threshold ? p.mid.rgb : p.low.rgb;
        else color=(value-middle)/(1-middle)>threshold ? p.high.rgb : p.mid.rgb;
    }
    color=mix(bg,color,v.a);
    target.write(float4(clamp(mix(original.rgb,color,p.tone.w),0.0,1.0),original.a),gid);
}

// Preserve the full input canvas with symmetric padding, matching pose decoding.
kernel void poseLetterbox(texture2d<float,access::sample> source [[texture(0)]],
                          texture2d<float,access::write> target [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=target.get_width() || gid.y>=target.get_height()) return;
    float2 sourceSize=float2(source.get_width(),source.get_height());
    float2 targetSize=float2(target.get_width(),target.get_height());
    float scale=min(targetSize.x/sourceSize.x,targetSize.y/sourceSize.y);
    float2 fitted=sourceSize*scale, padding=(targetSize-fitted)*0.5;
    float2 uv=(float2(gid)+0.5-padding)/fitted;
    float3 rgb=any(uv<0.0) || any(uv>1.0) ? float3(114.0/255.0) : source.sample(linearSampler,uv).rgb;
    target.write(float4(rgb,1),gid);
}
struct PoseStroke { float4 endpoints; float4 color; float4 style; float4 detail; };
struct PoseVertexOut {
    float4 position [[position]];
    float2 pixel;
    float4 endpoints [[flat]];
    float4 color [[flat]];
    float4 style [[flat]];
    float4 detail [[flat]];
};
vertex PoseVertexOut poseVertex(uint vertexID [[vertex_id]], uint instance [[instance_id]],
                                const device PoseStroke *strokes [[buffer(0)]], constant float2 &viewport [[buffer(1)]]) {
    constexpr float2 corners[6]={float2(0,0),float2(1,0),float2(0,1),float2(0,1),float2(1,0),float2(1,1)};
    PoseStroke s=strokes[instance];
    float extent=s.style.x+1+(s.style.w>0 ? s.style.z*2 : 0);
    float2 lo=min(s.endpoints.xy,s.endpoints.zw)-extent;
    float2 hi=max(s.endpoints.xy,s.endpoints.zw)+extent;
    float2 pixel=mix(lo,hi,corners[vertexID]);
    PoseVertexOut out;
    out.position=float4(pixel.x/viewport.x*2-1,1-pixel.y/viewport.y*2,0,1);
    out.pixel=pixel; out.endpoints=s.endpoints; out.color=s.color; out.style=s.style; out.detail=s.detail;
    return out;
}
fragment float4 poseFragment(PoseVertexOut in [[stage_in]]) {
    float2 a=in.endpoints.xy, b=in.endpoints.zw, delta=b-a;
    float t=clamp(dot(in.pixel-a,delta)/max(dot(delta,delta),1e-6),0.0,1.0);
    float2 relative=in.pixel-mix(a,b,t);
    float distance=in.detail.w>0.5 ? abs(relative.x)+abs(relative.y) : length(relative);
    float sdf=in.style.y>0 ? abs(distance-(in.style.x-in.style.y*0.5))-in.style.y*0.5 : distance-in.style.x;
    float alpha=1-smoothstep(-0.75,0.75,sdf);
    if(in.style.w>0) {
        float spread=max(1.0,in.style.z*0.6), outside=max(0.0,sdf);
        float halo=min(0.8,in.style.w*0.22)*exp(-outside*outside/(2*spread*spread));
        alpha=max(alpha,halo);
    }
    if(in.detail.x>0 && in.detail.y>0) {
        float along=t*length(delta)+in.detail.z;
        float phase=fract(along/(in.detail.x+in.detail.y))*(in.detail.x+in.detail.y);
        alpha*=1-smoothstep(in.detail.x-0.75,in.detail.x+0.75,phase);
    }
    return float4(in.color.rgb,alpha*in.color.a);
}

// Tiny, asynchronous GPU readback for typed palette extraction.
kernel void paletteSample(texture2d<float,access::sample> source [[texture(0)]],
                          device float4 *samples [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x>=32 || gid.y>=32) return;
    samples[gid.y*32+gid.x]=source.sample(linearSampler,(float2(gid)+0.5)/32.0);
}
kernel void palettePreview(texture2d<float,access::write> target [[texture(0)]],
                           constant float4 *colors [[buffer(0)]], constant uint &count [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x>=target.get_width() || gid.y>=target.get_height()) return;
    uint index=count>0 ? min(count-1,gid.x*count/target.get_width()) : 0;
    target.write(count>0 ? colors[index] : float4(0,0,0,1),gid);
}

kernel void videoCollectionPreview(array<texture2d<float, access::sample>, 8> inputs [[texture(0)]],
                                   texture2d<float, access::write> output [[texture(8)]],
                                   constant uint4 &info [[buffer(0)]], constant float &brightness [[buffer(1)]],
                                   uint2 p [[thread_position_in_grid]]) {
    if (p.x >= output.get_width() || p.y >= output.get_height()) return;
    float2 size=float2(output.get_width(),output.get_height());
    uint columns=max(1u,uint(ceil(sqrt(float(info.y)*size.x/size.y))));
    uint rows=max(1u,(info.y+columns-1)/columns);
    float2 cell=(float2(p)+0.5)/size*float2(columns,rows);
    uint face=uint(cell.y)*columns+uint(cell.x);
    float2 uv=(fract(cell)-0.04)/0.92;
    float4 color=float4(0,0,0,1);
    if (info.x>0 && face<info.y && all(uv>=0) && all(uv<=1)) {
        uint index=face%info.x;
        float aspect=(size.x/columns)/(size.y/rows);
        float sourceAspect=float(inputs[index].get_width())/float(inputs[index].get_height());
        float2 q=uv-0.5;
        if (info.z==0) { if(sourceAspect>aspect) q.y*=sourceAspect/aspect; else q.x*=aspect/sourceAspect; }
        if (info.z==1) { if(sourceAspect>aspect) q.x*=aspect/sourceAspect; else q.y*=sourceAspect/aspect; }
        q+=0.5;
        if (all(q>=0) && all(q<=1)) { color=inputs[index].sample(linearSampler,q);color.rgb*=brightness;color.a=1; }
    }
    output.write(color,p);
}

// Eight independent additive contributions; no normalization or layer occlusion.
kernel void muxVideos(array<texture2d<float, access::sample>, 8> inputs [[texture(0)]],
                      texture2d<float, access::write> output [[texture(8)]],
                      constant float* levels [[buffer(0)]], constant uint* modes [[buffer(1)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= output.get_width() || p.y >= output.get_height()) return;
    float2 uv = (float2(p)+0.5)/float2(output.get_width(),output.get_height());
    float aspect = float(output.get_width())/float(output.get_height());
    float3 sum = 0;
    for (uint i=0;i<8;i++) {
        if (levels[i] <= 0 || modes[i]!=0) continue;
        float sourceAspect = float(inputs[i].get_width())/float(inputs[i].get_height());
        float2 q = uv-0.5;
        if (sourceAspect > aspect) q.y *= sourceAspect/aspect; else q.x *= aspect/sourceAspect;
        q += 0.5;
        if (any(q < 0) || any(q > 1)) continue;
        float4 sample = inputs[i].sample(linearSampler,q);
        sum += sample.rgb * sample.a * levels[i];
    }
    sum=clamp(sum,0.0,1.0);
    for(uint i=0;i<8;i++)if(modes[i]==1 && levels[i]>0){
        float mask=dot(inputs[i].sample(linearSampler,uv).rgb,float3(.2126,.7152,.0722));
        sum*=mix(1.f,clamp(mask,0.f,1.f),clamp(levels[i],0.f,1.f));
    }
    output.write(float4(sum,1),p);
}

// Collection previews use the same CPU face evaluator as VJ, with sample geometry only.
kernel void collectionPreview(texture2d<float,access::sample> video [[texture(0)]],
 texture2d<float,access::write> output [[texture(1)]],constant float4* colors [[buffer(0)]],
 constant uint4& info [[buffer(1)]],constant float2& glow [[buffer(2)]],uint2 pos [[thread_position_in_grid]]) {
 if(pos.x>=output.get_width()||pos.y>=output.get_height())return;
 float2 uv=(float2(pos)+.5)/float2(output.get_width(),output.get_height());
 uint cols=uint(ceil(sqrt(float(info.x)*16.0/9.0))),rows=(info.x+cols-1)/cols;
 float2 cell=uv*float2(cols,rows);uint face=uint(cell.y)*cols+uint(cell.x);
 float2 local=fract(cell);float4 c=0;
 if(face<info.x&&all(local>float2(.04))&&all(local<float2(.96))) {
   c=colors[face];
   if(info.z){float2 p=(local-.04)/.92*2-1;float center=pow(max(0.f,(1-p.x*p.x)*(1-p.y*p.y)),glow.y);c.rgb*=mix(1.f,center,glow.x);}
   if(info.y){constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);c=video.sample(s,local)*c.a;}
   c.a=1;
 }
 output.write(c,pos);
}

// Preview only: particle positions come from the same 3D evaluator as VJ/LEDs.
kernel void graphParticlePreview(texture2d<float,access::write> output [[texture(0)]],
 constant float4* particles [[buffer(0)]],constant uint4& info [[buffer(1)]],uint2 pos [[thread_position_in_grid]]) {
 if(pos.x>=output.get_width()||pos.y>=output.get_height())return;
 float2 uv=(float2(pos)+.5)/float2(output.get_width(),output.get_height());
 float2 cell=uv*float2(info.z,info.w),local=fract(cell);uint face=uint(cell.y)*info.z+uint(cell.x);
 float3 rgb=0;
 if(face<info.x&&all(local>float2(.025))&&all(local<float2(.975))) {
  rgb=float3(info.y>0&&particles[2].y>0 ? .24:.012);
  for(uint i=0;i<info.y;i++)if(uint(particles[i*3+2].x)==face){
   float4 p=particles[i*3],c=particles[i*3+1];float2 delta=(local-p.xy)/max(p.zw,float2(.0001));float d=dot(delta,delta);
   if(d>9)continue;
   if(particles[i*3+2].y>0){
    float r=sqrt(d);
    if(particles[i*3+2].y>2.5){
     // Defocused glass tile. The preview has no backdrop to refract, so it frosts the face.
     float2 q=abs(delta)-.68;float sd=length(max(q,0.0))+min(max(q.x,q.y),0.0)-.17;
     float soft=.03+.22*particles[i*3+2].z,coverage=(1-smoothstep(-soft,soft,sd))*c.a;
     float rim=exp(-pow(sd/(soft+.04),2.0))*.22,sheen=.06*smoothstep(.8,-.8,delta.x+delta.y);
     rgb=mix(rgb,rgb*1.15+.04+sheen+rim,coverage);
    }else if(particles[i*3+2].y>1.5){
     float2 radiusPixels=p.zw*float2(output.get_width(),output.get_height())/float2(info.z,info.w);
     float aa=.5/max(.5,min(radiusPixels.x,radiusPixels.y));
     float coverage=1-smoothstep(.62-aa,.62+aa,r);
     rgb*=1-coverage*c.a;
    }else{
     float body=1-smoothstep(.42,.72,r),rim=exp(-pow((r-.82)*4.5,2.0))*particles[i*3+2].z;
     float a=min(.98,body*.98+rim*.3)*c.a;float3 tint=mix(float3(dot(c.rgb,float3(.2126,.7152,.0722))),c.rgb,.18);
     rgb=rgb*(1-a)+(float3(.002)*body+tint*rim*.35)*c.a;
    }
   }else{float a=min(1.0,exp(-d*2.5)*1.15)*c.a;rgb=mix(rgb,mix(c.rgb,float3(1),.35*exp(-d*16)),a);}
  }
 }
 output.write(float4(rgb,1),pos);
}

// Graph Clouds preview. Mirrors PatchClouds.h and the VJ collection shader:
// strips are polylines in canvas-height units; faces are a grid of cards.
// sky.w selects a painted sky; clear skies preview over the dark face.
float cloudHash(int2 c) { uint x=uint(c.x)*73856093u^uint(c.y)*19349663u; x^=x>>16; x*=0x7feb352du; x^=x>>15; x*=0x846ca68bu; x^=x>>16; return float(x%65536u)/65535.0; }
float cloudNoise(float2 p) {
 float2 i=floor(p),f=fract(p);f=f*f*(3-2*f);int2 c=int2(i);
 float a=cloudHash(c),b=cloudHash(c+int2(1,0)),d=cloudHash(c+int2(0,1)),e=cloudHash(c+int2(1,1));
 return a+(b-a)*f.x+(d-a)*f.y+(a-b-d+e)*f.x*f.y;
}
float cloudFbm(float2 p) { float v=0,a=.5;for(int i=0;i<4;i++){v+=a*cloudNoise(p);p=p*2.03+float2(17.1,9.7);a*=.5;}return v/.9375; }
struct CloudUniforms { float4 sky; float4 shape; float4 motion; uint4 info; float4 extra; };
kernel void graphCloudPreview(texture2d<float,access::write> output [[texture(0)]],
 constant float4* streaks [[buffer(0)]],constant CloudUniforms& u [[buffer(1)]],uint2 pos [[thread_position_in_grid]]) {
 if(pos.x>=output.get_width()||pos.y>=output.get_height())return;
 float2 size=float2(output.get_width(),output.get_height()),uv=(float2(pos)+.5)/size;
 float2 cell=uv*float2(u.info.y,u.info.z),local=fract(cell);uint face=uint(cell.y)*u.info.y+uint(cell.x);
 if(face>=u.info.x||any(local<float2(.025))||any(local>float2(.975))){output.write(float4(0,0,0,1),pos);return;}
 float2 p=float2(uv.x*size.x/size.y,uv.y);float time=u.motion.w;
 float sum=0,weight=1e-5;float3 tint=streaks[4].rgb*streaks[4].rgb*1e-5;
 for(uint i=0;i<u.info.w;i++){
  constant float4* s=streaks+i*5;
  float2 pts[6]={s[0].xy,s[0].zw,s[1].xy,s[1].zw,s[2].xy,s[2].zw};
  float nearest=1e9,along=0,side=0,cum=0;
  for(int k=0;k<5;k++){float2 d=pts[k+1]-pts[k];float l2=dot(d,d),l=sqrt(l2);
   float t=l2>1e-12?clamp(dot(p-pts[k],d)/l2,0.0,1.0):0;float2 r=p-pts[k]-d*t;float dist=length(r);
   if(dist<nearest){nearest=dist;along=cum+t*l;side=l>1e-9?(d.x*r.y-d.y*r.x)/l:0;}cum+=l;}
  float a=cum>1e-9?along/cum:0,profile=pow(max(0.0,sin(3.14159265*clamp(a*.92+.04,0.0,1.0))),.6);
  float width=s[3].x,w=width*(.3+.7*profile),r=nearest/max(w,1e-5);if(r>3.5)continue;
  float n=cloudFbm(float2(along/(width*4.0)+float(i)*31.7-time*.15,side/(width*.38)+float(i)*7.3));
  float body=exp(-r*r*(2.6-1.7*u.shape.x))*(1-u.shape.z+u.shape.z*(.15+1.7*n*n))*s[3].y;
  sum=1-(1-sum)*(1-min(1.0,body));float k=body*body;tint+=s[4].rgb*s[4].rgb*k;weight+=k;
 }
 float3 cloud=sqrt(tint/weight);
 float lo=(1-u.shape.y)*.45,hi=lo+.15+.75*u.shape.x,x=clamp((sum-lo)/(hi-lo),0.0,1.0),coverage=x*x*(3-2*x);
 float c=cos(u.motion.x),sn=sin(u.motion.x);float2 q=float2(c*p.x+sn*p.y,-sn*p.x+c*p.y);
 float h=clamp((cloudFbm(float2(q.x*1.4-time*(.03+u.motion.z*.5),q.y*7.0))-.5)/.3,0.0,1.0);
 float haze=h*h*(3-2*h)*u.shape.w*.7;
 float3 wisp=streaks[4].rgb*streaks[4].rgb,rgb;float alpha=1;
 if(u.sky.w>.5){rgb=sqrt(mix(u.sky.rgb*u.sky.rgb,wisp,haze));rgb=sqrt(mix(rgb*rgb,cloud*cloud,coverage));}
 else{alpha=1-(1-haze)*(1-coverage);rgb=sqrt(mix(wisp,cloud*cloud,coverage/max(alpha,1e-4)));}
 float grain=(cloudHash(int2(pos)+int2(int(time*24)*131,int(time*24)*71))-.5)*u.motion.y;
 rgb=clamp(rgb+grain*.28,0.0,1.0);if(u.sky.w<=.5)alpha=clamp(alpha*(1+grain*.9),0.0,1.0);
 alpha*=u.extra.x;
 output.write(float4(rgb*alpha+float3(.012)*(1-alpha),1),pos);
}

kernel void tracePreview(texture2d<float,access::write> target [[texture(0)]],device const float4* samples [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=target.get_width()||gid.y>=target.get_height())return;
    float2 p=(float2(gid)+.5)/float2(target.get_width(),target.get_height());
    p=(p-float2(.08,.16))/float2(.84,.68);
    float4 sides=float4(p.y,1-p.x,1-p.y,p.x);
    uint edge=0;for(uint i=1;i<4;i++)if(sides[i]<sides[edge])edge=i;
    float along=(edge==0?p.x:edge==1?1+p.y:edge==2?3-p.x:4-p.y)/4;
    float coverage=(all(p>=0)&&all(p<=1))?1-smoothstep(.015,.025,sides[edge]):0;
    float pos=clamp(along,0.f,1.f)*1023;uint index=uint(pos);
    float3 rgb=mix(samples[index].rgb,samples[min(index+1,1023u)].rgb,fract(pos))*coverage;
    target.write(float4(rgb,1),gid);
}

float glitchRandom(float3 p){return fract(sin(dot(p,float3(12.9898,78.233,37.719)))*43758.5453);}
kernel void powerGlitch(texture2d<float,access::write> target [[texture(0)]],constant float* p [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
 if(gid.x>=target.get_width()||gid.y>=target.get_height())return;
 // A mask is completely transparent to the MUX between brief flashes.
 if(p[0]<.5){target.write(float4(1),gid);return;}
 float2 uv=(float2(gid)+.5)/float2(target.get_width(),target.get_height());
 float pulse=p[1],seed=p[8],aspect=float(target.get_width())/target.get_height();
 float2 center=float2(glitchRandom(float3(seed,1,7)),glitchRandom(float3(seed,1,13)))*.8+.1;
 float2 offset=(float2(glitchRandom(float3(seed,pulse,17)),glitchRandom(float3(seed,pulse,23)))-.5)*p[4]*p[10]*.5;
 float2 delta=uv-center-offset;
 uint shape=uint(round(p[11]));
 if(shape==0)shape=1+min(2u,uint(glitchRandom(float3(seed,73,5))*3));
 float detail=max(1.f,p[3]),spread=max(.05,p[10]);
 float2 cell=floor(delta*float2(detail,detail/aspect));
 // Rectangular chunks and dead bands keep a stable shape within each burst.
 float regionMask,dropout;
 if(shape==1||shape==2){
     float coordinate=shape==1?delta.y:delta.x;
     float bandDetail=shape==1?max(1.f,detail/aspect):detail;
     float band=floor(coordinate*bandDetail);
     regionMask=abs(coordinate)<spread*.5?1.f:0.f;
     dropout=p[2]>0&&(band==0||glitchRandom(float3(band,seed,71))<p[2])?1.f:0.f;
 }else{
     float2 halfSize=float2(spread/aspect,spread)*.5;
     if(p[9]>.5)halfSize*=float2(2.2,.45);
     regionMask=all(abs(delta)<halfSize)?1.f:0.f;
     dropout=p[2]>0&&(all(cell==float2(0))||glitchRandom(float3(cell,seed*71))<p[2])?1.f:0.f;
 }
 float line=glitchRandom(float3(floor((uv.y-offset.y)*(p[9]>.5?160:24)),seed,37));
 dropout=max(dropout,line<p[7]*(p[9]>.5?1.f:.35f)?1.f:0.f);
 float noise=glitchRandom(float3(float2(gid),seed+pulse*131));
 float value=1-regionMask*max(dropout,(1-noise)*p[6]);
 // Whole-frame blackouts, too, only happen inside the short flash envelope.
 if(glitchRandom(float3(seed,59,1))<p[5])value=0;
 target.write(float4(float3(value),1),gid);
}

// Sample preview only; the published mux retains collection recipes and video references.
kernel void layerMuxPreview(array<texture2d<float,access::sample>,8> inputs [[texture(0)]],texture2d<float,access::write> output [[texture(8)]],constant float* levels [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
 if(p.x>=output.get_width()||p.y>=output.get_height())return;
 float2 uv=(float2(p)+.5)/float2(output.get_width(),output.get_height());float4 result=0;
 for(uint i=0;i<8;i++){if(levels[i]<=0)continue;float4 c=inputs[i].sample(linearSampler,uv);float a=clamp(c.a*levels[i],0.f,1.f);result.rgb=c.rgb*a+result.rgb*(1-a);result.a=a+result.a*(1-a);}
 output.write(result,p);
}

// Independent soft particles. Same density evaluator as the VJ particle variant.
kernel void graphCloudParticlePreview(texture2d<float,access::write> output [[texture(0)]],
 device const float4* particles [[buffer(0)]],constant CloudUniforms& u [[buffer(1)]],
 constant float4* boundsData [[buffer(2)]],uint2 pos [[thread_position_in_grid]]) {
 if(pos.x>=output.get_width()||pos.y>=output.get_height())return;
 float2 size=float2(output.get_width(),output.get_height()),uv=(float2(pos)+.5)/size;
 float2 cell=uv*float2(u.info.y,u.info.z),local=fract(cell);uint face=uint(cell.y)*u.info.y+uint(cell.x);
 if(face>=u.info.x||any(local<float2(.025))||any(local>float2(.975))){output.write(float4(0,0,0,1),pos);return;}
 float2 p=float2(uv.x*size.x/size.y,uv.y);int detail=int(u.extra.y);

    float sum=0.0,weight=0.00001;
    float3 tint=particles[2].rgb*particles[2].rgb*weight;
    for(int group=0;group<8;group++){
        if(group>=int(u.info.w))break;
        float4 bounds=boundsData[group];
        if(p.x<bounds.x||p.y<bounds.y||p.x>bounds.z||p.y>bounds.w)continue;
        for(int j=0;j<24;j++){
            if(j>=detail)break;
            int i=group*detail+j;
            float4 a=particles[i*3],b=particles[i*3+1];
            float2 delta=p-a.xy;
            float2 q=float2(b.x*delta.x+b.y*delta.y,-b.y*delta.x+b.x*delta.y)/a.zw;
            float r2=dot(q,q);if(r2>9.0)continue;
            float t=u.motion.w*u.motion.z*.1;
            float n=cloudNoise(q*1.4+float2(b.w-t,b.w*.71))+.5*cloudNoise(q*2.83+float2(b.w*.31+t,17));
            float body=exp(-r2*(2.6-1.7*u.shape.x))*(1.0-smoothstep(6.25,9.0,r2))*(1.0-u.shape.z+u.shape.z*(.15+1.13*n*n))*b.z;
            sum+=body;tint+=particles[(group*detail)*3+2].rgb*particles[(group*detail)*3+2].rgb*body;weight+=body;
        }
    }
    float3 cloud=sqrt(tint/weight);
    float coverage=1.0-exp(-sum*(.4+2.0*u.shape.y));
    float c=cos(u.motion.x),sn=sin(u.motion.x);float2 q=float2(c*p.x+sn*p.y,-sn*p.x+c*p.y);
    float haze=smoothstep(0.0,1.0,(cloudFbm(float2(q.x*1.4-u.motion.w*(u.motion.z*.5),q.y*7.0))-.5)/.3)*u.shape.w*.7;
    float3 wisp=particles[2].rgb*particles[2].rgb,rgb;float alpha=1.0;
    if(u.sky.w>.5){rgb=sqrt(mix(u.sky.rgb*u.sky.rgb,wisp,haze));rgb=sqrt(mix(rgb*rgb,cloud*cloud,coverage));}
    else{alpha=1.0-(1.0-haze)*(1.0-coverage);rgb=sqrt(mix(wisp,cloud*cloud,coverage/max(alpha,1e-4)));}
    float grain=(cloudHash(int2(pos))-.5)*u.motion.y;
    rgb=clamp(rgb+grain*.28,0.0,1.0);if(u.sky.w<=.5)alpha=clamp(alpha*(1.0+grain*.9),0.0,1.0);

 alpha*=u.extra.x;
 output.write(float4(rgb*alpha+float3(.012)*(1-alpha),1),pos);
}

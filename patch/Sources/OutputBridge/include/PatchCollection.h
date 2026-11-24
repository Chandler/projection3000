#pragma once
#include <math.h>
#include <stdint.h>
typedef struct { int pattern; double speed, onTime, fade, brightness; uint32_t seed; } PatchCollectionConfig;
typedef struct { int color, previous; float blend, level; } PatchCollectionSample;
static inline uint32_t patch_collection_hash(uint32_t x) { x^=x>>16; x*=0x7feb352dU; x^=x>>15; x*=0x846ca68bU; return x^(x>>16); }
static inline double patch_collection_clamp(double x,double a,double b) { return fmin(b,fmax(a,x)); }
static inline float patch_collection_smooth(double x) { x=patch_collection_clamp(x,0,1); return (float)(x*x*(3-2*x)); }
static inline int patch_collection_mod(int64_t a,int b) { return (int)((a%b+b)%b); }
static inline int patch_collection_color(PatchCollectionConfig p,int64_t tick,int face,int count,int colors) {
 if(p.pattern==3||p.pattern==5)return patch_collection_hash((uint32_t)tick*131U+(uint32_t)face*977U+p.seed*101U)%colors;
 if(p.pattern==1)return patch_collection_mod(tick,colors);
 if(p.pattern==2)return patch_collection_mod(tick/count+face,colors);
 return patch_collection_mod(tick+face,colors);
}
static inline PatchCollectionSample patch_collection_sample(PatchCollectionConfig p,int face,int count,int colors,double seconds) {
 count=count>0?count:1; colors=colors>0?colors:1;
 double phase=fmax(0,seconds)*patch_collection_clamp(p.speed,0,16);
 if(p.pattern==3)phase+=(double)(patch_collection_hash((uint32_t)face+p.seed*101U)%65536)/65536;
 if(p.pattern==4)phase-=(double)face/count;
 int64_t tick=(int64_t)floor(phase); double fraction=phase-floor(phase);
 double on=patch_collection_clamp(p.onTime,.05,1),fade=patch_collection_clamp(p.fade,0,1);
 float level=fraction<on?1:0;
 if(fade>0&&on<1){double edge=on*.5*fade;level=patch_collection_smooth(fraction/edge)*patch_collection_smooth((on-fraction)/edge);}
 if(p.pattern==2&&patch_collection_mod(tick,count)!=face)level=0;
 if(p.pattern==4)level*=.5-.5*cos(fraction*6.283185307179586);
 PatchCollectionSample s={patch_collection_color(p,tick,face,count,colors),patch_collection_color(p,tick-1,face,count,colors),fade>0?patch_collection_smooth(fraction/(fade*.5)):1,(float)(level*patch_collection_clamp(p.brightness,0,1))};
 return s;
}

// A destination supplies its ordered topology; the recipe has no fixed face count.
// Wander chooses a deterministic permutation each lap, so evaluation is stateless
// and identical on projectors and LEDs, including after seeking or pausing.
static inline int patch_graph_node(int64_t step,int count,int traversal,uint32_t seed) {
 count=count>0?count:1;
 if(traversal!=2)return patch_collection_mod(step,count);
 uint32_t lap=(uint32_t)(step/count);int stride=1+(int)(patch_collection_hash(seed+lap*131U)%(uint32_t)count);
 for(;;){int a=stride,b=count;while(b){int t=a%b;a=b;b=t;}if(a==1)break;stride=stride%count+1;}
 return ((int)(patch_collection_hash(seed^lap)%count)+patch_collection_mod(step,count)*stride)%count;
}
static inline PatchCollectionSample patch_graph_sample(int face,int count,int colors,double seconds,double speed,double trail,double brightness,int traversal,uint32_t seed) {
 count=count>0?count:1;colors=colors>0?colors:1;
 double phase=fmax(0,seconds)*patch_collection_clamp(speed,0,16);
 int64_t head=(int64_t)floor(phase);double width=patch_collection_clamp(trail,.1,8);
 PatchCollectionSample s={0,0,1,0};
 for(int i=0;i<=8;i++){int64_t step=head-i;if(step<0||(traversal==1&&step>=count))continue;
  if(patch_graph_node(step,count,traversal,seed)!=face)continue;
  double age=phase-step,level=patch_collection_clamp(1-age/width,0,1);
  level=level*level*(3-2*level)*patch_collection_clamp(brightness,0,1);
  if(level>s.level){s.level=(float)level;s.color=s.previous=patch_collection_mod(step,colors);}
 }
 return s;
}

// Glow Faces retains Composer's center-weighted profile. Palette colors cycle
// over destination faces; a single fallback color exactly matches Composer.
static inline PatchCollectionSample patch_glow_sample(int face,int colors,double brightness) {
 int index=patch_collection_mod(face,colors>0?colors:1);
 PatchCollectionSample s={index,index,1,(float)patch_collection_clamp(brightness,0,1)};return s;
}
static inline double patch_glow_weight(double x,double y,double centerGlow,double falloff) {
 double px=2*x-1,py=2*y-1;
 double center=pow(fmax(0,(1-px*px)*(1-py*py)),patch_collection_clamp(falloff,.25,6));
 double amount=patch_collection_clamp(centerGlow,0,1);return 1-amount+amount*center;
}

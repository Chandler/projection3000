#pragma once
#include "PatchCollection.h"
// Graph Clouds: long, defocused cloud strips drifting along the graph path.
// Hosts supply face centers in one shared metric space (x scaled by aspect,
// y in units of the canvas height), so a strip spans several surfaces at once.
// Strips are stateless polylines sampled from a Catmull-Rom path through the
// traversal order; shaders evaluate the textured density per pixel.
#define PATCH_CLOUD_POINTS 6
#define PATCH_CLOUD_MAX 24
// sky: 1 paints color 0 behind the clouds; 0 leaves it clear so clouds layer over other effects.
typedef struct { int count; double speed, length, width, wander; int colorMode, sky; uint32_t seed; } PatchCloudConfig;
typedef struct { double x[PATCH_CLOUD_POINTS], y[PATCH_CLOUD_POINTS]; double width, level; int color; } PatchCloudStreak;

static inline double patch_cloud_unit(uint32_t h) { return (h%65536)/65535.; }
static inline void patch_cloud_path(const double* centers,int faces,int traversal,uint32_t seed,double u,double* x,double* y) {
 if(faces<2){double c=u*.35-floor(u*.35);*x=centers[0]+(c*2-1)*1.2;*y=centers[1];return;}
 int64_t step=(int64_t)floor(u);double t=u-step,t2=t*t,t3=t2*t;
 int n[4];for(int i=0;i<4;i++)n[i]=patch_graph_node(step-1+i,faces,traversal,seed);
 double w0=-.5*t3+t2-.5*t,w1=1.5*t3-2.5*t2+1,w2=-1.5*t3+2*t2+.5*t,w3=.5*t3-.5*t2;
 *x=w0*centers[n[0]*2]+w1*centers[n[1]*2]+w2*centers[n[2]*2]+w3*centers[n[3]*2];
 *y=w0*centers[n[0]*2+1]+w1*centers[n[1]*2+1]+w2*centers[n[2]*2+1]+w3*centers[n[3]*2+1];
}
// Traversal "once" has no end for weather: clouds keep looping.
static inline PatchCloudStreak patch_cloud_streak(PatchCloudConfig p,int stream,const double* centers,int faces,int colors,double seconds,int traversal) {
 PatchCloudStreak s;faces=faces>0?faces:1;colors=colors>0?colors:1;if(traversal==1)traversal=0;
 uint32_t h=patch_collection_hash((uint32_t)stream*7919U+p.seed*101U);
 double rate=.7+.6*patch_cloud_unit(h>>3),phase=patch_cloud_unit(h)*faces;
 double head=fmax(0,seconds)*patch_collection_clamp(p.speed,0,4)*rate+phase;
 double length=patch_collection_clamp(p.length,.1,6)*(.75+.5*patch_cloud_unit(h>>11));
 double wander=patch_collection_clamp(p.wander,0,1),swirl=6.28318530718*patch_cloud_unit(h>>7);
 // Each strip rides a parallel lane; lanes slowly cross so streaks overlap and part.
 double lane=(patch_cloud_unit(h>>17)*2-1)*wander*.16;
 for(int k=0;k<PATCH_CLOUD_POINTS;k++){
  double u=head-length*k/(PATCH_CLOUD_POINTS-1),x,y,ax,ay,bx,by;
  patch_cloud_path(centers,faces,traversal,p.seed+(uint32_t)stream*13U,u,&x,&y);
  patch_cloud_path(centers,faces,traversal,p.seed+(uint32_t)stream*13U,u-.02,&ax,&ay);
  patch_cloud_path(centers,faces,traversal,p.seed+(uint32_t)stream*13U,u+.02,&bx,&by);
  double tx=bx-ax,ty=by-ay,tl=hypot(tx,ty);if(tl<1e-9){tx=1;ty=0;tl=1;}
  double off=lane+wander*(.07*sin(u*1.3+swirl)+.035*sin(u*2.9-swirl*1.7));
  s.x[k]=x-ty/tl*off;s.y[k]=y+tx/tl*off;
 }
 s.width=patch_collection_clamp(p.width,.005,.6)*(.7+.6*patch_cloud_unit(h>>23));
 s.level=.7+.3*patch_cloud_unit(h>>5);
 int first=p.sky&&colors>1?1:0,span=colors-first;
 s.color=p.colorMode==1&&span>1?first+stream%span:first;
 return s;
}

// Reference evaluator for hosts without a shader (LED fixtures). Matches the
// GLSL/Metal field: soft gaussian strips modulated by stretched value noise.
static inline double patch_cloud_noise(double x,double y) {
 double ix=floor(x),iy=floor(y),fx=x-ix,fy=y-iy;fx=fx*fx*(3-2*fx);fy=fy*fy*(3-2*fy);
 #define PATCH_CLOUD_H(a,b) (patch_collection_hash((uint32_t)(int32_t)(a)*73856093U^(uint32_t)(int32_t)(b)*19349663U)%65536/65535.)
 double a=PATCH_CLOUD_H(ix,iy),b=PATCH_CLOUD_H(ix+1,iy),c=PATCH_CLOUD_H(ix,iy+1),d=PATCH_CLOUD_H(ix+1,iy+1);
 #undef PATCH_CLOUD_H
 return a+(b-a)*fx+(c-a)*fy+(a-b-c+d)*fx*fy;
}
static inline double patch_cloud_fbm(double x,double y) {
 double v=0,a=.5;for(int i=0;i<4;i++){v+=a*patch_cloud_noise(x,y);x=x*2.03+17.1;y=y*2.03+9.7;a*=.5;}return v/.9375;
}
// Returns coverage in [0,1]; *color receives the dominant strip's palette index.
static inline double patch_cloud_coverage(const PatchCloudStreak* streaks,int count,double px,double py,double seconds,double softness,double density,double texture,int* color) {
 double sum=0,best=0;*color=count>0?streaks[0].color:0;
 for(int i=0;i<count;i++){const PatchCloudStreak* s=&streaks[i];
  double nearest=1e9,along=0,side=0,cum=0;
  for(int k=0;k+1<PATCH_CLOUD_POINTS;k++){
   double sx=s->x[k+1]-s->x[k],sy=s->y[k+1]-s->y[k],l2=sx*sx+sy*sy,l=sqrt(l2);
   double t=l2>1e-12?patch_collection_clamp(((px-s->x[k])*sx+(py-s->y[k])*sy)/l2,0,1):0;
   double dx=px-s->x[k]-sx*t,dy=py-s->y[k]-sy*t,d=hypot(dx,dy);
   if(d<nearest){nearest=d;along=cum+t*l;side=l>1e-9?(sx*dy-sy*dx)/l:0;}cum+=l;
  }
  double u=cum>1e-9?along/cum:0,profile=pow(fmax(0,sin(3.14159265*patch_collection_clamp(u*.92+.04,0,1))),.6);
  double w=s->width*(.3+.7*profile),r=nearest/fmax(w,1e-5);if(r>3.5)continue;
  double n=patch_cloud_fbm(along/(s->width*4.0)+i*31.7-seconds*.15,side/(s->width*.38)+i*7.3),soft=patch_collection_clamp(softness,0,1),grain=patch_collection_clamp(texture,0,1);
  double body=exp(-r*r*(2.6-1.7*soft))*(1-grain+grain*(.15+1.7*n*n));
  body*=s->level;sum=1-(1-sum)*(1-fmin(1,body));if(body>best){best=body;*color=s->color;}
 }
 double lo=(1-patch_collection_clamp(density,0,1))*.45,hi=lo+.15+.75*patch_collection_clamp(softness,0,1);
 return patch_collection_smooth((sum-lo)/(hi-lo));
}
// Faint sky wisps between strips, streaked along the wind and drifting with it.
static inline double patch_cloud_haze(double px,double py,double seconds,double speed,double wind,double amount) {
 double c=cos(wind),s=sin(wind),x=c*px+s*py,y=-s*px+c*py;
 double h=patch_cloud_fbm(x*1.4-seconds*(.03+speed*.5),y*7.0);
 return patch_collection_smooth((h-.5)/.3)*patch_collection_clamp(amount,0,1)*.7;
}

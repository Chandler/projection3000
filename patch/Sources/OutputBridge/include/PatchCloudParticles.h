#pragma once
#include "PatchClouds.h"
// Independent overlapping density particles. No edges, tangent frames, respawns,
// or nearest-segment coordinates. Shared by preview, projector and LED sampling.
#define PATCH_CLOUD_PARTICLE_GROUPS 8
#define PATCH_CLOUD_PARTICLE_DETAIL 24
#define PATCH_CLOUD_PARTICLE_MAX 192
typedef struct { double x,y,rx,ry,angle,level,noise; int color; } PatchCloudParticle;
static inline double patch_cloud_particle_random(uint32_t h,uint32_t salt) { return patch_cloud_unit(patch_collection_hash(h+salt*2654435761U)); }
// Uniform cubic B-spline: position, velocity and acceleration remain continuous
// at every graph hop, including reversals. It rounds corners rather than pinning
// a rigid body to each face center.
static inline void patch_cloud_particle_path(const double* centers,int faces,int traversal,uint32_t seed,double u,double* x,double* y) {
 if(faces<2){*x=centers[0]+.38*sin(u*.7);*y=centers[1]+.18*cos(u*.53);return;}
 int64_t step=(int64_t)floor(u);double t=u-step,a=1-t,t2=t*t,t3=t2*t;
 double weights[4]={a*a*a/6,(3*t3-6*t2+4)/6,(-3*t3+3*t2+3*t+1)/6,t3/6};*x=0;*y=0;
 for(int k=0;k<4;k++){int f=patch_graph_node(step+k-1,faces,traversal==1?0:traversal,seed);*x+=weights[k]*centers[f*2];*y+=weights[k]*centers[f*2+1];}
}
static inline PatchCloudParticle patch_cloud_particle(PatchCloudConfig p,int group,int particle,int detail,const double* centers,int faces,int colors,double seconds,int traversal,double wind) {
 PatchCloudParticle s; uint32_t gh=patch_collection_hash(p.seed*101U+(uint32_t)group*7919U),h=patch_collection_hash(gh+(uint32_t)particle*65537U);
 double time=fmax(0,seconds)*patch_collection_clamp(p.speed,0,2),phase=patch_cloud_particle_random(gh,1)*faces;
 double speed=.8+.4*patch_cloud_particle_random(gh,2),spread=patch_collection_clamp(p.length,.1,6);
 double age=(patch_cloud_particle_random(h,1)+patch_cloud_particle_random(h,2)-1)*spread;
 double u=time*speed+phase+age;
 patch_cloud_particle_path(centers,faces,traversal,p.seed+(uint32_t)group*13U,u,&s.x,&s.y);
 double width=patch_collection_clamp(p.width,.01,.5),turbulence=patch_collection_clamp(p.wander,0,1),a=6.28318530718*patch_cloud_particle_random(h,3);
 // Offsets evolve in a fixed metric frame: no normal flipping at tight turns.
 double drift=time*(.55+.4*patch_cloud_particle_random(h,4));
 s.x+=width*((patch_cloud_particle_random(h,5)-.5)*1.2+turbulence*(.8*sin(drift+a)+.35*sin(drift*1.73-a*2)));
 s.y+=width*((patch_cloud_particle_random(h,6)-.5)*1.2+turbulence*(.8*cos(drift*.81+a)+.35*cos(drift*1.31+a*3)));
 double breath=1+.12*sin(drift*.7+a*2),size=.65+.65*patch_cloud_particle_random(h,7);
 s.rx=width*size*breath*(1.3+.5*patch_cloud_particle_random(h,8));s.ry=width*size*breath*(.55+.35*patch_cloud_particle_random(h,9));
 s.angle=wind+turbulence*.35*sin(drift*.37+a);s.level=(.55+.4*patch_cloud_particle_random(h,10))*12/fmax(8,detail);
 s.noise=patch_cloud_particle_random(h,11)*100;
 int first=p.sky&&colors>1?1:0,span=colors-first;if(span<1)span=1;s.color=p.colorMode==1?first+group%span:first;
 return s;
}
static inline double patch_cloud_particle_body(PatchCloudParticle s,double x,double y,double seconds,double speed,double softness,double texture) {
 double dx=x-s.x,dy=y-s.y,c=cos(s.angle),sn=sin(s.angle),qx=(c*dx+sn*dy)/s.rx,qy=(-sn*dx+c*dy)/s.ry,r2=qx*qx+qy*qy;if(r2>9)return 0;
 double t=seconds*speed*.1,n=patch_cloud_noise(qx*1.4+s.noise-t,qy*1.4+s.noise*.71)+.5*patch_cloud_noise(qx*2.83+s.noise*.31+t,qy*2.83+17);
 double edge=1-patch_collection_smooth((r2-6.25)/2.75);
 return exp(-r2*(2.6-1.7*softness))*edge*(1-texture+texture*(.15+1.13*n*n))*s.level;
}
static inline double patch_cloud_particle_coverage(const PatchCloudParticle* particles,int count,double x,double y,double seconds,double speed,double softness,double density,double texture,int* color) {
 double sum=0,best=0;*color=count?particles[0].color:0;
 for(int i=0;i<count;i++){double body=patch_cloud_particle_body(particles[i],x,y,seconds,speed,softness,texture);sum+=body;if(body>best){best=body;*color=particles[i].color;}}
 return 1-exp(-sum*(.4+2*density));
}

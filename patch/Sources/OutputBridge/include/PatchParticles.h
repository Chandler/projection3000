#pragma once
#include "PatchCollection.h"
// Shared, stateless 3D particle trajectories. Hosts supply topology and face metrics.
// Position is in units of the face's short side, before perspective mapping.
typedef struct { int count; double dwell, travel, speed, spin, orbit, depth, size, stagger, trail; uint32_t seed; } PatchParticleConfig;
typedef struct { int face, neighbor, color, stage; double x,y,z,radius,level,transfer,led,anchorX,anchorY,clusterRadius; int flock; double tangentX,tangentY,flockTurn,flockResponse; } PatchParticle;
static inline PatchParticle patch_particle_sample(PatchParticleConfig p,int particle,int faces,int colors,double seconds,int traversal) {
 PatchParticle s={-1,-1,0,0,0,0,0,0,0,0,0,0,0,0};faces=faces>0?faces:1;colors=colors>0?colors:1;
 double dwell=patch_collection_clamp(p.dwell,.1,10),travel=patch_collection_clamp(p.travel,.08,5),cycle=dwell+travel;
 double stagger=(double)particle/(p.count>0?p.count:1)*patch_collection_clamp(p.stagger,0,.8)*cycle;
 double time=fmax(0,seconds)*patch_collection_clamp(p.speed,0,4)-stagger;if(time<0)return s;
 int64_t step=(int64_t)floor(time/cycle);double age=time-step*cycle;
 if(traversal==1&&step>=faces)return s;
 s.face=patch_graph_node(step,faces,traversal,p.seed);s.color=particle%colors;
 uint32_t hash=patch_collection_hash((uint32_t)particle+p.seed*101U);
 double theta=6.28318530718*(particle/(double)(p.count>0?p.count:1)+(hash%997)/9970.);
 double tilt=.5+((hash>>10)%997)/997.*.9;
 double orbit=patch_collection_clamp(p.orbit,.05,.4)*(.55+.45*((hash>>20)%997)/997.);
 double local=age;
 if(age>=dwell){
  if(age<dwell+travel*.5){s.stage=1;s.transfer=(age-dwell)/(travel*.5);s.neighbor=patch_graph_node(step+1,faces,traversal,p.seed);local=dwell;}
  else {if(traversal==1&&step+1>=faces){s.face=-1;return s;}s.stage=2;s.transfer=(age-dwell-travel*.5)/(travel*.5);s.neighbor=s.face;s.face=patch_graph_node(step+1,faces,traversal,p.seed);local=0;}
 }
 double angle=theta+local*patch_collection_clamp(p.spin,-4,4)*6.28318530718;
 double x=orbit*cos(angle),y=orbit*sin(angle)*cos(tilt),z=orbit*sin(angle)*sin(tilt);
 // Precess the tilted orbit slowly to make the cloud read as a volume.
 double precession=local*.65;double xx=x*cos(precession)-y*sin(precession),yy=x*sin(precession)+y*cos(precession);
 double depth=patch_collection_clamp(p.depth,0,1),projection=1/(1-z*depth*1.1);
 s.x=xx*projection;s.y=yy*projection;s.z=z;s.radius=patch_collection_clamp(p.size,.003,.08)*projection;
 s.level=.65+.35*(z/(orbit>0?orbit:1)*.5+.5);s.led=.5+.44*sin(angle);
 if(s.stage==1){double t=patch_collection_smooth(s.transfer);s.led=s.led*(1-t)+1.12*t;}
 if(s.stage==2){double t=patch_collection_smooth(s.transfer);s.led=-.12*(1-t)+s.led*t;}
 return s;
}
// Direction points from this face toward its neighbor, in the local metric chart.
static inline PatchParticle patch_particle_place(PatchParticle s,double aspect,double dx,double dy) {
 aspect=patch_collection_clamp(aspect,.02,50);double w=aspect>=1?aspect:1,h=aspect>=1?1:1/aspect;
 if(s.stage){double length=hypot(dx,dy);if(length<1e-9){dx=s.stage==1?1:-1;dy=0;length=1;}dx/=length;dy/=length;
  double reach=fmin(fabs(dx)>1e-9?w*.55/fabs(dx):1e9,fabs(dy)>1e-9?h*.55/fabs(dy):1e9);
  double t=patch_collection_smooth(s.transfer),outside=s.stage==1?t:1-t;
  s.x=s.x*(1-outside)+dx*reach*outside;s.y=s.y*(1-outside)+dy*reach*outside;
 }
 s.x=.5+s.x/w;s.y=.5+s.y/h;return s;
}
static inline double patch_particle_led(PatchParticle s,double position) {
 if(s.face<0)return 0;double radius=fmax(.004,s.radius*.65),distance=(position-s.led)/radius;
 return fabs(distance)>3?0:exp(-distance*distance*2.5)*s.level;
}

// Ink clusters share a continuous clock and travel in small, offset streams.
// Complete graphs visit a new permutation each lap; every transition is an edge.
static inline int patch_ink_node(int64_t step,int count,int traversal,uint32_t seed) {
 if(count<2)return 0;if(traversal!=2)return patch_collection_mod(step,count);
 int stride=1+(int)(patch_collection_hash(seed+(uint32_t)(step/count)*131U)%count);
 for(;;){int a=stride,b=count;while(b){int r=a%b;a=b;b=r;}if(a==1)break;stride=stride%count+1;}
 // The fixed lap origin prevents a repeated node at permutation boundaries.
 return (patch_collection_hash(seed)%count+patch_collection_mod(step,count)*stride)%count;
}
// Deterministic stopping points: no per-frame state, so seeks and LED sampling agree.
static inline double patch_ink_anchor(uint32_t visit,int site,uint32_t axis) {
 return ((patch_collection_hash(visit+(uint32_t)site*7919U+axis)%65536)/65535.)*1.8-.9;
}
// Original Graph Ink Flow. Keep this trajectory stable.
static inline PatchParticle patch_ink_sample(PatchParticleConfig p,int particle,int faces,int colors,double seconds,int traversal,double turbulence,double pulse,int circles) {
 PatchParticle s={-1,-1,0,0,0,0,0,0,0,0,0,0,0,0};faces=faces>0?faces:1;colors=colors>0?colors:1;
 uint32_t hash=patch_collection_hash((uint32_t)particle+p.seed*101U),stream=patch_collection_hash((uint32_t)(particle/8)+p.seed*977U);
 double phase=(hash%65536)/65536.,dwell=patch_collection_clamp(p.dwell,.1,10),travel=patch_collection_clamp(p.travel,.08,5),cycle=dwell+travel;
 double offset=traversal==1?0:(stream%faces)*cycle;
 double time=fmax(0,seconds)*patch_collection_clamp(p.speed,0,4)+offset-phase*patch_collection_clamp(p.stagger,0,.8)*cycle;
 if(time<0)return s;int64_t step=(int64_t)floor(time/cycle);double age=time-step*cycle;
 if(traversal==1&&step>=faces)return s;
 s.face=patch_ink_node(step,faces,traversal,stream);s.neighbor=patch_ink_node(step+1,faces,traversal,stream);s.color=particle%colors;
 double local=age;
 if(faces>1&&age>=dwell){
  if(age<dwell+travel*.5){s.stage=1;s.transfer=(age-dwell)/(travel*.5);local=dwell;}
  else {if(traversal==1&&step+1>=faces){s.face=-1;return s;}s.stage=2;s.transfer=(age-dwell-travel*.5)/(travel*.5);s.neighbor=s.face;s.face=patch_ink_node(step+1,faces,traversal,stream);local=0;++step;}
 }else if(faces>1){s.stage=3;s.transfer=patch_collection_smooth((age/dwell-.35)/.65);}
 double t=(step*cycle+local)*p.spin,theta=phase*6.28318530718,noise=patch_collection_clamp(turbulence,0,2);
 double orbit=patch_collection_clamp(p.orbit,.05,.4),a=t*.73+theta,b=t*1.137+theta*1.7;
 double z=orbit*.65*sin(t*.91+theta*.83),projection=1/(1-z*patch_collection_clamp(p.depth,0,1));
 s.x=orbit*(.62*sin(a)+.23*noise*sin(b+sin(a*.61)))*projection;
 s.y=orbit*(.57*cos(a*.87+theta*.21)+.22*noise*cos(b*.79+sin(a)))*projection;
 s.z=z;s.radius=patch_collection_clamp(p.size,.003,.08)*(.38+1.0*((hash>>16)%997)/997.)*projection;
 double breath=.5+.5*sin(t*.43+2*sin(t*.19+theta)+theta);
 s.level=(circles?1:(.62+.3*((hash>>8)%997)/997.))*(1-patch_collection_clamp(pulse,0,1)*(.75-breath*.75));
 s.led=.5+.39*sin(a+.35*sin(b));
 if(s.stage==3)s.led=s.led*(1-s.transfer*.3)+.85*s.transfer*.3;
 if(s.stage==1){double f=patch_collection_smooth(s.transfer);s.led=s.led*(1-f)+1.12*f;}
 if(s.stage==2){double f=patch_collection_smooth(s.transfer);s.led=-.12*(1-f)+s.led*f;}
 return s;
}
static inline PatchParticle patch_ink_place(PatchParticle s,double aspect,double dx,double dy,double exploration) {
 aspect=patch_collection_clamp(aspect,.02,50);exploration=patch_collection_clamp(exploration,0,1);
 double w=aspect>=1?aspect:1,h=aspect>=1?1:1/aspect;
 double margin=s.radius*1.1,ex=fmax(0,w*.5-margin),ey=fmax(0,h*.5-margin);
 double x=tanh(s.x/.18)*ex,y=tanh(s.y/.18)*ey;
 s.x+=(x-s.x)*exploration;s.y+=(y-s.y)*exploration;
 // Population transfers retain velocity and circulation as directional
 // steering builds. Grains respond at different times.
 if(s.flock){
  if(s.stage==1||s.stage==2){
   double length=hypot(dx,dy);if(length<1e-9){dx=s.stage==1?1:-1;dy=0;length=1;}
   double ux=dx/length,uy=dy/length;
   double reach=fmin(fabs(ux)>1e-9?(w*.5+s.radius*4)/fabs(ux):1e9,fabs(uy)>1e-9?(h*.5+s.radius*4)/fabs(uy):1e9);
   // Transform velocity through the same aspect-aware exploration map.
   double tx=tanh(s.anchorX/.18),ty=tanh(s.anchorY/.18);
   double vx=s.tangentX*((1-exploration)+exploration*ex/.18*(1-tx*tx));
   double vy=s.tangentY*((1-exploration)+exploration*ey/.18*(1-ty*ty));
   // Integrate velocity, rather than interpolating a destination spline.
   // Turning authority grows gradually; the initial circulation decays while
   // the shared heading takes over. Reverse integration settles arrivals into
   // their own current with exactly its position and tangent at the join.
   double t=patch_collection_clamp(s.stage==1?s.transfer:1-s.transfer,0,1);
   double turn=s.flockTurn;if(s.stage==2){vx=-vx;vy=-vy;turn=-turn;}
   double px=s.x,py=s.y;
   // Fixed integration steps make the result independent of frame rate, seeks,
   // trail sample order and the number of projectors consuming this recipe.
   for(int i=0;i<48;++i){
    double at=i/48.,dt=fmin(1./48.,t-at);if(dt<=0)break;
    double u=at+dt*.5,align=patch_collection_smooth(u);
    double response=(2+12*align)*s.flockResponse;
    double circulation=turn*(1-align)*(1-align);
    double desired=reach*(1+5*align);
    double ax=-vy*circulation+(ux*desired-vx)*response*align;
    double ay= vx*circulation+(uy*desired-vy)*response*align;
    // Midpoint position update preserves the existing velocity on entry.
    px+=vx*dt+ax*dt*dt*.5;py+=vy*dt+ay*dt*dt*.5;
    vx+=ax*dt;vy+=ay*dt;
   }
   s.x=px;s.y=py;
  }
  s.x=.5+s.x/w;s.y=.5+s.y/h;return s;
 }
 int stage=s.stage;double transfer=s.transfer;
 if(stage==3){s.stage=1;s.transfer=0;}
 if(stage==3||stage==1){double length=hypot(dx,dy);if(length>1e-9){
  double ux=dx/length,uy=dy/length,amount=stage==3?transfer:1;
  double reach=fmin(fabs(ux)>1e-9?ex/fabs(ux):1e9,fabs(uy)>1e-9?ey/fabs(uy):1e9);
  s.x+=amount*((1-exploration)*ux*.26+exploration*(ux*reach-s.x)*.3);
  s.y+=amount*((1-exploration)*uy*.26+exploration*(uy*reach-s.y)*.3);
 }}
 return patch_particle_place(s,aspect,dx,dy);
}

// Optional population routing for the original ink motion. Keep the particle
// budget fixed; residency belongs to organisms, never to individual grains.
static inline PatchParticle patch_ink_population(PatchParticleConfig p,int particle,int faces,int colors,double seconds,int traversal,double turbulence,double pulse,int circles,double startingFaces,int independent) {
 if(!independent&&startingFaces>=100)return patch_ink_sample(p,particle,faces,colors,seconds,traversal,turbulence,pulse,circles);
 PatchParticle empty={-1,-1,0,0,0,0,0,0,0,0,0,0,0,0};
 if(faces<1||p.count<1||startingFaces<=0)return empty;
 int population=(int)ceil(faces*patch_collection_clamp(startingFaces,0,100)/100.);
 if(population>p.count)population=p.count;
 int organism=particle%population;
 uint32_t identity=patch_collection_hash(p.seed*977U+(uint32_t)organism*7919U);
 // Unique, seeded starting faces. Later routes may converge freely.
 int start=patch_ink_node(organism,faces,2,p.seed);
 double dwell=patch_collection_clamp(p.dwell,.1,10)*(independent?(.55+.9*(identity%65536)/65535.):1);
 double travel=patch_collection_clamp(p.travel,.08,5),cycle=dwell+travel;
 uint32_t grain=patch_collection_hash((uint32_t)particle+p.seed*101U);
 double rate=patch_collection_clamp(p.speed,0,4);
 // Individual response latency remains present at low Stream spread. That
 // control widens the flock, rather than switching every grain simultaneously.
 double delay=(grain%65536)/65535.*(.25+patch_collection_clamp(p.stagger,0,.8))*fmin(cycle*.3,travel);
 double time=fmax(0,fmax(0,seconds)*rate-delay);
 int64_t step=(int64_t)floor(time/cycle);double age=time-step*cycle;
 if(traversal==1&&step>=faces-start)return empty;
 int from,to;
 if(traversal==2){
  int origin=patch_ink_node(0,faces,2,identity);
  from=patch_collection_mod(start+patch_ink_node(step,faces,2,identity)-origin,faces);
  to=patch_collection_mod(start+patch_ink_node(step+1,faces,2,identity)-origin,faces);
 }else{from=patch_collection_mod(start+step,faces);to=patch_collection_mod(start+step+1,faces);}
 // Retain the original continuous internal currents. Only residency changes.
 PatchParticleConfig motion=p;motion.stagger=0;
 motion.seed=identity;motion.spin*=.75+.5*((identity>>16)%65536)/65535.;
 PatchParticle s=patch_ink_sample(motion,particle,1,colors,seconds,0,turbulence,pulse,circles);
 s.face=from;s.neighbor=to;s.flock=1;
 // Do not correlate palette index with organism index (both used modulo N).
 s.color=(int)(grain%(uint32_t)(colors>0?colors:1));
 s.flockResponse=.8+.4*((grain>>16)%65536)/65535.;
 // Start gathering before departure, giving each grain time to continue its
 // curve and turn. Arrival joins the destination current with matching velocity.
 double gather=fmin(dwell*.55,fmax(travel*1.6,dwell*.18)),begin=dwell-gather,half=dwell+travel*.5;
 double boundary=0,duration=0;
 if(faces>1&&age>=begin){
  if(age<half){s.stage=1;duration=half-begin;s.transfer=(age-begin)/duration;boundary=step*cycle+begin;}
  else{if(traversal==1&&step+1>=faces-start)return empty;s.stage=2;duration=cycle-half;s.transfer=(age-half)/duration;boundary=(step+1)*cycle;s.face=to;s.neighbor=from;}
  double endpoint=rate>1e-9?(boundary+delay)/rate:seconds;
  PatchParticle point=patch_ink_sample(motion,particle,1,colors,endpoint,0,turbulence,pulse,circles);
  PatchParticle before=patch_ink_sample(motion,particle,1,colors,fmax(0,endpoint-.01),0,turbulence,pulse,circles);
  PatchParticle after=patch_ink_sample(motion,particle,1,colors,endpoint+.01,0,turbulence,pulse,circles);
  double span=endpoint<.01?endpoint+.01:.02;
  s.x=point.x;s.y=point.y;s.anchorX=point.x;s.anchorY=point.y;
  s.tangentX=(after.x-before.x)/span*duration/fmax(rate,1e-9);
  s.tangentY=(after.y-before.y)/span*duration/fmax(rate,1e-9);
  double ax=(after.x-2*point.x+before.x)/(.01*.01),ay=(after.y-2*point.y+before.y)/(.01*.01);
  double vx=(after.x-before.x)/span,vy=(after.y-before.y)/span;
  s.flockTurn=patch_collection_clamp((vx*ay-vy*ax)/fmax(.0001,vx*vx+vy*vy)*duration/fmax(rate,1e-9),-8,8);
  // LEDs follow the same staggered handoff, retaining motion at its joins.
  double f=patch_collection_smooth(s.transfer);
  if(s.stage==1)s.led=s.led*(1-f)+1.12*f;
  else s.led=-.12*(1-f)+s.led*f;
 }
 return s;
}

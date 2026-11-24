#pragma once
#include <math.h>
#include <stdint.h>
// Lightning Pulses uses the original normalized Composer trace equations.
typedef struct { double r,g,b; } PatchTraceColor;
typedef struct {
 double rate,burst,speed,jitter,length,tail,crackle,forks,spray,brightness,rainbow,start,end;
 int reverse,reflect,singleColor; uint32_t seed;
 double motionTime,motionDistance,motionJitterDistance;
 PatchTraceColor core,glow;
} PatchTraceConfig;
static inline double patch_trace_mod(double x,double n){return x-floor(x/n)*n;}
static inline double patch_trace_clamp(double x){return fmax(0,fmin(1,x));}
static inline PatchTraceColor patch_trace_glow(PatchTraceConfig p,const PatchTraceColor* colors,int count,double packet,double x,double t){
 PatchTraceColor c=count>0?colors[(int)patch_trace_mod(packet,count)]:p.glow;
 if(!p.singleColor){double h=x+t*.09; c.r=c.r*(1-p.rainbow)+(.5+.5*cos(6.283185307179586*h))*p.rainbow;c.g=c.g*(1-p.rainbow)+(.5+.5*cos(6.283185307179586*(h-1./3)))*p.rainbow;c.b=c.b*(1-p.rainbow)+(.5+.5*cos(6.283185307179586*(h-2./3)))*p.rainbow;}
 return c;
}
static inline PatchTraceColor patch_trace_sample(PatchTraceConfig p,const PatchTraceColor* colors,int count,double x,double t,uint32_t instance){
 PatchTraceColor result={0,0,0};double start=fmin(p.start,p.end),end=fmax(p.start,p.end),span=end-start;
 if(span<1e-6||x<start||x>end||(p.rate<=0&&!p.reflect))return result;
 x=p.reverse?end-x:x-start;t=fmax(0,t);
 double identity=(instance+p.seed)%65521,speed=fmax(.001,p.speed),width=fmax(.002,p.length),latest=floor(t*p.rate);
 int packets=p.reflect?1:(int)fmin(1024,ceil((span+width*(1+p.tail*4+.88))/(speed*fmax(.05,1-p.jitter*.5))*p.rate)+1);
 double noise=patch_trace_mod(floor(x*120)*37+floor(t*30)*17+identity*13,101)/101;
 PatchTraceColor glow=patch_trace_glow(p,colors,count,latest,x,t);
 double spray=p.spray*exp(-x*35)*noise*.25;result.r=glow.r*spray;result.g=glow.g*spray;result.b=glow.b*spray;
 for(int i=0;i<packets;i++){
  double packet=latest-i;if(packet<0)break;double seed=patch_trace_mod(packet*37+identity*17,1009)/1009,pos,heading=1,colorIndex=packet;
  if(p.reflect){double elapsed=t-p.motionTime,distance=p.motionDistance+elapsed*speed,jitterDistance=p.motionJitterDistance+elapsed*speed*p.jitter;
   double travel=(distance+jitterDistance*(patch_trace_mod(identity*17,1009)/1009-.5))/span,phase=patch_trace_mod(travel,2);pos=span*(phase<1?phase:2-phase);heading=phase<1?1:-1;colorIndex=floor(travel);seed=patch_trace_mod(colorIndex*37+identity*17,1009)/1009;
  }else pos=(t-packet/p.rate)*speed*(1+p.jitter*(seed-.5));
  double d=(x-pos)*heading,head=exp(-.5*pow(d/(width*.22),2)),tail=d<=0?patch_trace_clamp(1+d/(width*(1+p.tail*4))):0;
  double flow=(head*.55+tail*.75)*(1-p.crackle*.9*(1-noise))+p.forks*head*pow(sin(x*250+t*70+identity*.37),2)*.3;
  glow=patch_trace_glow(p,colors,count,colorIndex,x,t);PatchTraceColor core=p.singleColor?glow:p.core;double gain=1+p.burst*seed;
  result.r+=(glow.r*flow+core.r*head)*gain;result.g+=(glow.g*flow+core.g*head)*gain;result.b+=(glow.b*flow+core.b*head)*gain;
 }
 result.r=patch_trace_clamp(result.r*p.brightness);result.g=patch_trace_clamp(result.g*p.brightness);result.b=patch_trace_clamp(result.b*p.brightness);return result;
}

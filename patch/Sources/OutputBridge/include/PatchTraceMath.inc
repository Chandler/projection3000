PATCH_TRACE_MATH(
// Lightning Pulses uses the original normalized Composer trace equations.
typedef struct { PatchTraceReal r,g,b; } PatchTraceColor;
typedef struct {
 PatchTraceReal rate,burst,speed,jitter,length,tail,crackle,forks,spray,brightness,rainbow,start,end;
 int reverse,reflect,singleColor; PatchTraceSeed seed;
 PatchTraceReal motionTime,motionDistance,motionJitterDistance;
 PatchTraceColor core,glow;
} PatchTraceConfig;
static inline PatchTraceReal patch_trace_mod(PatchTraceReal x,PatchTraceReal n){return x-floor(x/n)*n;}
static inline PatchTraceReal patch_trace_clamp(PatchTraceReal x){return fmax(0,fmin(1,x));}
static inline PatchTraceColor patch_trace_glow(PatchTraceConfig p,PATCH_TRACE_ADDRESS const PatchTraceColor* colors,int count,PatchTraceReal packet,PatchTraceReal x,PatchTraceReal t){
 PatchTraceColor c=count>0?colors[(int)patch_trace_mod(packet,count)]:p.glow;
 if(!p.singleColor){PatchTraceReal h=x+t*.09; c.r=c.r*(1-p.rainbow)+(.5+.5*cos(6.283185307179586*h))*p.rainbow;c.g=c.g*(1-p.rainbow)+(.5+.5*cos(6.283185307179586*(h-1./3)))*p.rainbow;c.b=c.b*(1-p.rainbow)+(.5+.5*cos(6.283185307179586*(h-2./3)))*p.rainbow;}
 return c;
}
static inline PatchTraceColor patch_trace_sample(PatchTraceConfig p,PATCH_TRACE_ADDRESS const PatchTraceColor* colors,int count,PatchTraceReal x,PatchTraceReal t,PatchTraceSeed instance){
 PatchTraceColor result={0,0,0};PatchTraceReal start=fmin(p.start,p.end),end=fmax(p.start,p.end),span=end-start;
 if(span<1e-6||x<start||x>end||(p.rate<=0&&!p.reflect))return result;
 x=p.reverse?end-x:x-start;t=fmax(0,t);
 PatchTraceReal identity=(instance+p.seed)%65521,speed=fmax(.001,p.speed),width=fmax(.002,p.length),latest=floor(t*p.rate);
 int packets=p.reflect?1:(int)fmin(1024,ceil((span+width*(1+p.tail*4+.88))/(speed*fmax(.05,1-p.jitter*.5))*p.rate)+1);
 PatchTraceReal noise=patch_trace_mod(floor(x*120)*37+floor(t*30)*17+identity*13,101)/101;
 PatchTraceColor glow=patch_trace_glow(p,colors,count,latest,x,t);
 PatchTraceReal spray=p.spray*exp(-x*35)*noise*.25;result.r=glow.r*spray;result.g=glow.g*spray;result.b=glow.b*spray;
 for(int i=0;i<packets;i++){
  PatchTraceReal packet=latest-i;if(packet<0)break;PatchTraceReal seed=patch_trace_mod(packet*37+identity*17,1009)/1009,pos,heading=1,colorIndex=packet;
  if(p.reflect){PatchTraceReal elapsed=t-p.motionTime,distance=p.motionDistance+elapsed*speed,jitterDistance=p.motionJitterDistance+elapsed*speed*p.jitter;
   PatchTraceReal travel=(distance+jitterDistance*(patch_trace_mod(identity*17,1009)/1009-.5))/span,phase=patch_trace_mod(travel,2);pos=span*(phase<1?phase:2-phase);heading=phase<1?1:-1;colorIndex=floor(travel);seed=patch_trace_mod(colorIndex*37+identity*17,1009)/1009;
  }else pos=(t-packet/p.rate)*speed*(1+p.jitter*(seed-.5));
  PatchTraceReal d=(x-pos)*heading,head=exp(-.5*pow(d/(width*.22),2)),tail=d<=0?patch_trace_clamp(1+d/(width*(1+p.tail*4))):0;
  PatchTraceReal flow=(head*.55+tail*.75)*(1-p.crackle*.9*(1-noise))+p.forks*head*pow(sin(x*250+t*70+identity*.37),2)*.3;
  glow=patch_trace_glow(p,colors,count,colorIndex,x,t);PatchTraceColor core=p.singleColor?glow:p.core;PatchTraceReal gain=1+p.burst*seed;
  result.r+=(glow.r*flow+core.r*head)*gain;result.g+=(glow.g*flow+core.g*head)*gain;result.b+=(glow.b*flow+core.b*head)*gain;
 }
 result.r=patch_trace_clamp(result.r*p.brightness);result.g=patch_trace_clamp(result.g*p.brightness);result.b=patch_trace_clamp(result.b*p.brightness);return result;
}

// Continuous trace sampling for both normalized LED positions and editor previews.
typedef struct {
    int kind, beatSync;
    PatchTraceReal speed,beatSpeed,tail,drag,rainbow,spread,brightness,pulse,breathe;
    PatchTraceReal rate,perBeat,onTime,attack,release,floor,curve,ratePhase,motionTime;
    PatchTraceColor tint;
} PatchLineTrace;
static inline PatchTraceColor patch_line_sample(PatchLineTrace c,PatchTraceReal x,PatchTraceReal t,PatchTraceReal beat) {
    PatchTraceReal envelope=exp(-3*patch_trace_mod(beat,1)),gain=1,phase=0,mix=0;
    if(c.kind==1){phase=x*c.spread+beat*c.speed*.25;mix=1;gain=c.brightness*(1-c.pulse*(1-envelope));}
    else if(c.kind==3)gain=1-c.breathe*.6*(1-envelope);
    else if(c.kind==2){
        PatchTraceReal f=patch_trace_mod(c.beatSync?beat*c.perBeat:c.ratePhase+(t-c.motionTime)*c.rate,1);
        PatchTraceReal scale=c.onTime/fmax(1,c.attack+c.release),a=c.attack*scale,r=c.release*scale;
        PatchTraceReal level=f>=c.onTime?0:fmin(1,fmin(a>0?f/a:1,r>0?(c.onTime-f)/r:1));
        gain=c.floor+(1-c.floor)*pow(level*level*(3-2*level),c.curve);
    }else{
        PatchTraceReal d=patch_trace_mod((c.beatSync?beat*c.beatSpeed:t*c.speed)-x,1);
        gain=fmax(fmax(0,1-d/fmax(.000001,c.tail)),c.drag*exp(-d/fmax(.005,c.tail*(.2+c.drag))));
        phase=x+t*.04;mix=c.rainbow;
    }
    PatchTraceReal angle=phase*6.283185307179586;
    PatchTraceColor out;
    out.r=gain*(c.tint.r*(1-mix)+mix*(.5+.5*cos(angle)));
    out.g=gain*(c.tint.g*(1-mix)+mix*(.5+.5*cos(angle-2.094395102393195)));
    out.b=gain*(c.tint.b*(1-mix)+mix*(.5+.5*cos(angle-4.188790204786391)));
    return out;
}

)

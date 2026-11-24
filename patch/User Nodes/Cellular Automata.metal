#include <metal_stdlib>
using namespace metal;

// a: rule, initial density, seed, reset. b: injection, trail, wrap, neighborhood.
// c: cyclic states, threshold, generation, reserved.
uint cellHash(uint x) { x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; return x ^ (x >> 16); }
float cellRandom(uint2 p,uint seed,uint generation) { return float(cellHash(p.x+4099u*p.y+131071u*seed+524287u*generation)&0xffffffu)/16777216.0; }
kernel void cellularStep(texture2d<float,access::read> old [[texture(0)]],
                         texture2d<float,access::write> next [[texture(1)]],
                         constant float4 *controls [[buffer(0)]],uint2 cell [[thread_position_in_grid]]) {
    uint2 grid(next.get_width(),next.get_height()); if(any(cell>=grid)) return;
    float4 a=controls[0],b=controls[1],c=controls[2];
    uint rule=uint(a.x),states=uint(c.x),seed=uint(a.z),generation=uint(c.z);
    float state=0,trail=0;
    if(a.w>0.5) {
        float r=cellRandom(cell,seed,0);
        state=rule==4 ? (r<a.y?floor(cellRandom(cell,seed+17,0)*float(states)):0.0) : (r<a.y?1.0:0.0);
    } else {
        float4 previous=old.read(cell); uint current=uint(round(previous.r));
        uint alive=0,successors=0; uint successor=(current+1)%states;
        for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++) {
            if((x==0&&y==0)||(b.w>0.5&&abs(x)+abs(y)!=1)) continue;
            int2 p=int2(cell)+int2(x,y);
            if(b.z>0.5) p=(p+int2(grid))%int2(grid);
            else if(any(p<0)||any(p>=int2(grid))) continue;
            uint neighbor=uint(round(old.read(uint2(p)).r));
            alive+=neighbor==1; successors+=neighbor==successor;
        }
        if(rule==0||rule==1) state=(current==1?(alive==2||alive==3):(alive==3||(rule==1&&alive==6)))?1:0;
        else if(rule==2) state=current==0&&alive==2?1:0;
        else if(rule==3) state=current==1?2:(current==2?0:(alive==2?1:0));
        else state=successors>=uint(c.y)?float(successor):float(current);
        if(cellRandom(cell,seed,generation+1)<b.x) state=rule==4?float(successor):1.0;
        trail=previous.g*b.y;
    }
    float activity=rule==4 ? (state<1?1.0:0.0) : (state==1?1.0:0.0);
    next.write(float4(state,max(activity,trail),0,1),cell);
}

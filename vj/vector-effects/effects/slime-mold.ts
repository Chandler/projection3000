import {ABI_VERSION,COMMAND_CAPACITY,PARAM_CAPACITY,beginFrame,commandsPointer,finishFrame,getParam,lineVertex,moveVertex,paramsPointer} from '../sdk/graphics-v2';
import {hash2} from '../sdk/math';
export function abi_version():i32{return ABI_VERSION;}
export function params_ptr():usize{return paramsPointer();}
export function params_capacity():i32{return PARAM_CAPACITY;}
export function commands_ptr():usize{return commandsPointer();}
export function commands_capacity():i32{return COMMAND_CAPACITY;}
const x=new StaticArray<f32>(600),y=new StaticArray<f32>(600),dist=new StaticArray<f32>(600),cost=new StaticArray<f32>(600),mass=new StaticArray<f32>(600);
const tx=new StaticArray<f32>(600),ty=new StaticArray<f32>(600);
const parent=new StaticArray<i32>(600),order=new StaticArray<i32>(600),used=new StaticArray<i32>(600),cache=new StaticArray<f32>(6);
let ready:bool=false;
function build(n:i32):void{
 let changed=!ready;
 for(let k=0;k<6;k++){const v=getParam(k==5?12:k);if(cache[k]!=v)changed=true;cache[k]=v;}
 if(!changed)return;ready=true;
 const seed=<i32>getParam(0),aspect=getParam(12);
 x[0]=getParam(3);y[0]=getParam(4);
 for(let i=1;i<n;i++){
  x[i]=hash2(i,seed,17);y[i]=hash2(i,seed,41);
  if(i<=40){const side=i%4;const t=<f32>(i/4)/10;
   if(side==0){x[i]=0;y[i]=t;}else if(side==1){x[i]=1;y[i]=t;}else if(side==2){x[i]=t;y[i]=0;}else{x[i]=t;y[i]=1;}}
 }
 for(let i=0;i<n;i++){cost[i]=1e9;used[i]=0;mass[i]=1;dist[i]=0;parent[i]=0;}cost[0]=0;
 // Cached rooted spatial tree, with a path-cost bias for radial growth.
 for(let k=0;k<n;k++){
  let a:i32=0;let score:f32=1e10;
  for(let i=0;i<n;i++)if(used[i]==0&&cost[i]<score){a=i;score=cost[i];}
  used[a]=1;order[k]=a;
  if(a!=0){const p=parent[a],dx=(x[a]-x[p])/aspect,dy=y[a]-y[p];dist[a]=dist[p]+Mathf.sqrt(dx*dx+dy*dy);}
  for(let b=1;b<n;b++)if(used[b]==0){const dx=(x[a]-x[b])/aspect,dy=y[a]-y[b];const v=Mathf.sqrt(dx*dx+dy*dy)+dist[a]*getParam(2)*<f32>.35;if(v<cost[b]){cost[b]=v;parent[b]=a;}}
 }
 for(let k=n-1;k>0;k--){const a=order[k];mass[parent[a]]+=mass[a];}
 // Smooth the main vein through each fork; side branches leave along that
 // tangent instead of forming a rigid star of straight segments.
 for(let a=0;a<n;a++){
  let child:i32=-1;let biggest:f32=0;
  for(let b=1;b<n;b++)if(parent[b]==a&&mass[b]>biggest){child=b;biggest=mass[b];}
  const p=parent[a];
  let dx=(x[a]-x[p])/aspect,dy=y[a]-y[p];
  if(child>=0){dx=(x[child]-x[p])/aspect;dy=y[child]-y[p];}
  const norm=Mathf.max(<f32>.00001,Mathf.sqrt(dx*dx+dy*dy));
  tx[a]=dx/norm;ty[a]=dy/norm;
 }
}
export function render(time:f64,_beat:f64):i32{
 const n=<i32>getParam(1);build(n);beginFrame();
 const width=getParam(5),pulse=getParam(6),speed=getParam(7),length=getParam(8),r=getParam(9),g=getParam(10),b=getParam(11);
 for(let i=1;i<n;i++){
  const p=parent[i],aspect=getParam(12);
  const dx=(x[i]-x[p])/aspect,dy=y[i]-y[p];
  const span=Mathf.sqrt(dx*dx+dy*dy);
  const leaf=mass[i]==1;
  const bend=(hash2(i,<i32>getParam(0),93)-<f32>.5)*<f32>1.4;
  const startX=p==0?dx/Mathf.max(span,<f32>.00001):tx[p];
  const startY=p==0?dy/Mathf.max(span,<f32>.00001):ty[p];
  // Cubic paths preserve forks but turn terminal sticks into curling tips.
  const endX=leaf?tx[i]*Mathf.cos(bend)-ty[i]*Mathf.sin(bend):tx[i];
  const endY=leaf?tx[i]*Mathf.sin(bend)+ty[i]*Mathf.cos(bend):ty[i];
  const ax=x[p]+startX*span*aspect*<f32>.38,ay=y[p]+startY*span*<f32>.38;
  const bx=x[i]-endX*span*aspect*<f32>.38,by=y[i]-endY*span*<f32>.38;
  const w=width*(<f32>.65+Mathf.sqrt(mass[i]/<f32>n)*4);
  for(let j=0;j<=7;j++){
   const t=<f32>j/7,u=<f32>1-t,d=dist[p]+(dist[i]-dist[p])*t,phase=d-<f32>time*speed;
   const wrapped=phase-Mathf.floor(phase/<f32>.65)*<f32>.65;
   const light=<f32>1-pulse+pulse*(<f32>.15+<f32>.85*Mathf.exp(-wrapped*wrapped/(length*length)));
   const ripple=Mathf.sin(t*<f32>3.14159265)*Mathf.sin(t*<f32>3.14159265)*bend*<f32>.18;
   const px=Mathf.max(0,Mathf.min(1,u*u*u*x[p]+3*u*u*t*ax+3*u*t*t*bx+t*t*t*x[i]-dy*aspect*ripple));
   const py=Mathf.max(0,Mathf.min(1,u*u*u*y[p]+3*u*u*t*ay+3*u*t*t*by+t*t*t*y[i]+dx*ripple));
   const taper=leaf?Mathf.sqrt(u):<f32>1;
   if(j==0)moveVertex(px,py,r*light,g*light,b*light,1,0,0,0,0,w,0);
   else lineVertex(px,py,r*light,g*light,b*light,taper,0,0,0,0,w*(<f32>.1+<f32>.9*taper),0);
  }
 }
 return finishFrame();
}

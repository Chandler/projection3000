#pragma once
namespace vj {
inline constexpr const char* remotePage=R"VJREMOTE(<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes"><meta name="theme-color" content="#1e2022">
<title>VJ Mapping</title>
<style>
:root{--bg:#1e2022;--panel:#292c2f;--line:#3a3e42;--text:#e6e8ea;--dim:#8a9096;--accent:#8fc6db;--engaged:#344a52;--bad:#ff6b6b}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;background:var(--bg);color:var(--text);font:15px -apple-system,system-ui,sans-serif;overscroll-behavior:none}
body{padding:env(safe-area-inset-top) 10px env(safe-area-inset-bottom);display:flex;flex-direction:column;gap:8px;min-height:100vh;user-select:none;-webkit-user-select:none}
body>*{min-width:0}
.row{display:flex;gap:6px;align-items:center}
select,button{font:inherit;color:var(--text);background:var(--panel);border:1px solid var(--line);border-radius:8px;height:40px;padding:0 10px;touch-action:manipulation}
select{flex:1;min-width:0}
button.on{background:var(--engaged);border-color:var(--accent);color:var(--accent)}
button:disabled{opacity:.35}
#dot{width:10px;height:10px;border-radius:50%;background:var(--dim);flex:none}
#dot.ok{background:#3c3}#dot.bad{background:var(--bad)}
#stage{position:relative;touch-action:none;background:var(--bg);border:1px solid var(--line);border-radius:8px;overflow:hidden;height:52vh}
#stage img,#stage canvas{position:absolute;inset:0;width:100%;height:100%}
#stage img{object-fit:fill;visibility:hidden}
#resetView{position:absolute;top:8px;right:8px;height:36px;display:none;background:rgba(41,44,47,.9)}
#status{color:var(--dim);font-size:13px;min-height:18px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#status.bad{color:var(--bad)}
.seg{display:flex;flex:1}.seg button{flex:1;border-radius:0;margin-left:-1px;padding:0}
.seg button:first-child{border-radius:8px 0 0 8px;margin-left:0}.seg button:last-child{border-radius:0 8px 8px 0}
#pad{display:grid;grid-template-columns:repeat(3,64px);grid-template-rows:repeat(2,48px);gap:6px;justify-content:center}
#pad button{height:100%;font-size:20px}
label{color:var(--dim);font-size:12px;width:40px;flex:none}
</style></head><body>
<div class="row"><span id="dot"></span><select id="mapping" aria-label="Projector"></select><button id="undo">Undo</button><button id="redo">Redo</button><button id="grid">Grid</button></div>
<div class="row"><button id="prev" aria-label="Previous object">‹</button><select id="object" aria-label="Object"></select><button id="next" aria-label="Next object">›</button><button id="all">All</button></div>
<div id="stage"><img id="live" alt=""><canvas id="canvas"></canvas><button id="resetView">Reset view</button></div>
<div class="row" id="status"></div>
<div class="row"><label>Tool</label><div class="seg" id="tools"></div></div>
<div class="row"><label>Keys</label><div class="seg"><button id="shift">Shift</button><button id="command">⌘</button><button id="additive">Add</button><button id="curves">Curves</button><button id="esc">Esc</button></div></div>
<div class="row"><label>Drag</label><div class="seg" id="speeds"></div></div>
<div class="row"><label>View</label><div class="seg"><button id="fit">Reset</button><button id="fitSel">Sel</button><button id="zoomOut">−</button><button id="zoomIn">+</button><button id="liveToggle">Live</button></div></div>
<div class="row"><label>Nudge</label><button id="target" style="flex:1"></button></div>
<div id="pad"><span></span><button data-d="0,-1">↑</button><span></span><button data-d="-1,0">←</button><button data-d="0,1">↓</button><button data-d="1,0">→</button></div>
<script>
const key=new URLSearchParams(location.search).get('k')||'';
const $=id=>document.getElementById(id);
const store={get(k,d){try{const v=localStorage.getItem('vjr.'+k);return v===null?d:JSON.parse(v)}catch{return d}},set(k,v){try{localStorage.setItem('vjr.'+k,JSON.stringify(v))}catch{}}};
let ws=null,state=null,mid=store.get('mapping','1'),speed=store.get('speed',1),live=store.get('live',true),curves=false,tool=store.get('tool','move');
const mods={shift:false,command:false,additive:false};
let zoom=1,pan={x:0,y:0};
const SPEEDS=[[1,'1×'],[.25,'¼×'],[.05,'1/20×']],TOOLS=[['move','Move'],['scale','Scale'],['rotate','Rotate']];
const canvas=$('canvas'),ctx=canvas.getContext('2d');
const rgb=(r,g,b,a=1)=>`rgba(${Math.round(r*255)},${Math.round(g*255)},${Math.round(b*255)},${a})`;
const OVERLAY='#c084fc';

function status(text,bad){$('status').textContent=text||'';$('status').className='row'+(bad?' bad':'');}
function connect(){
  ws=new WebSocket((location.protocol==='https:'?'wss://':'ws://')+location.host+'/remote/ws?k='+encodeURIComponent(key));
  ws.onopen=()=>{$('dot').className='ok';sendView()};
  ws.onclose=()=>{$('dot').className='bad';status('Disconnected',true);setTimeout(connect,1000)};
  ws.onmessage=e=>{const m=JSON.parse(e.data);if(m.type!=='scene')return;state=m;mid=m.mappingId;inflight=false;flushMove();controls();draw()};
}
function send(m){if(ws&&ws.readyState===1)ws.send(JSON.stringify(m))}
const size=()=>({w:canvas.clientWidth,h:canvas.clientHeight});
// The Mapper's map rectangle: inset, aspect-fit, then zoomed and panned.
function bounds(){const {w:W,h:H}=size(),ratio=(state&&state.scene&&state.scene.aspect)||16/9;let w=Math.max(100,W-32),h=Math.max(100,H-32);if(w/h>ratio)w=h*ratio;else h=w/ratio;return {x:(W-w)/2+pan.x,y:(H-h)/2+pan.y,w:w*zoom,h:h*zoom}}
function sendView(){const {w,h}=size();send({type:'view',mapping:mid,bounds:bounds(),viewport:{x:0,y:0,w,h},hitScale:2.5,curves});$('resetView').style.display=zoom!==1||pan.x||pan.y?'block':'none'}

function controls(){
  const sel=$('mapping');sel.innerHTML='';for(const m of state.mappings){const o=new Option(m.name,m.id);o.selected=m.id===mid;sel.add(o)}
  const obj=$('object');obj.innerHTML='';const none=new Option(state.selected.length>1?state.selected.length+' selected':'—','');obj.add(none);
  for(const o of state.objects||[]){const opt=new Option((o.kind==='trace'?'Trace · ':'')+o.name,o.kind+':'+o.id);opt.selected=(o.kind==='trace'?state.selectedTrace===o.id:state.selected.length===1&&state.selected[0]===o.id);obj.add(opt)}
  $('undo').disabled=!(state.history&&state.history.can_undo);$('redo').disabled=!(state.history&&state.history.can_redo);
  $('grid').className=state.output&&state.output.boundsGrid?'on':'';
  for(const k of ['shift','command','additive'])$(k).className=mods[k]?'on':'';$('liveToggle').className=live?'on':'';$('curves').className=curves?'on':'';
  const tl=$('tools');tl.innerHTML='';for(const [v,l] of TOOLS){const b=document.createElement('button');b.textContent=l;b.className=v===tool?'on':'';b.onclick=()=>{tool=v;store.set('tool',v);controls()};tl.appendChild(b)}
  const c=state.activeCorner;$('target').textContent=c?'Corner '+(c.index+1)+' ×':state.selectedTrace?'Trace':'Selection';$('target').className=c?'on':'';
  const sp=$('speeds');sp.innerHTML='';for(const [v,l] of SPEEDS){const b=document.createElement('button');b.textContent=l;b.className=v===speed?'on':'';b.onclick=()=>{speed=v;store.set('speed',v);controls()};sp.appendChild(b)}
  if(state.status)status(state.status,true);else status(state.layout?state.layout.name+(state.layout.modified?' •':''):'Projector '+mid);
}

function layout(){const dpr=devicePixelRatio||1;canvas.width=canvas.clientWidth*dpr;canvas.height=canvas.clientHeight*dpr;placeLive();sendView();draw()}
function placeLive(){const b=bounds(),img=$('live');Object.assign(img.style,{left:b.x+'px',top:b.y+'px',width:b.w+'px',height:b.h+'px',right:'auto',bottom:'auto'})}
function draw(){
  const dpr=devicePixelRatio||1;ctx.setTransform(dpr,0,0,dpr,0,0);const {w:W,h:H}=size();ctx.clearRect(0,0,W,H);
  const b=bounds(),showLive=live&&$('live').style.visibility==='visible';
  if(!showLive){ctx.fillStyle='#000';ctx.fillRect(b.x,b.y,b.w,b.h)}ctx.strokeStyle=rgb(.25,.28,.3);ctx.lineWidth=1;ctx.strokeRect(b.x,b.y,b.w,b.h);
  if(!state||!state.scene)return;const S=state.scene,P=p=>[b.x+p[0]*b.w,b.y+p[1]*b.h];
  const path=pts=>{ctx.beginPath();pts.forEach((p,i)=>{const [x,y]=P(p);i?ctx.lineTo(x,y):ctx.moveTo(x,y)});ctx.closePath()};
  // Every fill first, so an overlay never covers outlines of earlier surfaces.
  for(const r of S.rects){path(r.outline);if(!showLive){ctx.fillStyle=r.muted?rgb(.08,.08,.08):r.overlay?rgb(.11,.10,.14):rgb(.075,.14,.12);ctx.fill()}if(r.overlay&&r.active){ctx.fillStyle='rgba(192,132,252,.095)';ctx.fill()}}
  const hs=1.6;
  for(const r of S.rects){
    path(r.outline);ctx.setLineDash(r.overlay?[8,5]:[]);ctx.strokeStyle='rgba(0,0,0,.8)';ctx.lineWidth=r.active?4:3;ctx.stroke();
    const color=r.overlay?OVERLAY:r.active?rgb(.27,.95,.58):rgb(.24,.75,.47);ctx.strokeStyle=color;ctx.lineWidth=r.active?2:1.5;ctx.stroke();
    if(r.seam){ctx.beginPath();ctx.moveTo(...P(r.seam[0]));ctx.lineTo(...P(r.seam[1]));ctx.stroke()}ctx.setLineDash([]);
    if(r.active){ctx.fillStyle=r.overlay?OVERLAY:rgb(.27,.95,.58);for(const p of r.handles||[]){const [x,y]=P(p);ctx.fillRect(x-3*hs,y-3*hs,6*hs,6*hs)}if(r.gridMarker){const [x,y]=P(r.gridMarker);ctx.fillRect(x-3*hs,y-3*hs,6*hs,6*hs)}}
  }
  if(state.activeCorner)for(const r of S.rects)if(r.id===state.activeCorner.id&&r.handles&&r.handles[state.activeCorner.index]){const [x,y]=P(r.handles[state.activeCorner.index]);ctx.strokeStyle='#fff';ctx.lineWidth=2;ctx.beginPath();ctx.arc(x,y,9,0,7);ctx.stroke()}
  if(S.rotation){const [x,y]=P(S.rotation.point),[ax,ay]=P(S.rotation.anchor);ctx.strokeStyle=rgb(.55,.42,.25);ctx.beginPath();ctx.moveTo(ax,ay);ctx.lineTo(x,y);ctx.stroke();ctx.fillStyle=rgb(.9,.62,.26);ctx.beginPath();ctx.arc(x,y,10*hs/1.2,0,7);ctx.fill();ctx.fillStyle='#000';ctx.font='15px -apple-system';ctx.textAlign='center';ctx.textBaseline='middle';ctx.fillText('↻',x,y+1)}
  ctx.textAlign='left';ctx.textBaseline='alphabetic';ctx.font='11px -apple-system';
  for(const r of S.rects){
    for(const e of r.edges||[]){const [x,y]=P(e.point);ctx.fillStyle=r.overlay?OVERLAY:rgb(.35,.65,.95);ctx.beginPath();ctx.arc(x,y,5*hs,0,7);ctx.fill();ctx.fillStyle=rgb(.8,.85,.83);ctx.fillText(e.label,x+7*hs,y+4)}
    for(const p of r.pins||[]){const [x,y]=P(p.point),d=5*hs;ctx.fillStyle=r.overlay?OVERLAY:p.enabled?rgb(.95,.65,.22):rgb(.4,.4,.4);ctx.beginPath();ctx.moveTo(x,y-d);ctx.lineTo(x+d,y);ctx.lineTo(x,y+d);ctx.lineTo(x-d,y);ctx.closePath();ctx.fill()}
  }
  for(const t of S.traces){
    ctx.beginPath();t.points.forEach((p,i)=>{const [x,y]=P(p);i?ctx.lineTo(x,y):ctx.moveTo(x,y)});ctx.lineCap='round';ctx.lineJoin='round';
    if(!showLive){ctx.lineWidth=Math.max(2,t.width*b.h);ctx.strokeStyle=t.enabled?rgb(.18,.4,.43):rgb(.15,.16,.17);ctx.stroke()}
    ctx.lineWidth=t.active?2:1;ctx.strokeStyle=t.active?rgb(.3,.95,.65):rgb(.5,.7,.7);ctx.stroke();
    if(t.active){ctx.fillStyle=rgb(.3,.95,.65);let cx=0,cy=0;for(const p of t.points){const [x,y]=P(p);cx+=x/t.points.length;cy+=y/t.points.length;ctx.beginPath();ctx.arc(x,y,4*hs,0,7);ctx.fill()}ctx.fillRect(cx-3*hs,cy-3*hs,6*hs,6*hs)}
  }
  if(state.marquee){const [x,y,w,h]=state.marquee;ctx.fillStyle='rgba(51,179,128,.14)';ctx.fillRect(b.x+x*b.w,b.y+y*b.h,w*b.w,h*b.h);ctx.strokeStyle=rgb(.3,.85,.6);ctx.strokeRect(b.x+x*b.w,b.y+y*b.h,w*b.w,h*b.h)}
}

// One finger is the Mapper pointer; slower drag speeds move it relative to the finger.
// Two fingers pinch-zoom and pan the view, cancelling any pointer gesture.
const touches=new Map();let inflight=false,pendingMove=null,pointer=null,pinch=null,lastTap={t:0,x:0,y:0};
const local=e=>{const r=canvas.getBoundingClientRect();return {x:e.clientX-r.left,y:e.clientY-r.top}};
canvas.addEventListener('pointerdown',e=>{
  canvas.setPointerCapture(e.pointerId);const p=local(e);touches.set(e.pointerId,p);
  if(touches.size===2){if(pointer){send({type:'cancel'});pointer=null}const [a,c]=[...touches.values()];pinch={d:Math.hypot(a.x-c.x,a.y-c.y),mx:(a.x+c.x)/2,my:(a.y+c.y)/2,zoom,pan:{...pan}};return}
  if(touches.size>2)return;
  const now=performance.now(),double=now-lastTap.t<350&&Math.hypot(p.x-lastTap.x,p.y-lastTap.y)<24;lastTap={t:double?0:now,x:p.x,y:p.y};
  pointer={id:e.pointerId,start:p,at:p};
  send({type:'down',tool,x:p.x,y:p.y,clickCount:double?2:1,shift:mods.shift,command:mods.command,additive:mods.additive,bounds:bounds()});
});
canvas.addEventListener('pointermove',e=>{
  if(!touches.has(e.pointerId))return;const p=local(e);touches.set(e.pointerId,p);
  if(pinch&&touches.size===2){const [a,c]=[...touches.values()],d=Math.hypot(a.x-c.x,a.y-c.y),mx=(a.x+c.x)/2,my=(a.y+c.y)/2;zoomAround(pinch.mx,pinch.my,Math.min(40,Math.max(.25,pinch.zoom*d/Math.max(1,pinch.d))),pinch.pan);pan.x+=mx-pinch.mx;pan.y+=my-pinch.my;placeLive();draw();return}
  if(!pointer||pointer.id!==e.pointerId)return;pointer.at={x:pointer.start.x+(p.x-pointer.start.x)*speed,y:pointer.start.y+(p.y-pointer.start.y)*speed};
  pendingMove={type:'move',x:pointer.at.x,y:pointer.at.y,shift:mods.shift};flushMove();
});
// Over slow Wi-Fi, queued moves would trail the finger; keep one in flight and send the latest.
function flushMove(){if(inflight||!pendingMove)return;inflight=true;send(pendingMove);pendingMove=null}
function release(e){
  touches.delete(e.pointerId);
  if(pinch){if(touches.size<2){pinch=null;sendView()}return}
  if(pointer&&pointer.id===e.pointerId){pendingMove=null;send({type:e.type==='pointercancel'?'cancel':'up',x:pointer.at.x,y:pointer.at.y,shift:mods.shift});pointer=null}
}
canvas.addEventListener('pointerup',release);canvas.addEventListener('pointercancel',release);
function zoomAround(x,y,next,base){const b0=bounds(),from=zoom;zoom=next;pan={...base};const b1=bounds();pan.x+=x-(b1.x+(x-b0.x)*(next/from));pan.y+=y-(b1.y+(y-b0.y)*(next/from))}
function zoomBy(f){const {w,h}=size();zoomAround(w/2,h/2,Math.min(40,Math.max(.25,zoom*f)),pan);placeLive();sendView();draw()}
$('zoomIn').onclick=()=>zoomBy(1.4);$('zoomOut').onclick=()=>zoomBy(1/1.4);
$('target').onclick=()=>send({type:'clearCorner'});
$('fitSel').onclick=()=>{if(!state||!state.scene)return;let lo=[1/0,1/0],hi=[-1/0,-1/0];const add=p=>{for(let a=0;a<2;a++){lo[a]=Math.min(lo[a],p[a]);hi[a]=Math.max(hi[a],p[a])}};
  for(const r of state.scene.rects)if(r.active)r.outline.forEach(add);for(const t of state.scene.traces)if(t.active)t.points.forEach(add);if(!isFinite(lo[0]))return;
  zoom=1;pan={x:0,y:0};const b0=bounds(),{w,h}=size();zoom=Math.min(40,Math.max(.25,1/(Math.max(hi[0]-lo[0],hi[1]-lo[1])*1.6||1)));
  pan={x:w/2-b0.x-(lo[0]+hi[0])/2*b0.w*zoom,y:h/2-b0.y-(lo[1]+hi[1])/2*b0.h*zoom};placeLive();sendView();draw()};
const resetView=()=>{zoom=1;pan={x:0,y:0};placeLive();sendView();draw()};$('fit').onclick=resetView;$('resetView').onclick=resetView;

for(const k of ['shift','command','additive'])$(k).onclick=()=>{mods[k]=!mods[k];controls()};
$('curves').onclick=()=>{curves=!curves;sendView();controls()};
$('esc').onclick=()=>{pointer=null;send({type:'cancel'})};
$('undo').onclick=()=>send({type:'undo'});$('redo').onclick=()=>send({type:'redo'});$('grid').onclick=()=>send({type:'grid'});
$('all').onclick=()=>send({type:'selectAll'});
$('mapping').onchange=e=>{mid=e.target.value;store.set('mapping',mid);zoom=1;pan={x:0,y:0};placeLive();sendView()};
function pickObject(v){if(!v)return send({type:'select',ids:[]});const i=v.indexOf(':'),kind=v.slice(0,i),id=v.slice(i+1);send(kind==='trace'?{type:'selectTrace',id}:{type:'select',ids:[id]})}
$('object').onchange=e=>pickObject(e.target.value);
const cycle=d=>{const o=$('object'),n=o.options.length-1;if(n<1)return;let i=o.selectedIndex-1;i=i<0?(d>0?0:n-1):(i+d+n)%n;pickObject(o.options[i+1].value)};
$('prev').onclick=()=>cycle(-1);$('next').onclick=()=>cycle(1);
document.querySelectorAll('#pad button').forEach(b=>{let repeat=null;const [dx,dy]=b.dataset.d.split(',').map(Number);const nudge=()=>send({type:'nudge',dx,dy,shift:mods.shift});
  b.addEventListener('pointerdown',e=>{e.preventDefault();nudge();repeat=setTimeout(function tick(){nudge();repeat=setTimeout(tick,80)},400)});
  const stop=()=>{clearTimeout(repeat);repeat=null};b.addEventListener('pointerup',stop);b.addEventListener('pointerleave',stop);b.addEventListener('pointercancel',stop)});

// Live underlay: the projector's mapping output, when it is being published.
const img=$('live');let frameBusy=false,frameWait=0;
img.onload=()=>{img.style.visibility=live?'visible':'hidden';frameBusy=false;frameWait=0;draw()};img.onerror=()=>{img.style.visibility='hidden';frameBusy=false;frameWait=25;draw()};
setInterval(()=>{if(frameWait>0){frameWait--;return}if(!live||frameBusy||document.hidden||pointer)return;frameBusy=true;img.src='/remote/frame?k='+encodeURIComponent(key)+'&mapping='+encodeURIComponent(mid)+'&t='+Date.now()},200);
$('liveToggle').onclick=()=>{live=!live;store.set('live',live);if(!live)img.style.visibility='hidden';controls();draw()};
addEventListener('resize',layout);
layout();connect();
</script></body></html>)VJREMOTE";
}

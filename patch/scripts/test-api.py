#!/usr/bin/env python3
"""Integration checks against an isolated --headless instance on port 9418."""
import json, pathlib, urllib.request, urllib.error, uuid, time, tempfile, subprocess, os
ROOT=pathlib.Path(__file__).resolve().parents[1]
TOKEN=(pathlib.Path.home()/'Library/Application Support/Patch/api-token').read_text().strip()
PORT=int(os.environ.get('PATCH_API_PORT','9418'))
def request(path,body=None,auth=True,headers=None):
    h={'Content-Type':'application/json'}
    if auth:h['Authorization']='Bearer '+TOKEN
    h.update(headers or {})
    req=urllib.request.Request(f'http://127.0.0.1:{PORT}'+path,data=json.dumps(body).encode() if body is not None else None,headers=h)
    try:
        with urllib.request.urlopen(req,timeout=12) as r:return r.status,json.load(r)
    except urllib.error.HTTPError as e:return e.code,json.load(e)
def cmd(body):
    status,result=request('/v1/commands',body)
    assert status==200,(status,result)
    return result
def state():return request('/v1/state')[1]
def rejected(body):assert request('/v1/commands',body)[0]==400
assert request('/health',auth=False)[0]==200
assert request('/v1/state',auth=False)[0]==401
assert request('/v1/state',headers={'Origin':'http://example.com'})[0]==403
print('PASS loopback API authentication and browser-origin rejection')
schema=request('/v1/schema')[1]
assert set(schema['portTypes'])=={'geometry','video','audio','faces'}
assert len(schema['nodes'])==24
initial=state()['graph']
assert [n['kind'] for n in initial['nodes']]==['lorenz','render','crt','window']
ids={n['kind']:n['id'] for n in initial['nodes']}
rejected({'op':'connect','source':ids['lorenz'],'target':ids['crt']})
rejected({'op':'connect','source':ids['crt'],'target':ids['crt']})
rejected({'op':'parameter','id':ids['crt'],'key':'noise','value':8})
assert state()['graph']==initial
print('PASS typed connections and invalid edits preserve graph')
color=str(uuid.uuid4())
result=cmd([{'op':'add','kind':'color','id':color,'x':450,'y':450},{'op':'connect','source':ids['render'],'target':color},{'op':'parameter','id':color,'key':'exposure','value':0.5}])
assert result['results'][0]['id'].lower()==color
before=state()['graph']
rejected([{'op':'parameter','id':color,'key':'exposure','value':1.5},{'op':'connect','source':color,'target':color}])
assert state()['graph']==before
cmd({'op':'remove','id':color})
assert state()['graph']==initial
print('PASS atomic batch transaction and rollback')
cmd({'op':'pause'}); time.sleep(.2); t=state()['time']; time.sleep(.15); assert state()['time']==t
cmd({'op':'play'}); time.sleep(.15); assert state()['time']>t
print('PASS deterministic pause / resume')
with tempfile.TemporaryDirectory(prefix='patch-api-') as directory:
    path=str(pathlib.Path(directory)/'roundtrip.patch.json')
    cmd({'op':'save','path':path}); assert json.loads(pathlib.Path(path).read_text())==initial
    cmd({'op':'parameter','id':ids['crt'],'key':'noise','value':0.1})
    rejected({'op':'open','path':path})
    cmd({'op':'open','path':path,'discardChanges':True}); assert state()['graph']==initial
    snap=str(pathlib.Path(directory)/'lorenz.png'); cmd({'op':'snapshot','id':ids['crt'],'path':snap}); assert pathlib.Path(snap).read_bytes().startswith(b'\x89PNG')
    print('PASS save / load roundtrip and rendered PNG snapshot')
    shader=pathlib.Path(directory)/'animation.metal'
    shader.write_text('float3 animation(float2 uv, float time) { return float3(uv.x, uv.y, 0.5 + 0.5*sin(time)); }')
    shader_id=cmd({'op':'add','kind':'shader','file':str(shader)})['id']
    for _ in range(60):
        if state()['status'].get(shader_id)=='Ready':break
        time.sleep(.1)
    assert state()['status'].get(shader_id)=='Ready',state()['status']
    shader.write_text('this is not metal')
    for _ in range(30):
        if 'error:' in state()['status'].get(shader_id,''):break
        time.sleep(.1)
    assert 'error:' in state()['status'].get(shader_id,'')
    shader.write_text('float3 animation(float2 uv, float time) { return float3(0.2, 0.7, 1.0); }')
    for _ in range(30):
        if state()['status'].get(shader_id)=='Ready':break
        time.sleep(.1)
    assert state()['status'].get(shader_id)=='Ready'
    cmd({'op':'remove','id':shader_id})
    print('PASS live shader registration, compile failure recovery and hot reload')
    ffmpeg=subprocess.run(['which','ffmpeg'],capture_output=True,text=True).stdout.strip()
    if ffmpeg:
        image=pathlib.Path(directory)/'image.png'; video=pathlib.Path(directory)/'movie.mp4'
        subprocess.run([ffmpeg,'-loglevel','error','-f','lavfi','-i','color=c=orange:s=320x180','-frames:v','1',str(image)],check=True)
        subprocess.run([ffmpeg,'-loglevel','error','-f','lavfi','-i','testsrc2=s=320x180:r=30','-t','1','-c:v','h264_videotoolbox','-pix_fmt','yuv420p',str(video)],check=True)
        for kind,file in [('image',image),('video',video)]:
            id=cmd({'op':'add','kind':kind,'file':str(file)})['id']
            for _ in range(60):
                if state()['status'].get(id)=='Ready':break
                time.sleep(.1)
            assert state()['status'].get(id)=='Ready',(kind,state()['status'])
            frame=pathlib.Path(directory)/(kind+'.png')
            cmd({'op':'snapshot','id':id,'path':str(frame)})
            assert frame.stat().st_size>3000
            if kind=='video':
                time.sleep(1.5)
                later=pathlib.Path(directory)/'video-later.png';cmd({'op':'snapshot','id':id,'path':str(later)})
                assert frame.read_bytes()!=later.read_bytes(),'Video did not animate across loop'
            cmd({'op':'remove','id':id})
        print('PASS image decoding and looping video texture delivery')
    pattern=cmd({'op':'add','kind':'pattern'})['id']
    for kind in ('syphon','ndi'):
        assert state()['outputs'][kind],kind+' unavailable'
        id=cmd({'op':'add','kind':kind,'name':'Patch Integration '+kind.title()})['id']
        cmd({'op':'connect','source':pattern,'target':id})
        time.sleep(.5)
        assert state()['status'][id]=='Publishing',(kind,state()['status'][id])
    print('PASS Syphon and NDI sender startup (receivers tested separately)')
    # Leave senders active for the independent receiver probes.
print('All API integration checks passed')

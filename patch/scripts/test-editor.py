#!/usr/bin/env python3
import json,os,pathlib,urllib.request,subprocess,tempfile,time
from PIL import Image
port=int(os.environ.get('PATCH_API_PORT','9418'));token=(pathlib.Path.home()/'Library/Application Support/Patch/api-token').read_text().strip()
def req(path,body=None):
    with urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{port}'+path,data=None if body is None else json.dumps(body).encode(),headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'}),timeout=10) as r:return json.load(r)
def cmd(body):return req('/v1/commands',body)
def state():return req('/v1/state')
original=state()['graph']
try:
    nodes=original['nodes'];members=[n['id'] for n in nodes if n['kind'] in ['render','crt']]
    component=cmd({'op':'component','nodes':members,'name':'Test Component'})['id']
    before=state()['graph'];assert before['edges']==original['edges']
    cmd({'op':'layout'});after=state()['graph'];assert before['edges']==after['edges']
    cmd({'op':'component_toggle','id':component});assert not state()['graph']['components'][0]['collapsed']
    cmd({'op':'ungroup','id':component});assert state()['graph']['nodes']==after['nodes']
    print('PASS component creation, boundary wiring preservation, layout, expansion and ungrouping API')
    with tempfile.TemporaryDirectory(prefix='patch-trim-') as directory:
        root=pathlib.Path(directory);video=root/'segments.mp4'
        subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i','color=red:s=320x180:r=30:d=1','-f','lavfi','-i','color=green:s=320x180:r=30:d=1','-f','lavfi','-i','color=blue:s=320x180:r=30:d=1','-filter_complex','[0:v][1:v][2:v]concat=n=3:v=1:a=0[v]','-map','[v]','-c:v','h264_videotoolbox',str(video)],check=True)
        id=cmd({'op':'add','kind':'video','file':str(video),'parameters':{'start':1.1,'end':1.9}})['id']
        for _ in range(100):
            if state()['status'].get(id)=='Ready':break
            time.sleep(.05)
        assert state()['status'].get(id)=='Ready',state()['status'].get(id)
        for _ in range(12):
            time.sleep(.25);path=root/'frame.png';cmd({'op':'snapshot','id':id,'path':str(path)})
            r,g,b=Image.open(path).convert('RGB').getpixel((640,360));assert g>r+50 and g>b+50,(r,g,b)
except Exception:
    raise
finally:cmd({'op':'replace','graph':original})
print('PASS video loop remained within trimmed green interval across repeated wraps')

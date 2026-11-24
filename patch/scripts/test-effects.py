#!/usr/bin/env python3
"""GPU pixel regressions for the print/CRT effects and output passthrough."""
import json, os, pathlib, urllib.request, tempfile, time
from PIL import Image, ImageDraw, ImageChops, ImageStat
port=int(os.environ.get('PATCH_API_PORT','9418'))
token=(pathlib.Path.home()/'Library/Application Support/Patch/api-token').read_text().strip()
def request(path, body=None):
    with urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{port}{path}',data=None if body is None else json.dumps(body).encode(),headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'}),timeout=12) as r:return json.load(r)
def cmd(body):return request('/v1/commands',body)
def state():return request('/v1/state')
def param(id,key,value):cmd({'op':'parameter','id':id,'key':key,'value':value});time.sleep(.12)
original=state()['graph'];playing=state()['playing']
try:
    cmd({'op':'replace','graph':{'version':1,'nodes':[],'edges':[],'width':320,'height':180,'fps':60}})
    cmd({'op':'pause'})
    with tempfile.TemporaryDirectory(prefix='patch-effects-') as directory:
        root=pathlib.Path(directory)
        im=Image.new('RGB',(320,180));im.putdata([(int(x/319*255),int(y/179*255),100) for y in range(180) for x in range(320)]);im.save(root/'source.png')
        source=cmd({'op':'add','kind':'image','file':str(root/'source.png')})['id']
        for _ in range(100):
            if state()['status'].get(source)=='Ready':break
            time.sleep(.05)
        def snap(id):
            cmd({'op':'snapshot','id':id,'path':str(root/'frame.png')})
            return Image.open(root/'frame.png').convert('RGB').copy()
        originalPixels=snap(source)
        for kind in ['dither','halftone','diffusion','modulation']:
            id=cmd({'op':'add','kind':kind})['id'];cmd({'op':'connect','source':source,'target':id});time.sleep(.2)
            a=snap(id);time.sleep(.1);b=snap(id)
            assert a.tobytes()==b.tobytes(),kind+' changes when paused'
            assert a.tobytes()!=originalPixels.tobytes(),kind+' has no effect'
            if kind=='dither':assert all(c in [0,255] for pixel in a.getdata() for c in pixel),'Dither quantization failed'
            param(id,'strength' if kind=='diffusion' else 'mix',0)
            assert snap(id).tobytes()==originalPixels.tobytes(),kind+' zero mix is not identity'
            param(id,'strength' if kind=='diffusion' else 'mix',1)
            # Exercise each enum choice and parameter extremes through Metal.
            specs=next(n['parameters'] for n in request('/v1/schema')['nodes'] if n['kind']==kind)
            for spec in specs:
                for v in [spec['min'],spec['max']]:param(id,spec['key'],v);snap(id)
                param(id,spec['key'],spec['initial'])
            assert state()['status'][id]=='Ready'
            cmd({'op':'remove','id':id})
            print('PASS',kind,'renders, stable pause, zero-mix identity, parameter bounds')
        glow=cmd({'op':'add','kind':'diffusion','parameters':{'radius':40,'strength':2}})['id']
        cmd({'op':'connect','source':source,'target':glow})
        black=root/'black.png';Image.new('RGB',(320,180)).save(black)
        cmd({'op':'update','id':source,'file':str(black)});time.sleep(.4)
        assert snap(glow).getbbox() is None,'Glow must preserve black'
        impulse=Image.new('RGB',(320,180));ImageDraw.Draw(impulse).rectangle((150,80,170,100),fill='white');impulse.save(root/'impulse.png')
        cmd({'op':'update','id':source,'file':str(root/'impulse.png')});time.sleep(.4)
        result=snap(glow);assert result.getpixel((140,90))[0]>2,'Glow did not spread beyond source'
        output=cmd({'op':'add','kind':'window','enabled':False})['id'];cmd({'op':'connect','source':glow,'target':output});time.sleep(.15)
        assert snap(output).tobytes()==snap(glow).tobytes(),'Disabled output must keep incoming video available'
        print('PASS glow black preservation, halo extent and disabled output preview texture')
        schema=request('/v1/schema');camera=next(n for n in schema['nodes'] if n['kind']=='webcam')
        assert any(p['key']=='mirror' and p['choices']==['Off','On'] for p in camera['parameters'])
        print('PASS camera Mirror control exposed in schema')
finally:
    cmd({'op':'replace','graph':original});cmd({'op':'play' if playing else 'pause'})

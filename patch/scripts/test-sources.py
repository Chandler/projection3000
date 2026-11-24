#!/usr/bin/env python3
"""Pixel and typed-source regressions on the isolated test app."""
import json, os, pathlib, urllib.request, urllib.error, tempfile, time, wave, math, struct
from PIL import Image, ImageDraw, ImageStat
port=int(os.environ.get('PATCH_API_PORT','9418'))
token=(pathlib.Path.home()/'Library/Application Support/Patch/api-token').read_text().strip()
def request(path,body=None):
    req=urllib.request.Request(f'http://127.0.0.1:{port}{path}',data=None if body is None else json.dumps(body).encode(),headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=10) as r:return json.load(r)
def cmd(body):return request('/v1/commands',body)
def ready(id):
    for _ in range(100):
        s=request('/v1/state')
        if s['status'].get(id)=='Ready':return
        time.sleep(.05)
    raise AssertionError(s['status'].get(id))
def snapshot(id,path):
    cmd({'op':'snapshot','id':id,'path':str(path)})
    return Image.open(path).convert('RGB')
original=request('/v1/state')['graph']
try:
    with tempfile.TemporaryDirectory(prefix='patch-sources-') as directory:
        root=pathlib.Path(directory)
        source=Image.new('RGB',(320,180));d=ImageDraw.Draw(source)
        d.rectangle((0,0,159,89),fill=(240,20,10));d.rectangle((160,0,319,89),fill=(10,230,30));d.rectangle((0,90,159,179),fill=(20,30,240));d.rectangle((160,90,319,179),fill=(240,240,240))
        for mode,ext in [('RGB','png'),('P','png'),('RGBA','png'),('CMYK','jpg')]:
            path=root/f'{mode}.{ext}';source.convert(mode).save(path)
            id=cmd({'op':'add','kind':'image','file':str(path)})['id'];ready(id)
            image=snapshot(id,root/'frame.png')
            for uv,channel in [((.25,.25),0),((.75,.25),1),((.25,.75),2)]:
                pixel=image.getpixel((int(image.width*uv[0]),int(image.height*uv[1])))
                assert pixel[channel]>100 and all(pixel[channel]>pixel[c]+45 for c in range(3) if c!=channel),(mode,uv,pixel)
            cmd({'op':'remove','id':id})
        path=root/'transforms.png';source.save(path)
        id=cmd({'op':'add','kind':'image','file':str(path)})['id'];ready(id)
        def transformed(parameters):
            cmd([{'op':'parameter','id':id,'key':k,'value':v} for k,v in parameters.items()]);time.sleep(.1)
            return snapshot(id,root/'transformed.png')
        image=transformed({'rotation':90});r,g,b=image.getpixel((700,180));assert r>180 and g<60 and b<60,'Clockwise rotation wrong'
        image=transformed({'rotation':0,'flipX':1});r,g,b=image.getpixel((960,180));assert r>180 and g<60 and b<60,'Horizontal flip wrong'
        image=transformed({'flipX':0,'flipY':1});r,g,b=image.getpixel((320,540));assert r>180 and g<60 and b<60,'Vertical flip wrong'
        image=transformed({'flipY':0,'scale':.5,'x':.5});assert image.getpixel((100,360))==(0,0,0),'Scale/position should expose black border'
        cmd({'op':'remove','id':id});print('PASS source transforms: clockwise rotation, both flips, scale and position')
        for mode in ['L','I;16']:
            path=root/f'{mode.replace(";","")}.png';Image.new(mode,(320,180),160 if mode=='L' else 40000).save(path)
            id=cmd({'op':'add','kind':'image','file':str(path)})['id'];ready(id)
            pixel=snapshot(id,root/'gray.png').getpixel((640,360));assert max(pixel)-min(pixel)<3 and max(pixel)>30,(mode,pixel)
            cmd({'op':'remove','id':id})
        print('PASS image color and orientation: RGB, indexed, RGBA, CMYK, grayscale and 16-bit')
        id=cmd({'op':'add','kind':'scene'})['id'];ready(id)
        a=snapshot(id,root/'scene1.png');time.sleep(.3);b=snapshot(id,root/'scene2.png')
        assert a.tobytes()!=b.tobytes(),'Scene is not animated'
        palette=a.resize((160,90)).getdata()
        assert sum(r>g*1.15 and r>b*1.1 for r,g,b in palette)>30,'Missing pink sphere'
        assert sum(g>r*1.15 and g>b*1.05 for r,g,b in palette)>20,'Missing mint sphere'
        assert sum(r>b*1.3 and g>b*1.15 for r,g,b in palette)>30,'Missing yellow box'
        cmd({'op':'pause'});time.sleep(.15);a=snapshot(id,root/'still1.png');time.sleep(.1);b=snapshot(id,root/'still2.png');assert a.tobytes()==b.tobytes()
        cmd({'op':'play'});cmd({'op':'remove','id':id})
        print('PASS analytic 3D scene: distinct object colors, animation, and pause')
        id=cmd({'op':'add','kind':'text','text':'Hello\nPatch','parameters':{'size':96}})['id'];ready(id)
        a=snapshot(id,root/'text.png');assert ImageStat.Stat(a).mean[0]>1
        cmd({'op':'update','id':id,'text':'X'});time.sleep(.3);ready(id)
        b=snapshot(id,root/'text2.png');assert a.tobytes()!=b.tobytes()
        cmd({'op':'remove','id':id})
        print('PASS multiline text rendering and content updates')
        path=root/'audio.wav'
        with wave.open(str(path),'wb') as w:
            w.setnchannels(1);w.setsampwidth(2);w.setframerate(48000)
            w.writeframes(b''.join(struct.pack('<h',int(20000*math.sin(i*2*math.pi*137/48000)*(0.5+0.5*math.sin(i/4800)))) for i in range(96000)))
        audio=cmd({'op':'add','kind':'audio','file':str(path)})['id'];ready(audio)
        scope=cmd({'op':'add','kind':'waveform'})['id'];cmd({'op':'connect','source':audio,'target':scope});ready(scope)
        a=snapshot(scope,root/'scope.png');time.sleep(.11);b=snapshot(scope,root/'scope2.png')
        assert a.tobytes()!=b.tobytes(),'Waveform does not animate'
        cmd({'op':'pause'});time.sleep(.1);a=snapshot(scope,root/'paused1.png');time.sleep(.1);b=snapshot(scope,root/'paused2.png');assert a.tobytes()==b.tobytes()
        cmd({'op':'play'})
        crt=cmd({'op':'add','kind':'crt'})['id']
        try:cmd({'op':'connect','source':audio,'target':crt});raise AssertionError('Audio accepted as video')
        except urllib.error.HTTPError as e:assert e.code==400
        cmd({'op':'connect','source':scope,'target':crt})
        print('PASS typed audio → waveform → CRT, animated PCM rendering and pause')
finally:
    cmd({'op':'replace','graph':original});cmd({'op':'play'})

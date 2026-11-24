#!/usr/bin/env python3
"""Real Vision + Metal integration checks; uses NASA's public-domain astronaut photo."""
import json, os, pathlib, tempfile, time, urllib.request
from PIL import Image
port = int(os.environ.get('PATCH_API_PORT', '9418'))
token = (pathlib.Path.home()/'Library/Application Support/Patch/api-token').read_text().strip()
def request(path, body=None):
    req = urllib.request.Request(f'http://127.0.0.1:{port}{path}', data=None if body is None else json.dumps(body).encode(), headers={'Authorization':'Bearer '+token, 'Content-Type':'application/json'})
    with urllib.request.urlopen(req, timeout=15) as r: return json.load(r)
def cmd(body): return request('/v1/commands', body)
def state(): return request('/v1/state')
def wait_for(predicate, description):
    deadline = time.monotonic()+20
    while time.monotonic() < deadline:
        s = state()
        if predicate(s): return s
        time.sleep(.08)
    raise AssertionError(description+'; status='+str(state()['status']))
fixture = pathlib.Path('.build/face-fixture.png').resolve()
if not fixture.exists():
    urllib.request.urlretrieve('https://raw.githubusercontent.com/scikit-image/scikit-image/v0.19.3/skimage/data/astronaut.png', fixture)
original = state()['graph']; playing = state()['playing']
try:
    cmd({'op':'replace','graph':{'version':1,'nodes':[],'edges':[],'width':640,'height':360,'fps':60}})
    source = cmd({'op':'add','kind':'image','file':str(fixture)})['id']
    detector = cmd({'op':'add','kind':'faceDetect'})['id']
    boxes = cmd({'op':'add','kind':'faceBoxes'})['id']
    cmd([{'op':'connect','source':source,'target':detector}, {'op':'connect','source':source,'target':boxes}, {'op':'connect','source':detector,'target':boxes,'input':1}])
    def detected(s): return bool(s['faceDetections'].get(detector,{}).get('faces'))
    s = wait_for(detected, 'No face detected in astronaut fixture')
    f = s['faceDetections'][detector]; face = f['faces'][0]; b = face['bounds']
    assert f['width']==640 and f['height']==360
    # Fixture face is in the upper middle; verifies top-left origin and letterboxing.
    assert .35 < b['x'] < .55 and .05 < b['y'] < .25, b
    assert .07 < b['width'] < .2 and .15 < b['height'] < .35, b
    assert len(face['landmarks']['leftEye']) > 2
    assert all(0<=p['x']<=1 and 0<=p['y']<=1 for region in face['landmarks'].values() for p in region)
    seq = f['sequence']; frames = s['frames']
    wait_for(lambda s:s['faceDetections'].get(detector,{}).get('sequence',0)>seq+2 and s['frames']>frames+5, 'Detection or renderer stalled')
    with tempfile.TemporaryDirectory(prefix='patch-faces-') as tmp:
        output = pathlib.Path(tmp)/'boxes.png'
        cmd({'op':'snapshot','id':boxes,'path':str(output)})
        im = Image.open(output).convert('RGB')
        im.save('.build/face-boxes-check.png')
        # Metal outline should coincide with the reported top edge (within rounding).
        x = int((b['x']+b['width']/2)*640); y = int(b['y']*360)
        assert any(im.getpixel((x,y+dy))[1]>240 and im.getpixel((x,y+dy))[0]<70 for dy in range(5)), (b, im.getpixel((x,y)))
        # Mirroring must move coordinates with the rendered source, not the raw image.
        cmd({'op':'parameter','id':source,'key':'flipX','value':1})
        s = wait_for(lambda s:detected(s) and abs(s['faceDetections'][detector]['faces'][0]['bounds']['x']-(1-b['x']-b['width'])) < .04,'Mirrored face not detected'); flipped = s['faceDetections'][detector]['faces'][0]['bounds']
        assert abs(flipped['x']-(1-b['x']-b['width'])) < .04, (b,flipped)
        cmd({'op':'update','id':detector,'enabled':False})
        wait_for(lambda s:detector not in s['faceDetections'],'Disabled detector retained coordinates')
        cmd({'op':'update','id':detector,'enabled':True});wait_for(detected,'Re-enabled detector did not recover')
        cmd({'op':'disconnect','target':detector})
        wait_for(lambda s:detector not in s['faceDetections'] and s['status'].get(detector)=='No input','Disconnected detector retained coordinates')
        cmd({'op':'connect','source':source,'target':detector});wait_for(detected,'Reconnect failed')
        blank = pathlib.Path(tmp)/'blank.png';Image.new('RGB',(512,512),'black').save(blank)
        cmd({'op':'update','id':source,'file':str(blank)})
        wait_for(lambda s:detector in s['faceDetections'] and not s['faceDetections'][detector]['faces'], 'No-face frame did not clear coordinates')
        cmd({'op':'snapshot','id':boxes,'path':str(output)})
        assert Image.open(output).convert('RGB').getbbox() is None,'Stale boxes remain on blank frame'
    print('PASS real Vision landmarks, normalized/letterboxed coordinates, live updates, GPU boxes, mirror, disable, disconnect, no-face clearing')
finally:
    cmd({'op':'replace','graph':original});cmd({'op':'play' if playing else 'pause'})

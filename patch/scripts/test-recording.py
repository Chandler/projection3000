#!/usr/bin/env python3
"""Exercise recording against the isolated app and decode the actual movie."""
import json,os,pathlib,urllib.request,urllib.error,time,tempfile,subprocess
port=int(os.environ.get('PATCH_API_PORT','9418'));token=(pathlib.Path.home()/'Library/Application Support/Patch/api-token').read_text().strip()
def request(path,body=None):
    req=urllib.request.Request(f'http://127.0.0.1:{port}'+path,data=None if body is None else json.dumps(body).encode(),headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=15) as r:return json.load(r)
def cmd(body):return request('/v1/commands',body)
def state():return request('/v1/state')
def ready(id):
    for _ in range(200):
        info=state()['recordings'].get(id,{})
        if info.get('state') in ['ready','failed']:assert info['state']=='ready',info;return info
        time.sleep(.05)
    raise AssertionError(info)
def reject(body):
    try:cmd(body);raise AssertionError('Expected rejection')
    except urllib.error.HTTPError as e:assert e.code==400
original=state()['graph'];takes=[]
try:
    source=cmd({'op':'add','kind':'pattern','parameters':{'speed':2}})['id']
    record=cmd({'op':'add','kind':'record'})['id']
    reject({'op':'record_start','id':record})
    cmd({'op':'connect','source':source,'target':record});time.sleep(.1)
    cmd({'op':'record_start','id':record});reject({'op':'record_start','id':record})
    before=state()['frames'];time.sleep(2.2);assert state()['frames']-before>75,'Graph stalled during recording'
    cmd({'op':'record_stop','id':record});info=ready(record);takes.append(info['path'])
    assert info['frames']>45 and info['seconds']>1.5,info
    with tempfile.TemporaryDirectory(prefix='patch-recording-') as directory:
        movie=pathlib.Path(directory)/'take.mov'
        cmd({'op':'record_save','id':record,'path':str(movie)})
        assert movie.stat().st_size>10000
        reject({'op':'record_save','id':record,'path':str(movie)})
        cmd({'op':'record_save','id':record,'path':str(movie),'replace':True})
        metadata=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(movie)]))
        stream=metadata['streams'][0];assert stream['codec_name']=='h264' and stream['width']==original['width'] and stream['height']==original['height'],stream
        assert float(metadata['format']['duration'])>1.5
        def frame(t):return subprocess.check_output(['ffmpeg','-v','error','-ss',str(t),'-i',str(movie),'-frames:v','1','-vf','scale=64:36','-f','rawvideo','-pix_fmt','rgb24','-'])
        a,b=frame(.1),frame(1.5);assert a and b and a!=b and max(a)>100
    print(f"PASS movie recording: {info['frames']} frames, {info['seconds']:.2f}s, {info['droppedFrames']} dropped; decoded H.264, animation, save and overwrite protection")
    # Disabling the sink finalizes its take, retaining it for later saving.
    cmd({'op':'record_start','id':record});time.sleep(.4)
    cmd({'op':'update','id':record,'enabled':False});info=ready(record);takes.append(info['path']);assert info['frames']>0
    cmd({'op':'update','id':record,'enabled':True});time.sleep(.1)
    cmd({'op':'record_start','id':record});time.sleep(.4)
    graph=state()['graph'];graph['width']=960;graph['height']=540
    cmd({'op':'replace','graph':graph});info=ready(record);takes.append(info['path']);assert info['frames']>0
    print('PASS automatic movie finalization on disabled node and resolution change')
finally:
    cmd({'op':'replace','graph':original})
    for path in takes:pathlib.Path(path).unlink(missing_ok=True)

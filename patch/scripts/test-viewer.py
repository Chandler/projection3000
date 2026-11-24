#!/usr/bin/env python3
"""Verify actual WindowServer presentation, not merely GPU graph completion.

Opens the first window output in the current patch, and watches it for > one
rotation of the default Lorenz example. Run with the window visible.
"""
import json, pathlib, urllib.request, time, argparse
parser=argparse.ArgumentParser();parser.add_argument('--port',type=int,default=9417);parser.add_argument('--seconds',type=int,default=40);args=parser.parse_args()
token=(pathlib.Path.home()/'Library/Application Support/Patch/api-token').read_text().strip()
def request(path,body=None):
    req=urllib.request.Request(f'http://127.0.0.1:{args.port}{path}',headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'},data=None if body is None else json.dumps(body).encode())
    with urllib.request.urlopen(req,timeout=5) as r:return json.load(r)
state=request('/v1/state'); node=next(n for n in state['graph']['nodes'] if n['kind']=='window')
request('/v1/commands',{'op':'view','id':node['id']})
def viewer():
    state=request('/v1/state')
    v=next(v for v in state['viewers'] if v['node']==node['id'] and v['window']=='Patch · '+node['name'])
    return v,state['frames']
time.sleep(.5)
first,rendered=viewer();previous=first;start=time.monotonic();visible_seconds=0;seen=0
while time.monotonic()-start<max(90,args.seconds*3):
    time.sleep(2)
    current,frames=viewer()
    if current['visible'] and previous['visible']:
        assert current['presentedFrames']>previous['presentedFrames'],('Visible window stopped presenting',current)
        assert current['lastPresentedTime']>previous['lastPresentedTime'],('Visible presentation timestamp stuck',current)
        visible_seconds+=2
        seen+=current['presentedFrames']-previous['presentedFrames']
    previous=current
    if visible_seconds>=args.seconds:break
assert visible_seconds>=args.seconds,f'Only {visible_seconds}s visible; keep the output window uncovered for this check'
print(f"PASS visible output: {seen} presented frames over {visible_seconds}s of visible playback; renderer advanced {frames-rendered} frames")

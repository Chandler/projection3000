"""Manual Mac integration smoke; uses temporary state and no hardware outputs."""
import argparse,json,subprocess,tempfile,urllib.request,struct,zlib,signal
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--build',type=Path,default=Path(__file__).resolve().parents[1]/'build/mac')
build=parser.parse_args().build.resolve()
def png(path):
 def chunk(kind,data): return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
 path.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',8,8,8,2,0,0,0))+chunk(b'IDAT',zlib.compress((b'\x00'+bytes((24,139,212))*8)*8))+chunk(b'IEND',b''))
with tempfile.TemporaryDirectory(prefix='vj-native-integrated-') as temporary:
 root=Path(temporary);state=root/'state';source=root/'fixture.png';png(source)
 p=subprocess.Popen([str(build/'vj-render-service'),'--state-root',str(state),'--port','0','--width','320','--height','180'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 try:
  ready=json.loads(p.stdout.readline());base='http://127.0.0.1:'+str(ready['port'])
  def request(method,path,body=None):
   q=urllib.request.Request(base+path,data=None if body is None else json.dumps(body).encode(),headers={'Content-Type':'application/json'},method=method)
   with urllib.request.urlopen(q,timeout=15) as response:return json.load(response)
  media=request('POST','/api/v1/media/import',{'path':str(source)})['item']
  request('POST','/api/v1/grid',{'action':'put_clip','row':'row_0','column':'column_0','effect':'image','params':{'file':media['file'],'fit':'stretch'}})
  request('POST','/api/v1/mix',{'video_master':.5})
 finally:
  p.send_signal(signal.SIGTERM);out,err=p.communicate(timeout=15)
  if p.returncode:raise RuntimeError(err)
 check=subprocess.run([str(build/'vj-render-service'),'--state-root',str(state),'--check-render','--width','320','--height','180'],capture_output=True,text=True,timeout=30,check=True)
 result=json.loads(check.stdout);pixel=result['readback'][0]['firstPixel'];assert all(abs(a-b)<=2 for a,b in zip(pixel,(12,70,106))),pixel
 print('PASS imported image + GPU master mix:',pixel)
 # Native text activation generates a cached RGBA asset through the shared API.
 p=subprocess.Popen([str(build/'vj-render-service'),'--state-root',str(state),'--port','0','--width','320','--height','180'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 try:
  ready=json.loads(p.stdout.readline());base='http://127.0.0.1:'+str(ready['port'])
  fonts=request('GET','/api/v1/text/fonts');assert fonts['available'] and len(fonts['fonts'])==10,fonts
  request('POST','/api/v1/mix',{'video_master':1.})
  request('POST','/api/v1/grid',{'action':'put_clip','row':'row_0','column':'column_0','effect':'text','params':{'content':'NATIVE\nVJ','color':'#ffffff'}})
  text=request('GET','/api/v1/state')['state']['grid']['rows'][0]['clips']['column_0'];assert text['textStatus']['available'] and Path(text['resolved_file']).is_file(),text
  m=request('GET','/api/v1/mappings/1');m=request('POST','/api/v1/mappings/1/collections',{'revision':m['revision'],'kind':'planar','rectIds':['rect-1']})
  request('POST','/api/v1/grid',{'action':'put_clip','row':'row_0','column':'column_0','effect':'glow_faces','params':{}})
  snapshot=request('GET','/api/v1/state');mapping=snapshot['mappings']['1'];assert mapping['collectionContexts'] and mapping['project']['renderRects'][0]['nativeBus'],mapping
  # A failed cross-owner batch cannot leave its successful first operation applied.
  revision=mapping['revision'];cid=mapping['project']['collections'][0]['id']
  try:request('POST','/api/v1/mappings/1/batch',{'revision':revision,'operations':[{'method':'PATCH','action':'collections/'+cid,'body':{'name':'Wrong'}},{'method':'PATCH','action':'rects','body':{'rectIds':['rect-1'],'cornerRadius':2}}]})
  except urllib.error.HTTPError as error:assert error.code==400
  else:raise AssertionError('invalid batch accepted')
  after=request('GET','/api/v1/mappings/1');assert after['revision']==revision and after['project']['collections'][0]['name']!='Wrong'
  request('POST','/api/v1/mappings/1/batch',{'revision':revision,'operations':[{'method':'PATCH','action':'collections/'+cid,'body':{'name':'Cards'}},{'method':'PATCH','action':'rects','body':{'rectIds':['rect-1'],'cornerRadius':.05}}]})
  print('PASS native text cache, collection render contexts, atomic bulk edits')
 finally:
  p.send_signal(signal.SIGTERM);out,err=p.communicate(timeout=15)
  if p.returncode:raise RuntimeError(err)
 ui=subprocess.run([str(build/'VJ.app/Contents/MacOS/VJ'),'--state-root',str(state),'--port','0','--check-ui'],capture_output=True,text=True,timeout=30,check=True)
 print(ui.stdout+ui.stderr)

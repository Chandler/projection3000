#!/usr/bin/env python3
"""Create small self-contained patches without changing the open project."""
import json, math, pathlib, struct, uuid, wave
root=pathlib.Path(__file__).resolve().parents[1]/'.build/examples'
root.mkdir(parents=True,exist_ok=True)
audio=root/'pulse.wav'
with wave.open(str(audio),'wb') as file:
    file.setnchannels(1);file.setsampwidth(2);file.setframerate(48000)
    file.writeframes(b''.join(struct.pack('<h',int(24000*math.sin(2*math.pi*110*i/48000)*math.exp(-5*((i/48000)%0.5)))) for i in range(48000*4)))
def write(name,kinds,settings):
    nodes=[dict(id=str(uuid.uuid4()).upper(),kind=kind,name=title,enabled=True,position=dict(x=70+i*280,y=150),parameters={},**settings.get(kind,{})) for i,(kind,title) in enumerate(kinds)]
    edges=[dict(id=str(uuid.uuid4()).upper(),source=a['id'],target=b['id'],input=0) for a,b in zip(nodes,nodes[1:])]
    path=root/(name+'.patch.json');path.write_text(json.dumps(dict(version=1,width=1280,height=720,fps=60,nodes=nodes,edges=edges),indent=2));print(path)
write('Audio Waveform',[('audio','Pulse'),('waveform','Waveform'),('crt','CRT'),('window','Audio Window')],{'audio':{'file':str(audio)}})
write('Text',[('text','Text'),('crt','CRT'),('window','Text Window')],{'text':{'text':'PATCH\n01'}})
write('Camera',[('webcam','Camera'),('crt','CRT'),('window','Camera Window')],{})

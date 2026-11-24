#!/usr/bin/env python3
"""Create small self-contained patches without changing the open project."""
import json, math, pathlib, struct, uuid, wave
root=pathlib.Path(__file__).resolve().parents[1]/'.build/examples'
root.mkdir(parents=True,exist_ok=True)
audio=root/'pulse.wav'
with wave.open(str(audio),'wb') as file:
    file.setnchannels(1);file.setsampwidth(2);file.setframerate(48000)
    file.writeframes(b''.join(struct.pack('<h',int(24000*math.sin(2*math.pi*110*i/48000)*math.exp(-5*((i/48000)%0.5)))) for i in range(48000*4)))

def write(name, nodes, connections):
    records = [
        dict(id=str(uuid.uuid4()).upper(), kind=kind, name=title, enabled=True,
             position=dict(x=70+i*280, y=150), parameters={}, **settings)
        for i, (kind, title, settings) in enumerate(nodes)
    ]
    edges = [
        dict(id=str(uuid.uuid4()).upper(), source=records[source]['id'], outputID=output_id,
             target=records[target]['id'], inputID=input_id)
        for source, output_id, target, input_id in connections
    ]
    path = root / (name+'.patch.json')
    path.write_text(json.dumps(dict(version=2, width=1280, height=720, fps=60,
                                    nodes=records, edges=edges), indent=2))
    print(path)


write('Audio Waveform', [
    ('audio', 'Pulse', {'file': str(audio)}), ('waveform', 'Waveform', {}),
    ('crt', 'CRT', {}), ('window', 'Audio Window', {})
], [(0, 'Stereo / XY', 1, 'Audio'), (1, 'Video', 2, 'Video'), (2, 'Video', 3, 'Video')])
write('Text', [
    ('text', 'Text', {'text': 'PATCH\n01'}), ('crt', 'CRT', {}), ('window', 'Text Window', {})
], [(0, 'Video', 1, 'Video'), (1, 'Video', 2, 'Video')])
write('Camera', [
    ('webcam', 'Camera', {}), ('crt', 'CRT', {}), ('window', 'Camera Window', {})
], [(0, 'Video', 1, 'Video'), (1, 'Video', 2, 'Video')])

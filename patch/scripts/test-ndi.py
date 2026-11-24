#!/usr/bin/env python3
"""Independent NDI receive probe; validates frames from the integration sender."""
import ctypes as c, os, pathlib, time
class Source(c.Structure):_fields_=[('name',c.c_char_p),('url',c.c_char_p)]
class Find(c.Structure):_fields_=[('local',c.c_bool),('groups',c.c_char_p),('extra',c.c_char_p)]
class Receive(c.Structure):_fields_=[('source',Source),('format',c.c_int),('bandwidth',c.c_int),('fields',c.c_bool),('name',c.c_char_p)]
class Frame(c.Structure):_fields_=[('width',c.c_int),('height',c.c_int),('fourcc',c.c_uint32),('fpsN',c.c_int),('fpsD',c.c_int),('aspect',c.c_float),('format',c.c_int),('timecode',c.c_int64),('data',c.POINTER(c.c_uint8)),('stride',c.c_int),('metadata',c.c_char_p),('timestamp',c.c_int64)]
paths=[pathlib.Path(os.environ.get('NDI_RUNTIME_DIR_V6','/usr/local/lib'))/'libndi.dylib',pathlib.Path('/Applications/TouchDesigner.app/Contents/Frameworks/libndi.dylib')]
lib=c.CDLL(str(next(p for p in paths if p.exists())))
def bind(name,args,result):
    f=getattr(lib,name); f.argtypes=args; f.restype=result; return f
initialize=bind('NDIlib_initialize',[],c.c_bool)
find=bind('NDIlib_find_create_v2',[c.POINTER(Find)],c.c_void_p)
get=bind('NDIlib_find_get_current_sources',[c.c_void_p,c.POINTER(c.c_uint32)],c.POINTER(Source))
create=bind('NDIlib_recv_create_v3',[c.POINTER(Receive)],c.c_void_p)
capture=bind('NDIlib_recv_capture_v3',[c.c_void_p,c.POINTER(Frame),c.c_void_p,c.c_void_p,c.c_uint32],c.c_int)
free=bind('NDIlib_recv_free_video_v2',[c.c_void_p,c.POINTER(Frame)],None)
destroy=bind('NDIlib_recv_destroy',[c.c_void_p],None)
destroy_find=bind('NDIlib_find_destroy',[c.c_void_p],None)
assert initialize()
finder=find(c.byref(Find(True,None,None))); assert finder
receiver=None
try:
    deadline=time.monotonic()+15
    while time.monotonic()<deadline:
        count=c.c_uint32(); sources=get(finder,c.byref(count))
        matching=next((sources[i] for i in range(count.value) if b'Patch Integration Ndi' in (sources[i].name or b'')),None)
        if matching:
            receiver=create(c.byref(Receive(matching,0,100,False,b'Patch validation')));break
        time.sleep(.2)
    assert receiver,'NDI source not discovered'
    frames=0
    while time.monotonic()<deadline:
        frame=Frame(); kind=capture(receiver,c.byref(frame),None,None,1000)
        if kind==1:
            try:
                assert frame.width>=64 and frame.height>=64
                raw=c.string_at(frame.data,frame.stride*frame.height)
                assert sum(raw[0:frame.width*4:4])>1000,'Received black frame'
                frames+=1
                if frames==5:
                    print(f'PASS NDI receiver: {frame.width} x {frame.height}, {frame.fpsN}/{frame.fpsD} FPS, 5 nonblack frames'); break
            finally:free(receiver,c.byref(frame))
    assert frames>=5,'No continuous NDI frames'
finally:
    if receiver:destroy(receiver)
    destroy_find(finder)

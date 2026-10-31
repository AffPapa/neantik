#!/usr/bin/env python3
"""Own fragmented MP4 streams; no downloads or user media."""
import hashlib,json,os,struct,subprocess,sys
from pathlib import Path

def split_mp4(raw):
    boxes=[];offset=0
    while offset<len(raw):
        if offset+8>len(raw):raise ValueError('truncated box')
        size,kind=struct.unpack_from('>I4s',raw,offset)
        if size<8 or offset+size>len(raw):raise ValueError('invalid bounded box')
        boxes.append((kind,raw[offset:offset+size]));offset+=size
    init=bytearray();segments=[];pending=None
    for kind,data in boxes:
        if kind==b'moof':
            if pending is not None:raise ValueError('missing mdat')
            pending=data
        elif kind==b'mdat':
            if pending is None:raise ValueError('mdat without moof')
            segments.append(pending+data);pending=None
        elif not segments and pending is None and kind in [b'ftyp',b'moov']:init.extend(data)
        elif kind!=b'mfra':raise ValueError('unexpected fragment box')
    if pending is not None or len(segments)<2 or b'moov' not in init:raise ValueError('incomplete stream')
    return bytes(init),segments

def create(output):
    output.mkdir(mode=0o700,exist_ok=False);ffmpeg='/opt/homebrew/bin/ffmpeg';cases=[]
    for role,source,encoder,mime in [('video','color=c=red:s=64x48:r=20:d=2','libx264','video/mp4; codecs="avc1.42C00A"'),('audio','sine=frequency=440:sample_rate=48000:duration=2','aac','audio/mp4; codecs="mp4a.40.2"')]:
        file=output/(role+'.mp4');args=[ffmpeg,'-nostdin','-v','error','-f','lavfi','-i',source,'-threads','2','-filter_threads','1']
        args+=['-an','-c:v',encoder,'-profile:v','baseline','-level:v','1.0','-pix_fmt','yuv420p','-g','10'] if role=='video' else ['-vn','-c:a',encoder,'-ac','1']
        args+=['-movflags','+empty_moov+default_base_moof+frag_keyframe','-frag_duration','500000',str(file)]
        p=subprocess.run(args,capture_output=True,timeout=30,env={'PATH':os.defpath})
        if p.returncode:raise ValueError('own media encoder failed:'+role)
        init,parts=split_mp4(file.read_bytes());names=[role+'-init.mp4']+[role+'-'+str(i)+'.m4s' for i in range(len(parts))]
        for name,raw in zip(names,[init,*parts]):(output/name).write_bytes(raw)
        cases.append({'id':role,'kind':role,'mime':mime,'files':names})
    files={}
    for p in sorted(output.iterdir()):
        p.chmod(0o600);raw=p.read_bytes();assert len(raw)<1048576;files[p.name]={'size':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
    manifest={'schemaVersion':1,'kind':'own-fragmented-mp4','cases':cases,'files':files,'ffmpegSHA256':hashlib.sha256(Path(ffmpeg).read_bytes()).hexdigest()};(output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');(output/'manifest.json').chmod(0o600);return manifest
if __name__=='__main__':
    m=create(Path(sys.argv[1]));print(json.dumps({'files':len(m['files']),'actualBrowser':False}))

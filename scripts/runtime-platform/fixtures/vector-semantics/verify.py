import sys
"""Independent PNG and numeric verification of synthetic browser observations.
PNG is decoded outside the browser: no second canvas read can add noise.
"""
import argparse, base64, binascii, copy, hashlib, json, math, struct, zlib
from pathlib import Path

MAX_PNG=1024*1024

def raw64(s, limit=MAX_PNG):
    if not isinstance(s,str) or len(s)>limit*2: raise ValueError('base64 limit')
    b=base64.b64decode(s,validate=True)
    if len(b)>limit: raise ValueError('decoded limit')
    return b

def png_rgba(encoded):
    data=raw64(encoded)
    if data[:8]!=b'\x89PNG\r\n\x1a\n': raise ValueError('PNG signature')
    pos=8; header=None; payload=bytearray(); ended=False; idat=False; closed=False
    while pos<len(data):
        if pos+12>len(data): raise ValueError('PNG truncated chunk')
        length=struct.unpack_from('>I',data,pos)[0]; tag=data[pos+4:pos+8]
        if length>MAX_PNG or pos+12+length>len(data): raise ValueError('PNG chunk limit')
        body=data[pos+8:pos+8+length]; crc=struct.unpack_from('>I',data,pos+8+length)[0]
        if binascii.crc32(tag+body)&0xffffffff!=crc: raise ValueError('PNG CRC')
        if header is None and tag!=b'IHDR': raise ValueError('PNG header order')
        if tag==b'IHDR':
            if header is not None or length!=13: raise ValueError('PNG header')
            header=struct.unpack('>IIBBBBB',body); w,h,depth,color,comp,filt,interlace=header
            if not (1<=w<=256 and 1<=h<=256 and depth==8 and color in (2,6) and comp==filt==interlace==0):
                raise ValueError('PNG unsupported header')
        elif tag==b'IDAT':
            if closed: raise ValueError('PNG noncontiguous IDAT')
            payload.extend(body); idat=True
        elif tag==b'IEND':
            if length or not idat: raise ValueError('PNG end')
            ended=True; pos+=12; break
        else:
            if idat: closed=True
            if tag[0]&32==0: raise ValueError('PNG unsupported critical chunk')
        pos+=12+length
    if not ended or pos!=len(data): raise ValueError('PNG missing end or trailing data')
    stride=w*(4 if color==6 else 3); expected=h*(stride+1)
    dec=zlib.decompressobj(); rows=dec.decompress(bytes(payload),expected+1)
    if len(rows)!=expected or not dec.eof or dec.unused_data or dec.unconsumed_tail: raise ValueError('PNG inflate boundary')
    previous=bytearray(stride); result=bytearray(); bpp=4 if color==6 else 3
    def paeth(a,b,c):
        p=a+b-c; choices=[(abs(p-a),a),(abs(p-b),b),(abs(p-c),c)]
        return min(enumerate(choices),key=lambda x:(x[1][0],x[0]))[1][1]
    for y in range(h):
        f=rows[y*(stride+1)]; row=bytearray(rows[y*(stride+1)+1:(y+1)*(stride+1)])
        if f>4: raise ValueError('PNG filter')
        for x in range(stride):
            a=row[x-bpp] if x>=bpp else 0; b=previous[x]; c=previous[x-bpp] if x>=bpp else 0
            predictor=(0,a,b,(a+b)//2,paeth(a,b,c))[f]; row[x]=(row[x]+predictor)&255
        if color==6: result.extend(row)
        else:
            for x in range(0,stride,3): result.extend(row[x:x+3]+b'\xff')
        previous=row
    return w,h,bytes(result)

def pixels(kind,w=32,h=24):
    out=bytearray()
    for y in range(h):
        for x in range(w):
            p={'solid':(36,104,172,255),'clear':(0,0,0,0),'black-alpha':(0,0,0,128)}.get(kind)
            if p is None: p=((x*7+y*3)%256,(y*11+x)%256,(x*13+y*17)%256,255)
            out.extend(p)
    return bytes(out)

def region(full,x0,y0,w,h):
    out=bytearray()
    for y in range(y0,y0+h):
        for x in range(x0,x0+w):
            out.extend(full[(y*32+x)*4:(y*32+x)*4+4] if 0<=x<32 and 0<=y<24 else b'\0'*4)
    return bytes(out)

def verify(observation):
    issues=[]; checks=0
    def check(ok,label):
        nonlocal checks
        checks+=1
        if not ok: issues.append(label)
    check(observation.get('headed') is True,'headed mode')
    check(observation.get('cleanupVerified') is True,'process cleanup')
    d=observation['data']; check(not d.get('errors'),'probe API errors')
    cs=d.get('canvas',[]); check(len(cs)==4 and {c.get('kind') for c in cs}=={'solid','clear','black-alpha','grid'},'canvas case coverage')
    for c in cs:
        kind=c.get('kind'); prefix='canvas:'+str(kind)+':'
        try:
            check(c['width']==32 and c['height']==24,prefix+'dimensions')
            full=raw64(c['full']); check(len(full)==32*24*4,prefix+'byte length')
            check(full==pixels(kind),prefix+'drawing/putImageData semantics')
            check(raw64(c['repeat'])==full,prefix+'repeat reading')
            check(raw64(c['after'])==full,prefix+'encoding does not mutate pixels')
            check(raw64(c['crop'])==region(full,5,3,16,12),prefix+'absolute crop coordinates')
            check(raw64(c['oob'])==region(full,-2,-2,36,28),prefix+'out of bounds transparency and coordinates')
            for field in ('png','pngBlob'):
                w,h,b=png_rgba(c[field]); check(w==32 and h==24 and b==full,prefix+field+' agrees with raw pixels')
            check(raw64(c['reset'])==pixels('solid'),prefix+'resize resets drawing state')
        except (ValueError,KeyError,TypeError,struct.error) as e: issues.append(prefix+'incomplete:'+type(e).__name__)
    ac=d.get('audio',[]); check(len(ac)==6 and {a.get('offset') for a in ac}=={None,0,.5,-.5,2,-2},'audio case coverage')
    for a in ac:
        offset=a.get('offset'); prefix='audio:'+str(offset)+':'
        try:
            n=4096 if offset is None else 1024; channels=2 if offset is None else 1; expected=0 if offset is None else offset
            for name in ('first','repeat'):
                b=a[name]; check((b['channels'],b['length'],b['sampleRate'])==(channels,n,44100),prefix+name+' metadata')
                check(len(b['buffers'])==channels,prefix+name+' channels')
                for i,s in enumerate(b['buffers']):
                    raw=raw64(s); check(len(raw)==n*4,prefix+name+' sample byte length')
                    samples=struct.unpack('<'+'f'*n,raw)
                    check(all(math.isfinite(v) and v==expected for v in samples),prefix+name+':channel'+str(i)+' silence/DC linear semantics')
            check(a['first']==a['repeat'],prefix+'repeat rendering')
        except (ValueError,KeyError,TypeError,struct.error) as e: issues.append(prefix+'incomplete:'+type(e).__name__)
    return {'checks':checks,'issues':issues,'passed':not issues}

def b64(b): return base64.b64encode(b).decode()
def encode_png(w,h,rgba,filter_kind=0,color=6):
    def chunk(tag,b): return struct.pack('>I',len(b))+tag+b+struct.pack('>I',binascii.crc32(tag+b)&0xffffffff)
    bpp=4 if color==6 else 3; stride=w*bpp
    pixels_data=rgba if color==6 else b''.join(rgba[i:i+3] for i in range(0,len(rgba),4))
    rows=bytearray(); previous=bytes(stride)
    for y in range(h):
        row=pixels_data[y*stride:(y+1)*stride]; encoded=bytearray()
        for x,v in enumerate(row):
            a=row[x-bpp] if x>=bpp else 0; b=previous[x]; c=previous[x-bpp] if x>=bpp else 0
            pred=a+b-c; distances=[abs(pred-a),abs(pred-b),abs(pred-c)]; paeth=(a,b,c)[distances.index(min(distances))]
            predictor=(0,a,b,(a+b)//2,paeth)[filter_kind]; encoded.append((v-predictor)&255)
        rows.append(filter_kind); rows.extend(encoded); previous=row
    return b64(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,color,0,0,0))+chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b''))

def self_test():
    fixture={'headed':True,'cleanupVerified':True,'data':{'errors':[],'canvas':[],'audio':[]}}
    for kind in ('solid','clear','black-alpha','grid'):
        full=pixels(kind); fixture['data']['canvas'].append(dict(kind=kind,width=32,height=24,full=b64(full),repeat=b64(full),after=b64(full),crop=b64(region(full,5,3,16,12)),oob=b64(region(full,-2,-2,36,28)),png=encode_png(32,24,full),pngBlob=encode_png(32,24,full),reset=b64(pixels('solid'))))
    for offset in (None,0,.5,-.5,2,-2):
        n=4096 if offset is None else 1024; count=2 if offset is None else 1
        item=dict(channels=count,length=n,sampleRate=44100,buffers=[b64(struct.pack('<f',0 if offset is None else offset)*n)]*count)
        fixture['data']['audio'].append(dict(offset=offset,first=item,repeat=copy.deepcopy(item)))
    assert verify(fixture)['passed']
    for color in (2,6):
        for f in range(5):
            assert png_rgba(encode_png(32,24,pixels('grid'),f,color))==(32,24,pixels('grid'))
    mutants=[]
    a=copy.deepcopy(fixture); b=bytearray(raw64(a['data']['canvas'][0]['full'])); b[-4]^=1; a['data']['canvas'][0]['full']=b64(b); mutants.append(a)
    a=copy.deepcopy(fixture); a['data']['canvas'][3]['crop']=b64(region(pixels('grid'),0,0,16,12)); mutants.append(a)
    a=copy.deepcopy(fixture); a['data']['audio'][0]['first']['buffers'][0]=b64(struct.pack('<f',1e-7)+b'\0'*(4096*4-4)); mutants.append(a)
    a=copy.deepcopy(fixture); a['data']['audio'][4]['first']['buffers'][0]=b64(struct.pack('<f',1)*1024); mutants.append(a)
    a=copy.deepcopy(fixture); a['data']['errors']=[{'vector':'canvas','error':'TimeoutError'}]; mutants.append(a)
    a=copy.deepcopy(fixture); a['data']['audio']=[]; mutants.append(a)
    assert all(not verify(a)['passed'] for a in mutants)
    p=raw64(fixture['data']['canvas'][0]['png']); bad=bytearray(p); bad[29]^=1
    for b in (bytes(bad),p[:-1],p+b'bad',b'not PNG'):
        try: png_rgba(b64(b))
        except ValueError: pass
        else: raise AssertionError('PNG negative control accepted')
    return {'positiveFixturePassed':True,'behaviorNegativeControlsRejected':len(mutants),'pngNegativeControlsRejected':4,'pngFilterColorPositiveControls':10}

if __name__=='__main__':
    p=argparse.ArgumentParser(); p.add_argument('observation',nargs='?'); a=p.parse_args(); controls=self_test()
    if a.observation:
        path=Path(a.observation); observation=json.loads(path.read_text()); report=verify(observation)
        report.update(schemaVersion=1,label=observation['label'],runtimeVersion=observation['runtimeVersion'],executableSHA256=observation['executableSHA256'],observationSHA256=hashlib.sha256(path.read_bytes()).hexdigest(),controls=controls)
        path.with_name(path.stem.replace('-observations','')+'-verification.json').write_text(json.dumps(report,indent=2)+'\n'); print(json.dumps(report)); sys.exit(0 if report['passed'] else 2)
    else: print(json.dumps(controls))

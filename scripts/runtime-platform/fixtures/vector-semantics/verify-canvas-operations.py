#!/usr/bin/env python3
"""Independent numerical Canvas operation oracle; never a whole release PASS.

Opaque/copy/reset values are exact. Colored alpha checks conserve premultiplied
color with the unavoidable 8-bit rounding bound; alpha itself stays exact for
putImageData. Source-over has its separate Porter-Duff/quantization tolerance.
"""
import argparse
import base64
import copy
import json
from pathlib import Path

COLORS = ((19,71,203,0),(19,71,203,1),(19,71,203,32),(240,120,36,64),
          (31,211,73,128),(200,61,19,192),(19,71,203,254),(19,71,203,255))
CASES = {'putOpaque','copyCanvas','copyCrop','copyComposite','putClipped','coloredPut',
         'sourceOver','reset','resizeWidth','resizeHeight','errors'}
DEFAULTS = dict(alpha=1,composite='source-over',fill='#000000',lineWidth=1,shadowBlur=0,
                smoothing=True,transform=[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1])
CONTROL_NAMES = ('copy-pixel','crop-offset','put-dirty-offset','colored-alpha',
                 'premultiplied-color','composite-alpha','reset-state','reset-clip',
                 'copy-source-over','reset-preserved-bitmap',
                 'resize-not-clear','missing-operation','swallowed-error')

def gradient(x,y): return bytes(((x*7+y*3)%256,(y*11+x)%256,(x*13+y*17)%256,255))
def copy_pixel(x,y):
    return gradient(x-2,y-3) if 2<=x<10 and 3<=y<9 and (x-2+y-3)%2==0 else bytes(4)
def raster(w,h,pixel): return b''.join(pixel(x,y) for y in range(h) for x in range(w))
def encoded(data): return base64.b64encode(data).decode()
def decoded(text,size):
    if not isinstance(text,str) or len(text)>16384: raise ValueError('invalid-pixels')
    data=base64.b64decode(text,validate=True)
    if len(data)!=size or encoded(data)!=text: raise ValueError('invalid-pixels')
    return data

def defaults_match(state):
    if not isinstance(state,dict) or set(state)!=set(DEFAULTS):return False
    for key in ('alpha','lineWidth','shadowBlur'):
        if type(state[key]) not in (int,float) or state[key]!=DEFAULTS[key]:return False
    return (state['smoothing'] is True and state['composite']=='source-over' and state['fill']=='#000000'
            and isinstance(state['transform'],list) and len(state['transform'])==16
            and all(type(v) in (int,float) and v==wanted for v,wanted in zip(state['transform'],DEFAULTS['transform'])))

def verify(data):
    issues=[];checks=0
    def need(value,label):
        nonlocal checks
        checks+=1
        if not value: issues.append(label)
    def exact(case,field,w,h,pixel):
        need(decoded(case[field],w*h*4)==raster(w,h,pixel),field+'-pixels')
    try:
        need(type(data.get('schemaVersion')) is int and data['schemaVersion']==1,'schema')
        need(data.get('kind')=='canvas-operations','kind')
        need(data.get('errors')==[],'capture-errors')
        cases=data['cases'];need(isinstance(cases,dict) and set(cases)==CASES,'case-coverage')
        for name in ('putOpaque','copyCanvas'):
            exact(cases[name],'pixels',16,12,gradient)
            need(cases[name]['repeat']==cases[name]['pixels'],name+'-repeat')
        exact(cases['copyComposite'],'pixels',16,12,copy_pixel)
        exact(cases['copyCrop'],'pixels',20,18,lambda x,y:gradient(x-5+3,y-7+2) if 5<=x<9 and 7<=y<12 else bytes(4))
        exact(cases['putClipped'],'pixels',16,12,lambda x,y:gradient(x+3,y+2) if 0<=x<7 and 0<=y<6 else bytes(4))
        colored=cases['coloredPut'];raw=decoded(colored['pixels'],16*12*4)
        need(colored['repeat']==colored['pixels'],'colored-repeat')
        for y in range(12):
            for x in range(16):
                wanted=COLORS[(x+y)%8];actual=raw[(y*16+x)*4:(y*16+x+1)*4];a=wanted[3]
                need(actual[3]==a,'colored-alpha')
                if a==0: need(actual[:3]==bytes(3),'transparent-rgb')
                elif a==255: need(actual[:3]==bytes(wanted[:3]),'opaque-rgb')
                else:
                    for observed,channel in zip(actual[:3],wanted[:3]):
                        need(abs(observed*a/255-channel*a/255)<=.5+a/510+1e-9,'premultiplied-color')
        composite=cases['sourceOver'];raw=decoded(composite['pixels'],16*12*4)
        need(composite['repeat']==composite['pixels'],'composite-repeat')
        sa=64/255;da=128/255;alpha=sa+da*(1-sa)
        expected=[(s*sa+d*da*(1-sa))/alpha for s,d in zip((212,75,13),(23,44,111))]
        for i in range(0,len(raw),4):
            need(abs(raw[i+3]-alpha*255)<=1,'composite-alpha')
            for channel,wanted in zip(raw[i:i+3],expected): need(abs(channel-wanted)<=2,'composite-color')
        reset=cases['reset'];need(reset.get('available') is True,'reset-api')
        exact(reset,'beforeReset',16,12,gradient)
        exact(reset,'blank',16,12,lambda *_:bytes(4));need(defaults_match(reset['state']),'reset-state')
        exact(reset,'afterFill',16,12,lambda x,y:bytes((0,0,0,255)) if x<2 and y<2 else bytes(4))
        for name,w,h in (('resizeWidth',17,12),('resizeHeight',16,13)):
            case=cases[name];need(type(case['width']) is int and type(case['height']) is int and (case['width'],case['height'])==(w,h),'resize-size')
            exact(case,'pixels',w,h,lambda *_:bytes(4));need(defaults_match(case['state']),'resize-state')
        need(cases['errors']=={'zeroRead':'IndexSizeError','zeroImage':'IndexSizeError','invalidPut':'TypeError'},'error-semantics')
    except (KeyError,TypeError,AttributeError,ValueError): issues.append('missing-or-invalid-observation')
    return dict(status='failed' if issues else 'verified-scoped-canvas-operations',
                passed=not issues,checks=checks,issues=sorted(set(issues)),
                scope='synthetic sRGB Canvas copies, alpha, reset/resize and errors; no hardware or anonymity claim')

def positive_fixture():
    opaque=encoded(raster(16,12,gradient));c={n:{'pixels':opaque} for n in ('putOpaque','copyCanvas')}
    c['copyComposite']={'pixels':encoded(raster(16,12,copy_pixel))}
    for n in ('putOpaque','copyCanvas'): c[n]['repeat']=opaque
    c['copyCrop']={'pixels':encoded(raster(20,18,lambda x,y:gradient(x-2,y-5) if 5<=x<9 and 7<=y<12 else bytes(4)))}
    c['putClipped']={'pixels':encoded(raster(16,12,lambda x,y:gradient(x+3,y+2) if x<7 and y<6 else bytes(4)))}
    def color(x,y):
        channels=COLORS[(x+y)%8];a=channels[3]
        if not a:return bytes(4)
        return bytes([min(255,round(round(v*a/255)*255/a)) for v in channels[:3]]+[a])
    colored=encoded(raster(16,12,color));c['coloredPut']={'pixels':colored,'repeat':colored}
    sa=64/255;da=128/255;a=sa+da*(1-sa)
    pixel=bytes([round((s*sa+d*da*(1-sa))/a) for s,d in zip((212,75,13),(23,44,111))]+[round(a*255)])
    composite=encoded(pixel*192);c['sourceOver']={'pixels':composite,'repeat':composite}
    c['reset']={'available':True,'beforeReset':opaque,'blank':encoded(bytes(768)),'state':copy.deepcopy(DEFAULTS),
                'afterFill':encoded(raster(16,12,lambda x,y:bytes((0,0,0,255)) if x<2 and y<2 else bytes(4)))}
    for n,w,h in (('resizeWidth',17,12),('resizeHeight',16,13)):c[n]={'width':w,'height':h,'pixels':encoded(bytes(w*h*4)),'state':copy.deepcopy(DEFAULTS)}
    c['errors']={'zeroRead':'IndexSizeError','zeroImage':'IndexSizeError','invalidPut':'TypeError'}
    return dict(schemaVersion=1,kind='canvas-operations',cases=c,errors=[])

def negative_controls():
    source=positive_fixture();assert verify(source)['passed'];controls=[]
    for name in CONTROL_NAMES:
        d=copy.deepcopy(source);c=d['cases']
        if name in ('copy-pixel','crop-offset','put-dirty-offset','colored-alpha','premultiplied-color','composite-alpha','reset-clip','resize-not-clear'):
            target,field,index={'copy-pixel':('copyCanvas','pixels',0),'crop-offset':('copyCrop','pixels',(7*20+5)*4),
                'put-dirty-offset':('putClipped','pixels',0),'colored-alpha':('coloredPut','pixels',3),
                'premultiplied-color':('coloredPut','pixels',7*4),'composite-alpha':('sourceOver','pixels',3),
                'reset-clip':('reset','afterFill',3),'resize-not-clear':('resizeWidth','pixels',3)}[name]
            b=bytearray(base64.b64decode(c[target][field]));b[index]=(b[index]+31)%256;c[target][field]=encoded(b)
        elif name=='reset-state':c['reset']['state']['alpha']=.2
        elif name=='copy-source-over':c['copyComposite']['pixels']=encoded(raster(16,12,lambda x,y:copy_pixel(x,y) if copy_pixel(x,y)[3] else bytes((255,0,255,255))))
        elif name=='reset-preserved-bitmap':c['reset']['blank']=c['reset']['beforeReset']
        elif name=='missing-operation':del c['copyCanvas']
        else:c['errors']['zeroRead']='no-error'
        controls.append({'name':name,'rejected':not verify(d)['passed']})
    assert all(c['rejected'] for c in controls)
    return controls

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('observation',type=Path)
    parser.add_argument('--negative-controls',action='store_true');args=parser.parse_args()
    def unique(pairs):
        d={}
        for key,value in pairs:
            if key in d:raise ValueError('duplicate-key')
            d[key]=value
        return d
    def constant(_):raise ValueError('nonfinite-number')
    try:
        raw=args.observation.read_bytes()
        if len(raw)>131072:raise ValueError('observation-too-large')
        result=verify(json.loads(raw,object_pairs_hook=unique,parse_constant=constant)['data'])
    except (OSError,ValueError,KeyError,TypeError):
        result=dict(status='failed',passed=False,checks=0,issues=['invalid-observation-envelope'])
    if args.negative_controls:result['negativeControls']=negative_controls()
    print(json.dumps(result));raise SystemExit(0 if result['passed'] else 1)

if __name__=='__main__':main()

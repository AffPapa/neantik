#!/usr/bin/env python3
"""Bounded MP4 fixture splitting; no encoding or browser launch."""
import importlib.util,struct
from pathlib import Path
p=Path(__file__).with_name('create-fixtures.py');spec=importlib.util.spec_from_file_location('fixtures',p);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
def box(kind,body=b''):return struct.pack('>I4s',8+len(body),kind)+body
init=box(b'ftyp')+box(b'moov');fragment=box(b'moof')+box(b'mdat',b'own');stream=init+fragment*2
assert m.split_mp4(stream)==(init,[fragment,fragment])
bad=[stream[:-1],b'bad',struct.pack('>I4s',4,b'moov'),init+box(b'mdat'),init+fragment+box(b'moof'),box(b'ftyp')+fragment*2,init+box(b'junk')+fragment*2,init+fragment]
for raw in bad:
 try:m.split_mp4(raw)
 except ValueError:pass
 else:raise AssertionError('malformed fixture accepted')
print('PASS:1positive,8negative fixture controls;no native launch')

"""Strict additive source binding for independently authored M155 corrections.

The historical 202-patch replay remains unchanged. No source or runtime PASS
is inferred from a manifest, and old signed bytes cannot inherit this policy.
"""
from __future__ import annotations
import hashlib,json,os,stat
from pathlib import Path
from chromium_15540_release_evidence import M15540EvidenceError,require_hash,safe_relative_regular,sha256_file

SET='canvas-audio-native-v1'
PREFIX='chromium-15540-semantic-v1'
BASE_SNAPSHOT='61636de70b6e5d11305d93fbc715e7a8c05901952b23255cce70be8c15edc977'
PATCH_ROOT='runtime/nevision-patches/ports/chromium-155.0.8059.40/patches/'
PATCHES={
 'canvas':(PATCH_ROOT+'m155-canvas-native-readback-semantics.patch',{
 'third_party/blink/renderer/modules/canvas/canvas2d/base_rendering_context_2d.cc',
 'third_party/blink/renderer/platform/image-encoders/image_encoder.cc',
 'third_party/blink/renderer/platform/graphics/static_bitmap_image.cc',
 'third_party/blink/renderer/platform/graphics/static_bitmap_image.h'}),
 'audio':(PATCH_ROOT+'m155-audio-native-output-semantics.patch',{
 'third_party/blink/renderer/modules/webaudio/offline_audio_context.cc'})}
VARIANTS={SET:(PREFIX,tuple(PATCHES)), 'canvas-audio-webgl-native-v2':('chromium-15540-semantic-v2',('canvas','audio','webgl')), 'canvas-audio-webgl-native-webrtc-v3':('chromium-15540-semantic-v3',('canvas','audio','webgl','webrtc'))}
VARIANTS['canvas-audio-webgl-native-webrtc-layout-text-v4']=('chromium-15540-semantic-v4',('canvas','audio','webgl','webrtc','clientrects','textmetrics'))
VARIANTS['canvas-audio-webgl-native-webrtc-layout-text-event-v5']=('chromium-15540-semantic-v5',('canvas','audio','webgl','webrtc','clientrects','textmetrics','audio-events'))
PATCHES['webgl']=(PATCH_ROOT+'m155-webgl-native-readback-semantics.patch',{'third_party/blink/renderer/modules/webgl/webgl_rendering_context_base.cc'})
PATCHES['webrtc']=(PATCH_ROOT+'m155-webrtc-explicit-udp-boundary.patch',{'chrome/browser/renderer_preferences_util.cc'})
PATCHES['clientrects']=(PATCH_ROOT+'m155-clientrects-native-geometry-semantics.patch',{'third_party/blink/renderer/core/dom/element.cc','third_party/blink/renderer/core/dom/range.cc'})
PATCHES['textmetrics']=(PATCH_ROOT+'m155-textmetrics-native-geometry-semantics.patch',{'third_party/blink/renderer/modules/canvas/canvas2d/base_rendering_context_2d.cc','third_party/blink/renderer/core/html/canvas/text_metrics.cc','third_party/blink/renderer/core/html/canvas/text_metrics.h'})
PATCHES['audio-events']=(PATCH_ROOT+'m155-audio-processor-error-event-semantics.patch',{'third_party/blink/renderer/modules/webaudio/audio_worklet_node.cc','third_party/blink/renderer/modules/webaudio/audio_worklet_node.h'})
REVIEWED_INPUT_SNAPSHOTS={
 'canvas-audio-native-v1':'d6e208b017790ccd44793c2b9e687c19402991003fa6da9cbd5985a8b286fd94',
 'canvas-audio-webgl-native-v2':'453f1d8753ebb39eabd1a6dfe547accdf3aedf3eeca1b39fdf39cbfc43260d59',
 'canvas-audio-webgl-native-webrtc-v3':'fda0a5e21c9e08c2a6972fc7c1e9c94996aa3162bbd1ea54df90c5272f9f39b9',
 'canvas-audio-webgl-native-webrtc-layout-text-v4':'db0d165e23fb0e35f9bfdd385f79ae5ea217db2860527ca73eafeba7dfa8082a',
 'canvas-audio-webgl-native-webrtc-layout-text-event-v5':'ee8096b06457e4c7d3fafd9f3dcd6bd642ffefe6aad6ad280483af93e749274b',
}
KEYS={'schemaVersion','kind','semanticCorrectionSet','targetChromiumVersion','baseSourceContractSHA256','baseSourceSnapshotSHA256','baseOrderedReplaySHA256','patches','releaseReady'}

def object_at(path:Path)->dict:
 try:
  fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
  try:
   before=os.fstat(fd)
   if not stat.S_ISREG(before.st_mode) or before.st_size>65536:raise M15540EvidenceError('Invalid correction document')
   data=os.read(fd,65537);after=os.fstat(fd)
   if len(data)>65536 or len(data)!=before.st_size or (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns)!=(after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns):raise M15540EvidenceError('Correction document changed while reading')
  finally:os.close(fd)
 except OSError as e:raise M15540EvidenceError('Cannot safely read correction document') from e
 def pairs(items):
  d={}
  for k,v in items:
   if k in d:raise M15540EvidenceError('Duplicate correction key')
   d[k]=v
  return d
 try:d=json.loads(data.decode('utf-8'),object_pairs_hook=pairs)
 except (UnicodeError,json.JSONDecodeError) as e:raise M15540EvidenceError('Invalid correction JSON') from e
 if not isinstance(d,dict):raise M15540EvidenceError('Correction document is not an object')
 return d

def verify_manifest(project:Path,document:dict)->dict[str,str]:
 v4=document.get('semanticCorrectionSet') in ('canvas-audio-webgl-native-webrtc-layout-text-v4','canvas-audio-webgl-native-webrtc-layout-text-event-v5')
 expected_keys=KEYS|({'generatedBuildCacheEvidenceSHA256'} if v4 else set())
 if set(document)!=expected_keys or type(document['schemaVersion']) is not int or document['schemaVersion']!=1 or document['kind']!='chromium-semantic-corrections' or not isinstance(document['semanticCorrectionSet'],str) or document['semanticCorrectionSet'] not in VARIANTS or document['targetChromiumVersion']!='155.0.8059.40' or document['releaseReady'] is not False:raise M15540EvidenceError('Unknown correction schema or policy')
 runtime=project/'runtime'
 for key,path in [('baseSourceContractSHA256','chromium-15540-source-contract.json'),('baseSourceSnapshotSHA256','chromium-15540-source-snapshot.json'),('baseOrderedReplaySHA256','chromium-15540-source-evidence/ordered-patch-replay.json')]:
  if sha256_file(safe_relative_regular(runtime,path))!=require_hash(document[key],key):raise M15540EvidenceError('Correction base binding mismatch')
 if document['baseSourceSnapshotSHA256']!=BASE_SNAPSHOT:raise M15540EvidenceError('Unknown correction base snapshot')
 if v4:
  from chromium_15540_generated_cache import verify_document
  cache=safe_relative_regular(runtime,'chromium-15540-semantic-v3-generated-build-cache.json');verify_document(object_at(cache))
  if document['generatedBuildCacheEvidenceSHA256']!=sha256_file(cache):raise M15540EvidenceError('Inherited generated cache binding mismatch')
 patches=document['patches']
 vectors=VARIANTS[document['semanticCorrectionSet']][1]
 if not isinstance(patches,list) or len(patches)!=len(vectors):raise M15540EvidenceError('Correction patch coverage')
 result={}
 for item,(vector,(patch_path,targets)) in zip(patches,((v,PATCHES[v]) for v in vectors)):
  keys={'vector','path','sha256','files'}|({'dependsOn'} if v4 else set())
  if not isinstance(item,dict) or set(item)!=keys or item['vector']!=vector or item['path']!=patch_path:raise M15540EvidenceError('Correction order or path mismatch')
  if v4 and item['dependsOn']!=(['canvas'] if vector=='textmetrics' else []):raise M15540EvidenceError('Correction dependency mismatch')
  if sha256_file(safe_relative_regular(project,patch_path))!=require_hash(item['sha256'],'patch'):raise M15540EvidenceError('Correction patch digest mismatch')
  files=item['files']
  if not isinstance(files,list) or len(files)!=len(targets):raise M15540EvidenceError('Correction file count mismatch')
  seen=set()
  for f in files:
   if not isinstance(f,dict) or set(f)!={'path','preimageSHA256','postimageSHA256'} or not isinstance(f['path'],str) or f['path'] not in targets or f['path'] in seen:raise M15540EvidenceError('Correction touched path mismatch')
   require_hash(f['preimageSHA256'],'preimage');require_hash(f['postimageSHA256'],'postimage')
   if f['path'] in result and (not v4 or f['preimageSHA256']!=result[f['path']]):raise M15540EvidenceError('Overlapping patch preimage lineage mismatch')
   seen.add(f['path']);result[f['path']]=f['postimageSHA256']
  if seen!=targets:raise M15540EvidenceError('Correction touched path coverage')
 return result

def verify_live_postimages(project:Path,source:Path,document:dict)->dict[str,str]:
 result=verify_manifest(project,document)
 for name,expected in result.items():
  if sha256_file(safe_relative_regular(source,name))!=expected:raise M15540EvidenceError('Correction live source mismatch')
 return result

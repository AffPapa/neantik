// Offline checks bind actual operations to every fragment, not declarations.
export function assess(value,manifest){
 const issues=[];let checks=0;const check=(valid,label)=>{checks++;if(!valid)issues.push(label);};
 check(value?.kind==='actual-mse-operations','missing-operation-report');check(Array.isArray(value?.rows)&&value.rows.length===2,'missing-rows');
 for(const c of manifest.cases){
  const r=value?.rows?.find(v=>v.id===c.id);if(!r){check(false,c.id+':missing');continue;}
  check(r.kind===c.kind&&r.status==='actual-stream-operations',c.id+':not-complete');check(r.supported===true,c.id+':unsupported');check(r.sourceBufferCount===1,c.id+':source-buffer');
  check(r.unsupported==='NotSupportedError',c.id+':unsupported-control');check(r.busyEndOfStream==='InvalidStateError',c.id+':busy-control');
  check(Array.isArray(r.appends)&&r.appends.length===c.files.length,c.id+':missing-append');let prior=0;
  for(const [i,file]of c.files.entries()){
   const a=r.appends?.[i];check(a?.file===file&&a.sha256===manifest.files[file].sha256,c.id+':asset-'+i);check(a?.updating===false,c.id+':updateend-'+i);
   if(i>0){check(a?.rangeCount===1&&Number.isFinite(a.end)&&a.end>prior,c.id+':buffer-progress-'+i);prior=a?.end??0;}
  }
  check(r.endedState==='ended'&&Number.isFinite(r.duration)&&r.duration>1.9&&r.duration<2.2,c.id+':end-of-stream');check(Number.isFinite(r.advanced)&&r.advanced>=.25&&r.advanced<2.2&&Number.isInteger(r.readyState)&&r.readyState>=2&&r.readyState<=4,c.id+':playback');
  if(c.kind==='video'){check(JSON.stringify(r.dimensions)==='[64,48]'&&Number.isInteger(r.frames)&&r.frames>=2,c.id+':frames');check(Array.isArray(r.pixel)&&r.pixel.length===4&&r.pixel[0]>220&&r.pixel[0]<=255&&r.pixel[1]>=0&&r.pixel[1]<45&&r.pixel[2]>=0&&r.pixel[2]<45&&r.pixel[3]===255,c.id+':actual-red-frame');}
  check(r.invalidRemove==='TypeError',c.id+':invalid-range');check(r.rangeCountAfterRemove===0&&r.stateAfterRemove==='open',c.id+':remove-buffered');check(r.sourceBufferCountAfterRemove===0,c.id+':remove-source-buffer');check(r.detachedAppend==='InvalidStateError',c.id+':detached-control');check(r.duplicateRemove==='NotFoundError',c.id+':duplicate-control');check(r.cleaned===true,c.id+':media-cleanup');
 }
 return{status:issues.length?'failed':'passed-scoped-mse-operations',checks,issues,releaseQualified:false};
}

// Only synthetic local streams. Declarations alone never establish playback.
(async()=>{
 const nonce=document.documentElement.dataset.nonce,manifest=await(await fetch('/manifest.json')).json(),rows=[];
 const wait=(target,event,action)=>new Promise((resolve,reject)=>{
  let timer;const clear=()=>{clearTimeout(timer);target.removeEventListener(event,ok);target.removeEventListener('error',bad);};
  const ok=()=>{clear();resolve();},bad=()=>{clear();reject(Error('event-error'));};
  target.addEventListener(event,ok,{once:true});target.addEventListener('error',bad,{once:true});timer=setTimeout(()=>{clear();reject(Error('event-timeout'));},5000);
  try{action?.();}catch(e){clear();reject(e);}
 });
 const errorName=action=>{try{action();return 'incorrectly-accepted';}catch(e){return e.name;}};
 const hash=async bytes=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),v=>v.toString(16).padStart(2,'0')).join('');
 for(const c of manifest.cases){
  const row={id:c.id,kind:c.kind},media=document.createElement(c.kind),source=new MediaSource(),url=URL.createObjectURL(source);media.muted=true;media.style.cssText='width:64px;height:48px';document.body.append(media);
  try{
   row.supported=MediaSource.isTypeSupported(c.mime);await wait(source,'sourceopen',()=>{media.src=url;});
   row.unsupported=errorName(()=>source.addSourceBuffer('video/mp4; codecs="neantik.invalid"'));
   const buffer=source.addSourceBuffer(c.mime);row.sourceBufferCount=source.sourceBuffers.length;row.appends=[];
   for(const [i,file]of c.files.entries()){
    const bytes=await(await fetch('/'+file)).arrayBuffer(),sha256=await hash(bytes);let busyState;
    await wait(buffer,'updateend',()=>{buffer.appendBuffer(bytes);if(i===0)busyState=errorName(()=>source.endOfStream());});
    if(i===0)row.busyEndOfStream=busyState;
    row.appends.push({file,sha256,updating:buffer.updating,rangeCount:buffer.buffered.length,end:buffer.buffered.length?buffer.buffered.end(buffer.buffered.length-1):0});
   }
   await wait(source,'sourceended',()=>source.endOfStream());row.endedState=source.readyState;row.duration=media.duration;
   await media.play();const start=media.currentTime,deadline=performance.now()+5000;
   await new Promise((resolve,reject)=>{const tick=()=>{if(media.error)return reject(Error('media-error'));if(media.currentTime-start>=.25)return resolve();if(performance.now()>deadline)return reject(Error('time-timeout'));setTimeout(tick,20);};tick();});
   row.advanced=media.currentTime-start;row.readyState=media.readyState;
   if(c.kind==='video'){
    row.dimensions=[media.videoWidth,media.videoHeight];row.frames=media.getVideoPlaybackQuality().totalVideoFrames;const canvas=document.createElement('canvas');canvas.width=64;canvas.height=48;const ctx=canvas.getContext('2d');ctx.drawImage(media,0,0);row.pixel=Array.from(ctx.getImageData(30,20,1,1).data);
   }
   media.pause();row.invalidRemove=errorName(()=>buffer.remove(-1,1));
   await wait(buffer,'updateend',()=>buffer.remove(0,Infinity));row.rangeCountAfterRemove=buffer.buffered.length;row.stateAfterRemove=source.readyState;
   source.removeSourceBuffer(buffer);row.sourceBufferCountAfterRemove=source.sourceBuffers.length;row.detachedAppend=errorName(()=>buffer.appendBuffer(new Uint8Array([0])));row.duplicateRemove=errorName(()=>source.removeSourceBuffer(buffer));row.status='actual-stream-operations';
  }catch(e){row.status='failed';row.error=e.name;}
  finally{media.pause();media.removeAttribute('src');media.load();media.remove();URL.revokeObjectURL(url);row.cleaned=true;}
  rows.push(row);
 }
 await fetch('/result',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({nonce,kind:'actual-mse-operations',rows})});
})().catch(async e=>{await fetch('/result',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({nonce:document.documentElement.dataset.nonce,kind:'harness-failed',error:e.name})});});

(async () => {
  // This fixture is launched only with Chromium synthetic media devices.
  // Never export labels, device IDs, frame pixels or microphone samples.
  const result = {kind:'synthetic-media-capture',errors:[],cleanupVerified:false};
  const streams = []; let video, audio, source, processor;
  const bounded = (operation, ms=5000) => {
    let timer, expired=false;
    const request=Promise.resolve().then(operation);
    request.then(value=>{if(expired&&value?.getTracks)value.getTracks().forEach(t=>t.stop());},()=>{});
    return Promise.race([request,new Promise((_,reject)=>{timer=setTimeout(()=>{expired=true;reject(new Error('OwnTimeout'));},ms);})]).finally(()=>clearTimeout(timer));
  };
  const query = async name => bounded(()=>navigator.permissions.query({name}));
  try {
    const camera=await query('camera'), microphone=await query('microphone');
    result.before={camera:camera.state,microphone:microphone.state};
    const stream=await bounded(()=>navigator.mediaDevices.getUserMedia({video:true,audio:true}));streams.push(stream);
    result.tracks=stream.getTracks().map(t=>({kind:t.kind,state:t.readyState}));
    video=document.createElement('video');video.muted=true;video.srcObject=stream;document.body.appendChild(video);
    await bounded(()=>video.play());
    const frame=await bounded(()=>new Promise(resolve=>video.requestVideoFrameCallback((_,metadata)=>resolve(metadata))));
    const canvas=document.createElement('canvas');canvas.width=4;canvas.height=4;
    const context=canvas.getContext('2d');context.drawImage(video,0,0,4,4);
    const pixels=context.getImageData(0,0,4,4).data;
    result.frame={presented:frame.presentedFrames>0,width:video.videoWidth,height:video.videoHeight,nonzeroColor:Array.from(pixels).some((v,i)=>i%4!==3&&v!==0)};
    audio=new AudioContext();source=audio.createMediaStreamSource(stream);processor=audio.createScriptProcessor(256,1,1);
    let callbacks=0;const processed=bounded(()=>new Promise(resolve=>{processor.onaudioprocess=event=>{callbacks++;resolve({frames:event.inputBuffer.length,channels:event.inputBuffer.numberOfChannels,finite:Array.from(event.inputBuffer.getChannelData(0)).every(Number.isFinite)});};}));
    source.connect(processor);processor.connect(audio.destination);await audio.resume();result.audio=await processed;result.audio.callbacks=callbacks;
    let changes=0;const changed=()=>{changes++;};camera.addEventListener('change',changed);microphone.addEventListener('change',changed);
    try {
      const nonce=document.body.dataset.ownFixture;
      const response=await bounded(()=>fetch('/media-permission?setting=denied&nonce='+encodeURIComponent(nonce)));
      if(!response.ok)throw Error('PermissionControlFailed');
      const deadline=performance.now()+5000;
      while(camera.state!=='denied'||microphone.state!=='denied'){
        if(performance.now()>=deadline)throw Error('OwnTimeout');
        await new Promise(resolve=>setTimeout(resolve,10));
      }
      result.revoked={camera:camera.state,microphone:microphone.state,events:changes};
      result.activeAfterRevoke=stream.getTracks().map(t=>({kind:t.kind,state:t.readyState}));
      stream.getTracks().forEach(t=>t.stop());
      try {const unexpected=await bounded(()=>navigator.mediaDevices.getUserMedia({video:true,audio:true}));streams.push(unexpected);result.denied={rejected:false};}
      catch(error){result.denied={rejected:true,error:error.name};}
    } finally {camera.removeEventListener('change',changed);microphone.removeEventListener('change',changed);}
  } catch(error) {result.errors.push(error.message==='OwnTimeout'?'timeout':error.name);}
  finally {
    processor && (processor.onaudioprocess=null);source?.disconnect();processor?.disconnect();
    streams.forEach(s=>s.getTracks().forEach(t=>t.stop()));
    if(audio && audio.state!=='closed')await audio.close();
    if(video){video.pause();video.srcObject=null;video.remove();}
    result.cleanupVerified=streams.every(s=>s.getTracks().every(t=>t.readyState==='ended'))&&(!audio||audio.state==='closed')&&(!video||!video.isConnected&&video.srcObject===null);
  }
  return result;
})()

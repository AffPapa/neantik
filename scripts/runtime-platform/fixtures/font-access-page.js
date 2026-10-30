// Fixed operations on four explicit names. No unfiltered query or font export.
(async()=>{
  const config=globalThis.OWN_FONT_ACCESS_CONFIG,nonce=config.nonce;
  globalThis.__OWN_REALM_NONCE=nonce;
  const url=route=>config.origin+route+'?nonce='+nonce;
  const report={schemaVersion:1,nonce,ready:null,stages:[],events:[],foreign:null,topForeign:null,error:null};
  const bounded=async(promise,ms=15000)=>{let timer;try{return await Promise.race([promise,new Promise((_,reject)=>timer=setTimeout(()=>reject(Error('OwnAccessTimeout')),ms))]);}finally{clearTimeout(timer);}};
  const until=async(test)=>{const end=Date.now()+10000;while(Date.now()<end){if(test())return;await new Promise(resolve=>setTimeout(resolve,30));}throw Error('OwnAccessStateTimeout');};
  const post=async(route,value)=>{const response=await fetch(url(route),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(value)});if(!response.ok)throw Error('OwnAccessHTTP');};
  const digest=async bytes=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),x=>x.toString(16).padStart(2,'0')).join('');
  const names=[...config.names,'NeAntikMissing_'+nonce],retained=[];let permission=null,foreignFrame=null,foreignListener=null;
  const query=async()=>{
    const entries=await queryLocalFonts({postscriptNames:names});
    if(entries.some(font=>!names.includes(font.postscriptName))||new Set(entries.map(font=>font.postscriptName)).size!==entries.length)throw Error('OwnAccessUnexpectedEntry');
    return entries;
  };
  const checkBlob=async(font,index,initialHash=null)=>{
    const blob=await bounded(font.blob());if(blob.size<28||blob.size>32*1024*1024)throw Error('OwnAccessBlobSize');
    const bytes=new Uint8Array(await bounded(blob.arrayBuffer())),parsed=readOwnFontSFNT(bytes,config.names[index]);
    let matchedOwnTables=0;
    if(index<2){for(const [tag,expected]of Object.entries(config.ownTables[index])){const data=parsed.tables.get(tag);if(!data||await digest(data)!==expected)throw Error('OwnAccessTableMismatch');matchedOwnTables++;}}
    const hash=await digest(bytes),family='QAOwnedAccessBlob'+index,face=new FontFace(family,bytes);let drawingValid=false,removed=false;
    try{
      await bounded(face.load());document.fonts.add(face);await bounded(document.fonts.ready);
      const canvas=document.createElement('canvas');canvas.width=200;canvas.height=64;const context=canvas.getContext('2d',{willReadFrequently:true});context.font=`20px ${family}`;
      if(context.font!==`20px ${family}`)throw Error('OwnAccessBlobFontRejected');
      const widths=Array.from({length:3},()=>context.measureText('ABABA').width);context.fillText('ABABA',2,40);
      const pixels=context.getImageData(0,0,200,64).data;drawingValid=widths.every(value=>Number.isFinite(value)&&value>0&&Math.abs(value-widths[0])<=0.08)&&pixels.some((value,i)=>i%4===3&&value>128);
      if(!drawingValid)throw Error('OwnAccessBlobDrawing');
    }finally{document.fonts.delete(face);removed=!document.fonts.has(face);}
    if(!removed)throw Error('OwnAccessBlobFaceLeaked');
    return {hash,summary:{index,validSFNT:parsed.validSFNT,expectedPostscriptName:parsed.expectedPostscriptName,matchedOwnTables,drawingValid,removed,sameAsGranted:initialHash===null?null:hash===initialHash}};
  };
  const foreign=()=>new Promise((resolve,reject)=>{
    foreignFrame=document.createElement('iframe');foreignFrame.allow='local-fonts *';
    foreignListener=event=>{if(event.source!==foreignFrame.contentWindow||event.origin!==config.foreignOrigin||event.data?.nonce!==nonce||event.data?.kind!=='own-font-access-foreign')return;event.data.error?reject(Error('OwnAccessForeignFailure')):resolve(event.data.value);};
    addEventListener('message',foreignListener);foreignFrame.src=config.foreignOrigin+'/foreign?nonce='+nonce;document.body.append(foreignFrame);
  });
  try{
    if(typeof queryLocalFonts!=='function'||typeof readOwnFontSFNT!=='function')throw Error('OwnAccessAPIUnavailable');
    permission=await navigator.permissions.query({name:'local-fonts'});permission.addEventListener('change',()=>report.events.push(permission.state));
    report.ready={secureContext:isSecureContext,visible:document.visibilityState==='visible',initialPermission:permission.state,activeGesture:navigator.userActivation.isActive,filteredNames:names.length};
    await post('/ready',{nonce,ready:report.ready});
    for(const phase of ['denied-initial','granted','denied-revoked']){
      const end=Date.now()+30000;let allowed=false;
      while(Date.now()<end){const value=await(await fetch(url('/phase')+'&visible='+(document.visibilityState==='visible'?'1':'0'))).json();if(value.topForeign)report.topForeign=value.topForeign;if(value.phase===phase){allowed=true;break;}await new Promise(resolve=>setTimeout(resolve,40));}
      if(!allowed)throw Error('OwnAccessPhaseTimeout');
      const expected=phase==='granted'?'granted':'denied',eventExpected=phase!=='denied-initial'||report.ready.initialPermission!=='denied';
      await until(()=>permission.state===expected&&(!eventExpected||report.events.at(-1)===expected));
      const entries=await bounded(query()),stage={phase,permission:permission.state,eventExpected,eventSeen:report.events.at(-1)===expected,count:entries.length,selected:names.map(name=>entries.some(font=>font.postscriptName===name)),blobs:[]};
      if(phase==='granted'){
        for(const font of entries){const index=config.names.indexOf(font.postscriptName);if(index<0)throw Error('OwnAccessInventedFontPresent');const checked=await checkBlob(font,index);retained.push({font,index,hash:checked.hash});stage.blobs.push(checked.summary);}
        report.foreign=await bounded(foreign());
      }else if(phase==='denied-revoked'){
        // Upstream FontData retains access; revoke blocks fresh enumeration.
        for(const entry of retained)stage.blobs.push((await checkBlob(entry.font,entry.index,entry.hash)).summary);
      }
      report.stages.push(stage);await post('/step',{nonce,stage});
    }
  }catch(error){report.error={kind:error.name,message:/^OwnAccess[A-Za-z]+$/.test(error.message)?error.message:'own-access-operation-failure'};}
  finally{if(foreignListener)removeEventListener('message',foreignListener);foreignFrame?.remove();report.foreignRemoved=!foreignFrame||!foreignFrame.isConnected;}
  await post('/result',report);
})().catch(()=>{});

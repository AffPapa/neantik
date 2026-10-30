// Served only by the owned manager/relay fixture. No CDP or raw ICE export.
(async()=>{
  const config=globalThis.OWN_WEBRTC_CONFIG;
  if(!config||config.nonce!==document.body.dataset.ownFixture)throw Error('OwnedDocumentMismatch');
  const peer=new RTCPeerConnection({iceServers:[{urls:config.stunURL}]});
  let timer,complete=false,timedOut=false;
  const candidates={host:0,srflx:0,prflx:0,relay:0,other:0},errorCodes=[];
  try{
    peer.onicecandidate=event=>{if(event.candidate){const kind=event.candidate.type;candidates[Object.hasOwn(candidates,kind)?kind:'other']++;}};
    peer.onicecandidateerror=event=>{if(errorCodes.length<16&&Number.isInteger(event.errorCode))errorCodes.push(event.errorCode);};
    peer.createDataChannel('owned-manager-udp');
    const gathering=new Promise(resolve=>{
      peer.onicegatheringstatechange=()=>{if(peer.iceGatheringState==='complete'){complete=true;clearTimeout(timer);resolve();}};
      timer=setTimeout(()=>{timedOut=true;resolve();},12000);
    });
    await peer.setLocalDescription(await peer.createOffer());await gathering;
    const result={nonce:config.nonce,gatheringComplete:complete,iceGatheringState:peer.iceGatheringState,timedOut,candidates,errorCodes,rawICEExported:false};
    const target=new URL(location.href);target.searchParams.set('result',JSON.stringify(result));
    const response=await fetch(target,{cache:'no-store',credentials:'omit'});
    if(!response.ok)throw Error('OwnedReceiptRefused');
    document.querySelector('#result').textContent=complete&&!timedOut?'WebRTC completed':'WebRTC incomplete';
  }catch{document.querySelector('#result').textContent='WebRTC fixture failed';}
  finally{clearTimeout(timer);peer.onicecandidate=null;peer.onicecandidateerror=null;peer.onicegatheringstatechange=null;peer.close();}
})()

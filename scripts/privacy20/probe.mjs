// Fixed synthetic page only; page results carry no real browsing data.
export function page(nonce, phase, marker) {
  return `<!doctype html><meta charset=utf-8><title>NeAntik private policy QA</title><h1>Owned privacy test ${phase}</h1><script type=module>
const nonce=${JSON.stringify(nonce)}, marker=${JSON.stringify(marker)}, result={nonce,phase:${JSON.stringify(phase)}};
const bound=(p,ms=3000)=>Promise.race([p,new Promise((_,r)=>setTimeout(()=>r(Error('timeout')),ms))]);
try {
 result.before={cookie:document.cookie,local:localStorage.getItem('owned-marker')};
 result.httpCache=[await(await fetch('/owned-http-cache')).text(),await(await fetch('/owned-http-cache')).text()];
 result.connections=[await(await fetch('/owned-connection')).json(),await(await fetch('/owned-connection')).json()];
 result.tlsFirst=await(await fetch('/owned-tls-close')).json();await new Promise(r=>setTimeout(r,150));
 result.tlsSecond=await(await fetch('/owned-tls-close')).json();

 const db=await new Promise((resolve,reject)=>{const q=indexedDB.open('owned-privacy20',1);q.onupgradeneeded=()=>q.result.createObjectStore('data');q.onerror=()=>reject(q.error);q.onsuccess=()=>resolve(q.result)});
 result.before.idb=await new Promise((resolve,reject)=>{const q=db.transaction('data').objectStore('data').get('marker');q.onsuccess=()=>resolve(q.result??null);q.onerror=()=>reject(q.error)});
 result.before.cache=await(await caches.open('owned-cache')).match('/owned-cache-marker').then(async r=>r?await r.text():null);
 document.cookie='owned_marker='+marker+';Secure;SameSite=Strict;Path=/;Max-Age=3600';localStorage.setItem('owned-marker',marker);
 await new Promise((resolve,reject)=>{const tx=db.transaction('data','readwrite');tx.objectStore('data').put(marker,'marker');tx.oncomplete=resolve;tx.onerror=()=>reject(tx.error)});db.close();
 await(await caches.open('owned-cache')).put('/owned-cache-marker',new Response(marker));
 const registration=await navigator.serviceWorker.register('/owned-sw.js');await navigator.serviceWorker.ready;
 result.serviceWorker=registration.active!==null;
 result.worker=await bound(new Promise((resolve,reject)=>{const worker=new Worker('/owned-worker.js');worker.onmessage=e=>{resolve(e.data);worker.terminate()};worker.onerror=()=>reject(Error('worker'))}));
 try {const pc=new RTCPeerConnection();result.rtc='created';pc.close()}catch(e){result.rtc=e.name}
 const gl=document.createElement('canvas').getContext('webgl');result.webgl=!!gl;result.debugRenderer=gl?.getExtension('WEBGL_debug_renderer_info')!==null;result.debugEnumerated=gl?.getSupportedExtensions().includes('WEBGL_debug_renderer_info');
 result.geometry={innerWidth,innerHeight,outerWidth,outerHeight};result.timezone=Intl.DateTimeFormat().resolvedOptions().timeZone;
 result.permissions={};for(const name of ['camera','microphone','geolocation','notifications']){try{result.permissions[name]=(await navigator.permissions.query({name})).state}catch{result.permissions[name]='unsupported'}}
 result.devices=(await navigator.mediaDevices.enumerateDevices()).map(d=>({kind:d.kind,id:d.deviceId,label:d.label}));
 const scripts=['Latin ABC','Кириллица Ж','漢字かな','العربية','e\\u0301','😀','❤\\uFE0F'];const c=document.createElement('canvas').getContext('2d');c.font='16px sans-serif';result.fontVectors=scripts.map(text=>({text,width:c.measureText(text).width}));
 result.lan={};for(const host of ['127.0.0.1','localhost','192.168.1.1','[::1]']){try{await bound(fetch('https://'+host+':44443/private-canary',{mode:'no-cors'}));result.lan[host]='unexpected-success'}catch{result.lan[host]='rejected'}}
 result.tracker=await bound(fetch('https://ad.ae.doubleclick.net/owned-tracker',{mode:'no-cors'})).then(()=> 'unexpected-success',()=> 'rejected');
 result.websocket=await bound(new Promise((resolve,reject)=>{const ws=new WebSocket(location.origin.replace('https:','wss:')+'/owned-ws');ws.onmessage=e=>{resolve(e.data);ws.close()};ws.onerror=()=>reject(Error('own websocket'))}));
 result.keepalive=await(await fetch('/owned-keepalive',{keepalive:true})).text();
 const link=document.createElement('a');link.href='/owned-download';link.download='owned-test.txt';document.body.append(link);link.click();link.remove();result.downloadRequested=true;

 if(result.phase==='A2'){
  await fetch('/begin-failure');await new Promise(r=>setTimeout(r,150));
  result.proxyFailure=await bound(fetch('/failure-check',{cache:'no-store'}),1000).then(()=> 'unexpected-success',()=> 'rejected');
  await new Promise(r=>setTimeout(r,2300));
  result.proxyRecovery=await bound(fetch('/recovery',{cache:'no-store'})).then(r=>r.status===200,()=>false);
 }
 result.status='observed';
}catch(e){result.status='failed';result.failure=String(e.message).slice(0,80)}
await fetch('/result?nonce='+nonce,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(result)});
</script>`;
}
export const workerSource = `
(async()=>{const result={timezone:Intl.DateTimeFormat().resolvedOptions().timeZone,fonts:typeof self.fonts!=='undefined',storage:typeof indexedDB==='object'};
result.fetch=await(await fetch('/owned-worker-network',{keepalive:true})).text();
result.websocket=await Promise.race([new Promise(resolve=>{const ws=new WebSocket(location.origin.replace('https:','wss:')+'/owned-worker-ws');ws.onopen=()=>{ws.close();resolve('unexpected-success')};ws.onerror=()=>resolve('rejected')}),new Promise(resolve=>setTimeout(()=>resolve('timeout'),2000))]);postMessage(result)})();`;
export const serviceWorkerSource = `addEventListener('install',e=>e.waitUntil(skipWaiting()));addEventListener('activate',e=>e.waitUntil(clients.claim()));`;

export function rtcPage(nonce, udpPort) {
 return `<!doctype html><meta charset=utf-8><title>Own RTC route QA</title><script type=module>
const r={nonce:${JSON.stringify(nonce)},status:'not-run'};
try{const pc=new RTCPeerConnection({iceServers:[{urls:'stun:127.0.0.1:${udpPort}'}]});r.rtc='created';r.candidateTypes=[];pc.onicecandidate=e=>{if(e.candidate){const type=e.candidate.type??'unknown';if(!r.candidateTypes.includes(type))r.candidateTypes.push(type)}};pc.createDataChannel('own-synthetic-data');await pc.setLocalDescription(await pc.createOffer());await new Promise(resolve=>{const timer=setTimeout(resolve,3500);pc.onicegatheringstatechange=()=>{if(pc.iceGatheringState==='complete'){clearTimeout(timer);resolve()}}});pc.close();
try{const w=new WebTransport(location.origin+'/owned-webtransport');r.webTransport=await Promise.race([w.ready.then(()=>{w.close();return 'unexpected-success'},()=> 'rejected'),new Promise(resolve=>setTimeout(()=>resolve('timeout'),2500))])}catch{r.webTransport='rejected'}
r.status='observed'}catch(e){r.rtc=e.name;r.status='failed'}
await fetch('/result?nonce='+r.nonce,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(r)});
</script>`;
}

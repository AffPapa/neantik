// Code served only by the owned HTTPS qualification fixture, never to user pages.
export const hints = ['architecture', 'bitness', 'platformVersion', 'fullVersionList'];
export async function captureIdentity() {
  if (!navigator.userAgentData) throw Error('UADataUnavailable');
  return {userAgent: navigator.userAgent, languages: Array.from(navigator.languages),
    deviceMemory: navigator.deviceMemory,
    hints: await navigator.userAgentData.getHighEntropyValues(['architecture','bitness','platformVersion','fullVersionList'])};
}

export function workerSource(config) {
  return `const own=${JSON.stringify(config)}; const capture=${captureIdentity};
onmessage=async()=>{try{const js=await capture();const rows=[];
for(const [operation,origin] of [['worker',own.a],['worker-cross',own.b]]){
 const nonce=crypto.randomUUID(); const http=await(await fetch(origin+'/identity?token='+own.token+'&operation='+operation+'&nonce='+nonce,{cache:'no-store'})).json();
 rows.push({operation,nonce,js,http});}postMessage({rows});}catch{postMessage({error:'WorkerOperationFailed'});}close();};`;
}

export function serviceWorkerSource(config) {
  return `const own=${JSON.stringify(config)}; const capture=${captureIdentity};
addEventListener('install',e=>e.waitUntil(skipWaiting()));
addEventListener('activate',e=>e.waitUntil(clients.claim()));
addEventListener('fetch',e=>{const u=new URL(e.request.url);if(u.origin!==own.a||u.pathname!='/identity'||u.searchParams.get('operation')!=='service-worker')return;
e.respondWith((async()=>{const result=await fetch(e.request);const client=await clients.get(e.clientId);if(client)client.postMessage({ownSW:u.searchParams.get('nonce'),js:await capture()});return result;})());});`;
}

export function policyControlSource(config) {
  return `const own=${JSON.stringify(config)}; const capture=${captureIdentity};
(async()=>{const nonce=crypto.randomUUID(),js=await capture();const http=await(await fetch(own.b+'/identity?token='+own.token+'&operation=cross-not-delegated&nonce='+nonce,{cache:'no-store'})).json();parent.postMessage({ownPolicy:own.token,row:{operation:'cross-not-delegated',nonce,js,http}},own.a);})();`;
}

export function pageSource(config) {
  return `const own=${JSON.stringify(config)}; const capture=${captureIdentity};
(async()=>{const rows=[];let registration=null,iframe=null,listener=null,timer=null,stage='identity';
try{const js=await capture();
const read=async(operation,origin,path='/identity',headers={})=>{stage=operation;const nonce=crypto.randomUUID();
const http=await(await fetch(origin+path+'?token='+own.token+'&operation='+operation+'&nonce='+nonce,{cache:'no-store',headers})).json();
const row={operation,nonce,js,http};rows.push(row);return row;};
await read('page',own.a);await read('redirect',own.a,'/redirect');
stage='cross-warm';iframe=document.createElement('iframe');iframe.src=own.b+'/warm?token='+own.token;
await new Promise((resolve,reject)=>{timer=setTimeout(()=>reject(Error('CrossWarmTimeout')),8000);
listener=e=>{if(e.origin===own.b&&e.source===iframe.contentWindow&&e.data?.ownWarm===own.token){clearTimeout(timer);resolve();}};
addEventListener('message',listener);document.body.append(iframe);});removeEventListener('message',listener);listener=null;
await read('cross',own.b);await read('cross-redirect',own.a,'/cross-redirect');
stage='nondelegation-control';const control=document.createElement('iframe');control.src=own.a+'/policy-control?token='+own.token;
const controlled=await new Promise((resolve,reject)=>{const t=setTimeout(()=>reject(Error('PolicyTimeout')),8000);
const l=e=>{if(e.origin===own.a&&e.source===control.contentWindow&&e.data?.ownPolicy===own.token){clearTimeout(t);removeEventListener('message',l);resolve(e.data.row);}};
addEventListener('message',l);document.body.append(control);});rows.push(controlled);control.remove();
stage='dedicated-worker';const workerRows=await new Promise((resolve,reject)=>{const w=new Worker('/worker.js?token='+own.token);
const t=setTimeout(()=>{w.terminate();reject(Error('WorkerTimeout'));},8000);
w.onmessage=e=>{clearTimeout(t);w.terminate();e.data?.rows?resolve(e.data.rows):reject(Error('WorkerFailed'));};
w.onerror=()=>{clearTimeout(t);w.terminate();reject(Error('WorkerError'));};w.postMessage('start');});rows.push(...workerRows);
stage='service-worker';registration=await navigator.serviceWorker.register('/owned-sw.js?token='+own.token,{scope:'/',updateViaCache:'none'});
await navigator.serviceWorker.ready;const deadline=performance.now()+8000;
while(navigator.serviceWorker.controller?.scriptURL!==new URL('/owned-sw.js?token='+own.token,own.a).href&&performance.now()<deadline)await new Promise(r=>setTimeout(r,20));
if(!navigator.serviceWorker.controller)throw Error('ControllerMissing');
const nonce=crypto.randomUUID();const message=new Promise((resolve,reject)=>{timer=setTimeout(()=>reject(Error('SWTimeout')),8000);
listener=e=>{if(e.data?.ownSW===nonce&&e.source?.scriptURL===new URL('/owned-sw.js?token='+own.token,own.a).href){clearTimeout(timer);resolve(e.data);}};
navigator.serviceWorker.addEventListener('message',listener);});
const http=await(await fetch(own.a+'/identity?token='+own.token+'&operation=service-worker&nonce='+nonce,{cache:'no-store'})).json();
const sw=await message;navigator.serviceWorker.removeEventListener('message',listener);listener=null;
rows.push({operation:'service-worker',nonce,js:sw.js,http});
const unregistered=await registration.unregister();registration=null;
await read('negative-language',own.a,'/identity',{'Accept-Language':'xx'});
await fetch('/result?token='+own.token,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({rows,unregistered,crossWarm:true,secureContext:isSecureContext})});
}catch(error){await fetch('/result?token='+own.token,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({error:'OwnedProbeIncomplete',stage,errorClass:error.name,rows})}).catch(()=>{});}
finally{clearTimeout(timer);if(listener)removeEventListener('message',listener);if(registration)await registration.unregister();iframe?.remove();}})();`;
}

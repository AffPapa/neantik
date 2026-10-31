addEventListener('install', e => e.waitUntil(skipWaiting()));
addEventListener('activate', e => e.waitUntil(clients.claim()));
addEventListener('fetch', e => {
 const u=new URL(e.request.url);
 if(u.origin!==location.origin||u.pathname!=='/identity'||u.searchParams.get('via')!=='sw-controlled')return;
 e.respondWith((async()=>{
  const response=await fetch(e.request);
  const client=await clients.get(e.clientId);
  if(client)client.postMessage({ownInterceptedNonce:u.searchParams.get('requestNonce'),scriptURL:location.href,requestURL:e.request.url});
  return response;
 })());
});

(async()=>{
 const js={userAgent:navigator.userAgent,languages:Array.from(navigator.languages),deviceMemory:navigator.deviceMemory,hints:await navigator.userAgentData.getHighEntropyValues(['architecture','bitness','platformVersion','fullVersionList'])};
 const baselineNonce=crypto.randomUUID(),controlledNonce=crypto.randomUUID();
 const baseline=await(await fetch('/identity?via=baseline&requestNonce='+baselineNonce,{cache:'no-store'})).json();
 const expectedWorker=new URL('/owned-identity-sw.js',location.href).href;
 let registration,listener,timer;
 try{
  registration=await navigator.serviceWorker.register('/owned-identity-sw.js',{scope:'/',updateViaCache:'none'});
  await navigator.serviceWorker.ready;
  const deadline=performance.now()+8000;
  while(navigator.serviceWorker.controller?.scriptURL!==expectedWorker&&performance.now()<deadline)await new Promise(ok=>setTimeout(ok,20));
  if(navigator.serviceWorker.controller?.scriptURL!==expectedWorker)throw Error('OwnControllerTimeout');
  const eventPromise=new Promise((resolve,reject)=>{
   timer=setTimeout(()=>reject(Error('OwnInterceptTimeout')),8000);
   listener=e=>{if(e.data?.ownInterceptedNonce===controlledNonce){clearTimeout(timer);resolve({data:e.data,sourceScriptURL:e.source?.scriptURL??null});}};
   navigator.serviceWorker.addEventListener('message',listener);
  });
  const controlled=await(await fetch('/identity?via=sw-controlled&requestNonce='+controlledNonce,{cache:'no-store'})).json();
  const interception=await eventPromise;
  const controller={scriptURL:navigator.serviceWorker.controller.scriptURL,state:navigator.serviceWorker.controller.state};
  const unregistered=await registration.unregister();registration=null;
  const remainingRegistrations=(await navigator.serviceWorker.getRegistrations()).length;
  return {kind:'page-controlled-sw-http-identity',js,baseline:{http:baseline,requestNonce:baselineNonce},controlled:{http:controlled,requestNonce:controlledNonce},interception,controller,expectedWorker,unregistered,remainingRegistrations,limitations:['Owned loopback HTTP Accept-CH page pass-through ServiceWorker only; TLS/cross-origin/proxy route/final manager separate.']};
 }finally{
  clearTimeout(timer);if(listener)navigator.serviceWorker.removeEventListener('message',listener);
  if(registration)await registration.unregister();
 }
})()

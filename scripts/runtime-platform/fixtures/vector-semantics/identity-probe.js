(async()=>{
 const js={userAgent:navigator.userAgent,languages:Array.from(navigator.languages),deviceMemory:navigator.deviceMemory,hints:await navigator.userAgentData.getHighEntropyValues(['architecture','bitness','platformVersion','fullVersionList'])};
 const direct=await(await fetch('/identity?via=page')).json(),redirect=await(await fetch('/identity-redirect')).json();
 let worker;try{worker=await new Promise((resolve,reject)=>{const w=new Worker('/identity-worker.js');const timer=setTimeout(()=>{w.terminate();reject(new Error('OwnWorkerTimeout'));},5000);w.onmessage=e=>{clearTimeout(timer);w.terminate();resolve(e.data);};w.onerror=()=>{clearTimeout(timer);w.terminate();reject(new Error('OwnWorkerError'));};w.postMessage('own');});}catch(e){worker={error:e.name};}
 return {kind:'http-js-identity',js,page:{js,http:direct},redirect:{js,http:redirect},worker,limitations:['Same-origin HTTP loopback Accept-CH/redirect and DedicatedWorker only; TLS/cross-origin/SW paths separate gates.']};
})()

// Only own font operations. Handles remain live until independent confirmation.
(async()=>{
  const config=globalThis.OWN_FONT_CONTEXT_CONFIG,cleanups=[];
  const report={schemaVersion:1,nonce:config.nonce,results:[],error:null};
  const fresh=()=>Array.from(crypto.getRandomValues(new Uint8Array(16)),x=>x.toString(16).padStart(2,'0')).join('');
  const url=(route,extra={})=>config.origin+route+'?'+new URLSearchParams({nonce:config.nonce,...extra});
  const bounded=async(promise,ms=15000)=>{let timer;try{return await Promise.race([promise,new Promise((_,reject)=>timer=setTimeout(()=>reject(Error('OwnContextTimeout')),ms))]);}finally{clearTimeout(timer);}};
  const record=async(name,operation)=>{
    const contextNonce=fresh(),row={name,created:false,contextNonce,error:null};report.results.push(row);
    try {
      const value=await bounded(operation(contextNonce));
      if(value.contextNonce!==contextNonce)throw Error('OwnContextNonceMismatch');
      Object.assign(row,{created:true,value});
      const response=await bounded(fetch(url('/confirm',{name,contextNonce})));
      if(!response.ok)throw Error('OwnContextConfirmHTTP');row.lifecycleCreation=await response.json();
      if(!row.lifecycleCreation.confirmed||!row.lifecycleCreation.uniqueContext)throw Error('OwnContextUnconfirmed');
    }catch(error){row.error={kind:error.name,message:error.message==='OwnContextTimeout'?'timeout':'owned-context-failure'};throw error;}
  };
  const realmConfig=contextNonce=>({nonce:config.nonce,contextNonce,fontURL:url('/canary.ttf'),ahemURL:url('/ahem.woff2')});
  const ownWorker=async(shared,contextNonce)=>{
    const worker=shared?new SharedWorker(url('/shared.js'),contextNonce):new Worker(url('/dedicated.js'));
    const port=shared?worker.port:worker;
    cleanups.push(async()=>{
      try {
        await bounded(new Promise((resolve,reject)=>{
          port.onmessage=e=>e.data?.ownShutdown===contextNonce?resolve():reject(Error('OwnShutdownMismatch'));
          port.postMessage({shutdown:true,contextNonce});
        }),2000);
      }finally{if(shared)port.close();else worker.terminate();}
    });
    return await new Promise((resolve,reject)=>{
      port.onmessage=e=>e.data?.error?reject(Error('OwnWorkerCapture')):resolve(e.data);
      worker.onerror=()=>reject(Error('OwnWorkerError'));if(shared)port.start();port.postMessage(realmConfig(contextNonce));
    });
  };
  const frame=async(name,contextNonce)=>{
    const iframe=document.createElement('iframe'),foreign=name==='cross-origin OOPIF';let listener;
    cleanups.push(()=>iframe.remove());
    const expectedOrigin=foreign?config.crossOrigin:config.origin;
    const pending=new Promise((resolve,reject)=>{
      listener=e=>{
        if(e.source!==iframe.contentWindow||e.data?.kind!=='own-font-frame'||e.data?.contextNonce!==contextNonce)return;
        if(e.origin!==expectedOrigin||e.data.error){reject(Error('OwnFrameCapture'));return;}
        resolve(e.data.value);
      };addEventListener('message',listener);
    });
    try {
      if(name==='about:blank iframe'||name==='srcdoc iframe') {
        const response=await fetch(url('/frame',{name,contextNonce}));if(!response.ok)throw Error('OwnFrameHTTP');const html=await response.text();
        if(name==='srcdoc iframe'){iframe.srcdoc=html;document.body.append(iframe);}
        else {
          await bounded(new Promise(resolve=>{iframe.onload=resolve;iframe.src='about:blank';document.body.append(iframe);}));
          // document.open/write changes an about:blank URL to its creator URL.
          // Import only the three fixed fixture scripts, preserving this realm.
          const parsed=new DOMParser().parseFromString(html,'text/html'),scripts=[...parsed.querySelectorAll('script')];
          if(scripts.length!==3)throw Error('OwnBlankScripts');
          for(const source of scripts){
            const script=iframe.contentDocument.createElement('script');
            if(source.hasAttribute('src')){
              const target=new URL(source.getAttribute('src'));if(target.origin!==config.origin||!['/realm.js','/generic.js'].includes(target.pathname)||target.searchParams.get('nonce')!==config.nonce)throw Error('OwnBlankScriptURL');
              await bounded(new Promise((resolve,reject)=>{script.onload=resolve;script.onerror=()=>reject(Error('OwnBlankScriptLoad'));script.src=target.href;iframe.contentDocument.body.append(script);}));
            }else{script.textContent=source.textContent;iframe.contentDocument.body.append(script);}
          }
        }
      }else {iframe.src=(foreign?config.crossOrigin:config.origin)+'/frame?'+new URLSearchParams({nonce:config.nonce,name,contextNonce});document.body.append(iframe);}
      return await bounded(pending);
    }finally{removeEventListener('message',listener);}
  };
  try {
    await record('page',async contextNonce=>{
      globalThis.__OWN_REALM_NONCE=contextNonce;
      return {contextNonce,font:await runOwnFontPolicyRealm(realmConfig(contextNonce)),generics:await runOwnGenericFontRealm(config.nonce)};
    });
    await record('DedicatedWorker',contextNonce=>ownWorker(false,contextNonce));
    await record('SharedWorker',contextNonce=>ownWorker(true,contextNonce));
    await record('ServiceWorker',async contextNonce=>{
      let registration=null;
      cleanups.push(async()=>{if(registration&&!await registration.unregister())throw Error('OwnServiceUnregister');});
      registration=await navigator.serviceWorker.register(url('/service.js'),{scope:'/sw-fixture/'});
      const worker=registration.active||registration.installing||registration.waiting;if(!worker)throw Error('OwnServiceMissing');
      if(worker.state!=='activated')await new Promise((resolve,reject)=>{
        const listen=()=>{if(worker.state==='activated'){worker.removeEventListener('statechange',listen);resolve();}else if(worker.state==='redundant'){worker.removeEventListener('statechange',listen);reject(Error('OwnServiceRedundant'));}};
        worker.addEventListener('statechange',listen);listen();
      });
      const channel=new MessageChannel();cleanups.push(()=>channel.port1.close());
      return await new Promise((resolve,reject)=>{channel.port1.onmessage=e=>e.data?.error?reject(Error('OwnServiceCapture')):resolve(e.data);worker.postMessage(realmConfig(contextNonce),[channel.port2]);});
    });
    await record('AudioWorklet',async contextNonce=>{
      const context=new OfflineAudioContext(1,128,44100);let node=null;
      cleanups.push(()=>{node?.port.close();node?.disconnect();});
      await context.audioWorklet.addModule(url('/worklet.js',{contextNonce}));
      node=new AudioWorkletNode(context,'own-font-scope');
      const capture=new Promise((resolve,reject)=>{node.port.onmessage=e=>resolve(e.data);node.onprocessorerror=()=>reject(Error('OwnWorkletProcessor'));});
      node.connect(context.destination);const rendering=context.startRendering();
      const value=await capture,rendered=await rendering,samples=Array.from(rendered.getChannelData(0));
      return {...value,processing:{frames:samples.length,allQuarter:samples.every(x=>x===0.25),sampleRate:rendered.sampleRate}};
    });
    for(const name of ['same-origin iframe','about:blank iframe','srcdoc iframe','cross-origin OOPIF'])await record(name,contextNonce=>frame(name,contextNonce));
  }catch(error){report.error={kind:error.name,message:'owned-font-context-stage-incomplete'};}
  await fetch(url('/result'),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(report)});
  // Parent observes all contexts still live as a real negative control before
  // allowing shutdown. Cleanup requests alone are not destruction receipts.
  const end=Date.now()+30000;let allowed=false;
  while(Date.now()<end){const phase=await (await fetch(url('/phase'))).json();if(phase.teardown){allowed=true;break;}await new Promise(resolve=>setTimeout(resolve,100));}
  const cleanup={nonce:config.nonce,teardownAllowed:allowed,completed:0,errors:[]};
  for(const close of cleanups.reverse())try{await bounded(Promise.resolve().then(close),2500);cleanup.completed++;}catch(error){cleanup.errors.push(error.name);}
  await fetch(url('/closed'),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(cleanup)});
})().catch(()=>{});

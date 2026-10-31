// Own CDP evidence recorder. A cleanup call alone is not destruction evidence.
export class OwnContextLifecycleRecorder {
 constructor(browser,command,origins){
  this.browser=browser;this.command=command;this.origins=origins;
  this.targets=new Map();this.contexts=new Map();this.receipts=new Map();
  this.pending=new Set();this.failures=[];this.attaching=new Set();
  this.listener=e=>{try{this.event(JSON.parse(e.data));}catch{this.failures.push('recorder-event');}};
  browser.addEventListener('message',this.listener);
 }
 own(url){return this.origins.some(origin=>url===origin+'/'||url.startsWith(origin+'/'));}
 async start(pageId){
  await this.command(this.browser,'Target.setDiscoverTargets',{discover:true});
  await this.attach({targetId:pageId,type:'page',url:this.origins[0]+'/'});
 }
 async attach(info){
  if(this.attaching.has(info.targetId))return;
  this.attaching.add(info.targetId);
  const attached=await this.command(this.browser,'Target.attachToTarget',{targetId:info.targetId,flatten:true});
  const t={...info,sessionId:attached.sessionId,destroyed:false};this.targets.set(info.targetId,t);
  await this.command(this.browser,'Runtime.enable',{},t.sessionId);
  if(info.type==='shared_worker')await this.command(this.browser,'Inspector.enable',{},t.sessionId);
  if(info.type==='page'){
   await this.command(this.browser,'Page.enable',{},t.sessionId);
   await this.command(this.browser,'Target.setAutoAttach',{autoAttach:true,waitForDebuggerOnStart:false,flatten:true},t.sessionId);
   await this.command(this.browser,'ServiceWorker.enable',{},t.sessionId);
  }
 }
 schedule(p){this.pending.add(p);p.catch(()=>this.failures.push('target-attach')).finally(()=>this.pending.delete(p));}
 event(d){
  if(d.method==='Target.targetCreated'||d.method==='Target.targetInfoChanged'){
   const t=d.params.targetInfo;
   if(this.own(t.url)&&['worker','shared_worker','service_worker','worklet','iframe'].includes(t.type))this.schedule(this.attach(t));
  }
  if(d.method==='Target.attachedToTarget'){
   const info=d.params.targetInfo;
   if(this.own(info.url)&&['worker','shared_worker','service_worker','worklet','iframe'].includes(info.type)&&!this.attaching.has(info.targetId)){
    this.attaching.add(info.targetId);this.targets.set(info.targetId,{...info,sessionId:d.params.sessionId,destroyed:false});
    this.schedule(this.command(this.browser,'Runtime.enable',{},d.params.sessionId));
   }
  }
  if(d.method==='Target.detachedFromTarget'){
   const t=[...this.targets.values()].find(t=>t.sessionId===d.params.sessionId);if(t)t.detached=true;
  }
  if(d.method==='Inspector.targetCrashed'){
   const t=[...this.targets.values()].find(t=>t.sessionId===d.sessionId);if(t)t.workerDestroyedNotification=true;
  }
  if(d.method==='Inspector.detached'){
   const t=[...this.targets.values()].find(t=>t.sessionId===d.sessionId);if(t)t.inspectorDetachReason=d.params.reason;
  }
  if(d.method==='Target.targetDestroyed'){
   const t=this.targets.get(d.params.targetId);if(t)t.destroyed=true;
  }
  if(d.method==='Runtime.executionContextCreated'){
   const c=d.params.context;this.contexts.set(d.sessionId+':'+c.id,{sessionId:d.sessionId,...c,destroyed:false});
  }
  if(d.method==='Runtime.executionContextDestroyed'){
   const c=this.contexts.get(d.sessionId+':'+d.params.executionContextId);if(c)c.destroyed=true;
  }
  if(d.method==='Runtime.executionContextsCleared'){
   for(const c of this.contexts.values())if(c.sessionId===d.sessionId){c.destroyed=true;c.cleared=true;}
  }
  if(d.method==='ServiceWorker.workerVersionUpdated'){
   for(const v of d.params.versions){
    if(!this.own(v.scriptURL))continue;
    this.versions??=new Map();const old=this.versions.get(v.versionId);this.versions.set(v.versionId,{...v,wasRunning:old?.wasRunning||v.runningStatus==='running'});
   }
  }
 }
 async confirm(name,nonce){
  const until=Date.now()+4000;
  while(Date.now()<until){
   await Promise.allSettled([...this.pending]);
   for(const c of [...this.contexts.values()]){
    if(c.destroyed||c.auxData?.isDefault===false)continue;
    let r;try{r=await this.command(this.browser,'Runtime.evaluate',{expression:'globalThis.__OWN_REALM_NONCE??null',contextId:c.id,returnByValue:true},c.sessionId);}catch{continue;}
    if(r.result?.value!==nonce)continue;
    const target=[...this.targets.values()].find(t=>t.sessionId===c.sessionId);
    if(!c.uniqueId||!target)continue;
    const receipt={name,nonce,context:c,target,versionId:null};
    if(name==='ServiceWorker')receipt.versionId=[...(this.versions?.values()??[])].find(v=>v.scriptURL===target.url&&v.wasRunning)?.versionId??null;
    this.receipts.set(name,receipt);return {confirmed:true,uniqueContext:true,targetType:target.type};
   }
   await new Promise(ok=>setTimeout(ok,50));
  }
  return {confirmed:false,reason:'own-context-not-independently-observed'};
 }
 async finish(pageId){
  const sw=this.receipts.get('ServiceWorker');
  if(sw?.versionId){
   await this.command(this.browser,'ServiceWorker.stopWorker',{versionId:sw.versionId},[...this.targets.values()].find(t=>t.type==='page').sessionId);
   // The ServiceWorker domain belongs to this page session. Closing it before
   // the asynchronous stopped notification arrives loses independent evidence.
   const stoppedDeadline=Date.now()+5000;
   while(Date.now()<stoppedDeadline&&this.versions?.get(sw.versionId)?.runningStatus!=='stopped')await new Promise(ok=>setTimeout(ok,50));
  }
  await this.command(this.browser,'Target.closeTarget',{targetId:pageId});
  const until=Date.now()+5000;
  while(Date.now()<until){if(this.summary().every(x=>x.terminated))break;await new Promise(ok=>setTimeout(ok,50));}
  return {receipts:this.summary(),serviceWorkerVersions:[...(this.versions?.values()??[])].map(v=>({runningStatus:v.runningStatus,status:v.status,wasRunning:v.wasRunning,owned:this.own(v.scriptURL)})),recorderErrors:this.failures,targetDiagnostics:[...this.targets.values()].map(t=>({type:t.type,owned:this.own(t.url),destroyed:t.destroyed,detached:!!t.detached,inspectorDetachReason:t.inspectorDetachReason??null,contexts:[...this.contexts.values()].filter(c=>c.sessionId===t.sessionId).map(c=>({default:c.auxData?.isDefault??null,destroyed:c.destroyed,unique:!!c.uniqueId}))})),scope:'recorded context destruction/target shutdown; not physical shared backing-thread destruction'};
 }
 summary(){return [...this.receipts.values()].map(r=>{
  const sw=r.versionId?this.versions?.get(r.versionId):null;
  const terminated=r.name==='ServiceWorker'?sw?.runningStatus==='stopped':r.context.destroyed||r.target.destroyed||(r.name==='SharedWorker'&&r.target.workerDestroyedNotification===true);
  return {name:r.name,confirmed:true,uniqueContext:true,targetType:r.target.type,terminated:!!terminated,versionBound:r.name==='ServiceWorker'?!!r.versionId:null,mechanism:r.name==='ServiceWorker'?(terminated?'observed-service-worker-stopped':'not-observed'):r.context.destroyed?(r.context.cleared?'session-contexts-cleared':'context-destroyed'):r.target.destroyed?'target-destroyed':r.name==='SharedWorker'&&r.target.workerDestroyedNotification?'shared-worker-host-destroyed-notification':'not-observed'};
 });}
 dispose(){this.browser.removeEventListener('message',this.listener);}
}

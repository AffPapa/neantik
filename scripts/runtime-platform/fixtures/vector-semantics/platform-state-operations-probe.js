(async()=>{
 const result={kind:'platform-state-and-memory-operations',errors:[],limitations:[
  'Observed native connection state is an estimate, not a measured proxy RTT or route.',
  'Battery events require a real state change; this fixture does not change system power.',
  'Device memory, JavaScript heap and storage quota are different metrics.',
  'No camera/microphone enumeration, capture or system voice getter is invoked.'
 ]};
 async function bounded(p,stage){let t;try{return await Promise.race([p,new Promise((_,reject)=>{t=setTimeout(()=>reject(Error(stage+'Timeout')),5000);})]);}finally{clearTimeout(t);}}
 const connection=navigator.connection;
 if(!connection)result.connection={status:'unavailable'};
 else{
  const snapshot=()=>({effectiveType:connection.effectiveType,rtt:connection.rtt,downlink:connection.downlink,saveData:connection.saveData});
  result.connection={status:'observed',samples:[snapshot()],events:0};
  const listener=()=>result.connection.events++;connection.addEventListener('change',listener);
  await new Promise(resolve=>setTimeout(resolve,50));result.connection.samples.push(snapshot());connection.removeEventListener('change',listener);
 }
 if(typeof navigator.getBattery!=='function')result.battery={status:'unavailable'};
 else{
  try{
   const a=await bounded(navigator.getBattery(),'Battery'),b=await bounded(navigator.getBattery(),'BatteryRepeat');
   const validTime=value=>(Number.isFinite(value)&&value>=0)||value===Infinity;
   result.battery={status:'observed',sameObject:a===b,chargingBoolean:typeof a.charging==='boolean',levelInRange:Number.isFinite(a.level)&&a.level>=0&&a.level<=1,chargingTimeValid:validTime(a.chargingTime),dischargingTimeValid:validTime(a.dischargingTime),listenerAPI:typeof a.addEventListener==='function'};
  }catch{result.battery={status:'error'};result.errors.push('BatteryObservationFailed');}
 }
 try{
  const values=Array.from({length:2048},(_,i)=>i*13+3);
  result.heap={allocatedElements:values.length,checksum:values.reduce((a,b)=>a+b,0),status:'observed'};
  const memory=performance.memory;
  if(memory)result.heap.nativeHeap={status:'observed',used:memory.usedJSHeapSize,total:memory.totalJSHeapSize,limit:memory.jsHeapSizeLimit};
  else result.heap.nativeHeap={status:'unavailable'};
  result.deviceMemory=typeof navigator.deviceMemory==='number'?{status:'observed',value:navigator.deviceMemory}:{status:'unavailable'};
 }catch{result.errors.push('HeapOperationFailed');}
 const databaseName='own-platform-state-fixture';let database;
 try{
  const request=indexedDB.open(databaseName,1);
  const opened=new Promise((resolve,reject)=>{request.onupgradeneeded=()=>request.result.createObjectStore('own');request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(Error('OpenFailed'));request.onblocked=()=>reject(Error('OpenBlocked'));});
  database=await bounded(opened,'IDBOpen');
  const bytes=new Uint8Array(1024*1024);for(let i=0;i<bytes.length;i++)bytes[i]=(i*7+19)%256;
  const transaction=database.transaction('own','readwrite',{durability:'strict'});
  const committed=new Promise((resolve,reject)=>{transaction.oncomplete=resolve;transaction.onerror=()=>reject(Error('CommitFailed'));transaction.onabort=()=>reject(Error('CommitAborted'));});
  transaction.objectStore('own').put(bytes,'value');await bounded(committed,'IDBCommit');
  const read=database.transaction('own','readonly').objectStore('own').get('value');
  const retrieved=await bounded(new Promise((resolve,reject)=>{read.onsuccess=()=>resolve(read.result);read.onerror=()=>reject(Error('ReadFailed'));}),'IDBRead');
  const digest=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',retrieved)),b=>b.toString(16).padStart(2,'0')).join('');
  const estimate=await bounded(navigator.storage.estimate(),'Estimate');
  result.storage={status:'observed',strictCommitCompleted:true,retrievedBytes:retrieved.byteLength,retrievedSHA256:digest,quotaCoversOwnBytes:Number.isFinite(estimate.quota)&&estimate.quota>=bytes.length,usageValid:Number.isFinite(estimate.usage)&&estimate.usage>=0};
 }catch{result.storage={status:'error'};result.errors.push('StorageOperationFailed');}
 finally{
  database?.close();const deleted=indexedDB.deleteDatabase(databaseName);
  try{await bounded(new Promise((resolve,reject)=>{deleted.onsuccess=resolve;deleted.onerror=()=>reject(Error('DeleteFailed'));deleted.onblocked=()=>reject(Error('DeleteBlocked'));}),'IDBDelete');result.storage??={status:'error'};result.storage.databaseDeleted=true;}
  catch{result.errors.push('StorageCleanupFailed');}
 }
 result.permissions=[];
 for(const name of ['camera','microphone']){
  try{const state=await bounded(navigator.permissions.query({name}),'Permission');result.permissions.push({name,status:'observed',state:state.state});}
  catch{result.permissions.push({name,status:'unavailable'});}
 }
 // Avoid speechSynthesis's getter: on macOS it connects the native voice
 // service. Descriptor presence alone is explicitly not voice behavior proof.
 let prototype=window,descriptor;
 while(prototype&&!descriptor){descriptor=Object.getOwnPropertyDescriptor(prototype,'speechSynthesis');prototype=Object.getPrototypeOf(prototype);}
 result.speechDescriptor={present:!!descriptor,nativeVoices:'not_observed'};
 return result;
})()

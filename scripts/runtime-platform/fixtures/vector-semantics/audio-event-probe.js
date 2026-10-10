(async()=>{
 const result={kind:'audio-error-event-semantics',schemaVersion:1,cases:[],errors:[]};
 for(const [failure,listenerMode] of [['constructor','replace'],['process','replace'],['missing-process','replace'],['process','null'],['process','remove']]){
  let timer;try{
   const context=new OfflineAudioContext(1,1024,48000);
   const body=failure==='constructor'?"constructor(){super();throw new Error('owned constructor failure');}process(){return true;}":failure==='process'?"process(){throw new Error('owned process failure');}":'';
   const url=URL.createObjectURL(new Blob([`class OwnError extends AudioWorkletProcessor{${body}}registerProcessor('own-error',OwnError);`],{type:'text/javascript'}));try{await context.audioWorklet.addModule(url);}finally{URL.revokeObjectURL(url);}
   const node=new AudioWorkletNode(context,'own-error',{numberOfInputs:0,numberOfOutputs:1,outputChannelCount:[1]});let oldCalls=0,attributeCalls=0,listenerCalls=0,legacyCalls=0,attributeEvent=null,listenerEvent=null,native=null;
   const serialize=e=>({type:e.type,errorEvent:e instanceof ErrorEvent,trusted:e.isTrusted,bubbles:e.bubbles,cancelable:e.cancelable,messagePresent:typeof e.message==='string'&&e.message.length>0});
   let resolveReceipt;const receipt=new Promise((resolve,reject)=>{resolveReceipt=resolve;timer=setTimeout(()=>reject(new Error('AudioEventTimeout')),5000);});
   const handler=e=>{attributeCalls++;attributeEvent=e;native=serialize(e);clearTimeout(timer);resolveReceipt();};
   const listener=e=>{listenerCalls++;listenerEvent=e;native=serialize(e);clearTimeout(timer);resolveReceipt();};
   node.onprocessorerror=()=>oldCalls++;node.onprocessorerror=handler;let getterMatches=node.onprocessorerror===handler;
   if(listenerMode==='null'){node.onprocessorerror=null;getterMatches=node.onprocessorerror===null;}
   node.addEventListener('processorerror',listener);if(listenerMode==='remove')node.removeEventListener('processorerror',listener);
   node.addEventListener('error',e=>{legacyCalls++;native=serialize(e);clearTimeout(timer);resolveReceipt();});
   node.connect(context.destination);let rendered;
   try{[rendered]=await Promise.all([context.startRendering(),receipt]);await new Promise(resolve=>setTimeout(resolve,0));}
   finally{clearTimeout(timer);}
   const nativeMetadata=native;const beforeSynthetic=attributeCalls;node.dispatchEvent(new ErrorEvent('error',{message:'owned synthetic negative event'}));const syntheticErrorInvokedAttribute=attributeCalls!==beforeSynthetic;
   const zero=rendered.getChannelData(0).every(x=>x===0);
   node.port.close();node.disconnect();result.cases.push({failure,listenerMode,renderCompleted:true,state:context.state,outputLength:rendered.length,silence:zero,getterMatches,oldCalls,attributeCallsBeforeSynthetic:beforeSynthetic,listenerCalls,legacyCallsBeforeSynthetic:legacyCalls-1,sameNativeEvent:listenerMode==='replace'?attributeEvent===listenerEvent:true,native:nativeMetadata,syntheticErrorInvokedAttribute,portClosed:true,disconnected:true});
  }catch(e){clearTimeout(timer);result.errors.push({failure,listenerMode,error:e.message==='AudioEventTimeout'?'AudioEventTimeout':e.name});}
 }
 return result;
})()

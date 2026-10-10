(async()=>{
 const result={kind:'audio-worklet-lifetime',schemaVersion:1,errors:[],cases:[]},length=8192,rate=48000;
 for(const mode of ['generator-first','generator-repeat','throws']){
  try{
   const context=new OfflineAudioContext(2,length,rate);
   const code=`class OwnLife extends AudioWorkletProcessor{constructor(){super();this.calls=0;}process(inputs,outputs){this.calls++;if(${mode==='throws'}){throw new Error('owned deliberate processor failure');}const out=outputs[0];for(let ch=0;ch<out.length;ch++)for(let i=0;i<out[ch].length;i++)out[ch][i]=((currentFrame+i)%32/32-0.5)*(ch===0?1:4);if(currentFrame+out[0].length>=4096){this.port.postMessage({terminal:true,calls:this.calls,frames:currentFrame+out[0].length});return false;}return true;}}registerProcessor('own-lifetime',OwnLife);`;
   const url=URL.createObjectURL(new Blob([code],{type:'text/javascript'}));try{await context.audioWorklet.addModule(url);}finally{URL.revokeObjectURL(url);}
   const node=new AudioWorkletNode(context,'own-lifetime',{numberOfInputs:0,numberOfOutputs:1,outputChannelCount:[2]});let message=null,processorErrors=0,processorListenerErrors=0,processorEventTypes=[],timer;
   const receipt=new Promise((resolve,reject)=>{timer=setTimeout(()=>reject(new Error('WorkletReceiptTimeout')),5000);node.port.onmessage=e=>{if(e.data?.terminal){message=e.data;clearTimeout(timer);resolve();}};node.addEventListener('processorerror',e=>{processorListenerErrors++;processorEventTypes.push(e.type);});node.onprocessorerror=e=>{processorErrors++;processorEventTypes.push(e.type);clearTimeout(timer);resolve();};});
   node.connect(context.destination);let buffer;try{[buffer]=await Promise.all([context.startRendering(),receipt]);}finally{clearTimeout(timer);node.port.close();node.disconnect();}
   const channels=[];for(let ch=0;ch<2;ch++){const a=buffer.getChannelData(ch);let maxError=0,tailMax=0;for(let i=0;i<a.length;i++){const expected=mode==='throws'||i>=4096?0:(i%32/32-0.5)*(ch===0?1:4);maxError=Math.max(maxError,Math.abs(a[i]-expected));if(i>=4096)tailMax=Math.max(tailMax,Math.abs(a[i]));}channels.push({channel:ch,length:a.length,maxError,tailMax,firstSamples:Array.from(a.slice(0,32))});}
   result.cases.push({mode,renderCompleted:true,state:context.state,processorErrors,processorListenerErrors,processorEventTypes,terminal:message,channels,portClosed:true,disconnected:true});
  }catch(e){result.errors.push({mode,error:e.message==='WorkletReceiptTimeout'?'WorkletReceiptTimeout':e.name});}
 }
 return result;
})()

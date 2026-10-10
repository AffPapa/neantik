// Owned known signals. Completed rendering and worklet terminal receipts are separate gates.
(async () => {
 const result={kind:'audio-operations',schemaVersion:1,errors:[],analysers:[],worklet:null,invalid:[]};
 const rate=48000,length=8192,fft=2048;
 const sample=(signal,i)=>signal==='silence'?0:signal==='positive-dc'?2:signal==='negative-dc'?-2:0.5*Math.sin(2*Math.PI*32*i/fft);
 const tail=(values,n=16)=>Array.from(values.slice(-n));
 for(const signal of ['silence','positive-dc','negative-dc','sine']){
  let phase='create';try{
   const c=new OfflineAudioContext(1,length,rate),b=c.createBuffer(1,length,rate);
   for(let channel=0;channel<1;channel++){const a=b.getChannelData(channel);for(let i=0;i<length;i++)a[i]=sample(signal,i)*(channel===0?1:0.5);}
   const source=c.createBufferSource();source.buffer=b;
   const analyser=c.createAnalyser();analyser.fftSize=fft;analyser.smoothingTimeConstant=0;analyser.minDecibels=-100;analyser.maxDecibels=-30;
   source.connect(analyser);analyser.connect(c.destination);source.start();phase='render';const rendered=await c.startRendering();
   const time=new Float32Array(fft),repeat=new Float32Array(fft),byte=new Uint8Array(fft),freq=new Float32Array(fft/2),freqRepeat=new Float32Array(fft/2),byteFreq=new Uint8Array(fft/2);
   analyser.getFloatTimeDomainData(time);analyser.getFloatTimeDomainData(repeat);analyser.getByteTimeDomainData(byte);analyser.getFloatFrequencyData(freq);analyser.getFloatFrequencyData(freqRepeat);analyser.getByteFrequencyData(byteFreq);
   const finite=Array.from(freq).every(x=>Number.isFinite(x)||x===-Infinity);let peak=0;for(let i=1;i<freq.length;i++)if(freq[i]>freq[peak])peak=i;
   const channels=[];for(let channel=0;channel<1;channel++){const a=rendered.getChannelData(channel);let maxError=0;for(let i=0;i<a.length;i++)maxError=Math.max(maxError,Math.abs(a[i]-sample(signal,i)*(channel===0?1:0.5)));channels.push({channel,length:a.length,maxError,repeatEqual:a.every((x,i)=>x===rendered.getChannelData(channel)[i]),tail:tail(a)});}
   result.analysers.push({signal,renderCompleted:true,state:c.state,length:rendered.length,sampleRate:rendered.sampleRate,channels,floatTail:tail(time),byteTail:tail(byte),timeRepeat:time.every((x,i)=>x===repeat[i]),frequencyRepeat:freq.every((x,i)=>x===freqRepeat[i]),frequencyFiniteOrNegativeInfinity:finite,frequencyAllNegativeInfinity:freq.every(x=>x===-Infinity),byteFrequencyAllZero:byteFreq.every(x=>x===0),peakBin:peak,peakDB:Number.isFinite(freq[peak])?freq[peak]:null});
   source.disconnect();analyser.disconnect();
  }catch(e){result.errors.push({signal,phase,error:e.name});}
 }
 try{
  const c=new OfflineAudioContext(2,length,rate),b=c.createBuffer(2,length,rate);
  b.getChannelData(0).fill(0.25);b.getChannelData(1).fill(-0.5);
  const module=URL.createObjectURL(new Blob([`class OwnPass extends AudioWorkletProcessor{constructor(){super();this.calls=0;this.frames=0;}process(inputs,outputs){this.calls++;const input=inputs[0]||[],out=outputs[0]||[];for(let ch=0;ch<out.length;ch++){if(input[ch])out[ch].set(input[ch]);else out[ch].fill(0);}this.frames+=out[0]?.length||0;if(this.frames>=8192){this.port.postMessage({terminal:true,calls:this.calls,frames:this.frames,channels:out.length,realm:typeof AudioWorkletGlobalScope!=='undefined'? 'worklet':'processor',rate:sampleRate});return false;}return true;}}registerProcessor('own-pass-complete',OwnPass);`],{type:'text/javascript'}));
  try{await c.audioWorklet.addModule(module);}finally{URL.revokeObjectURL(module);}
  const source=c.createBufferSource();source.buffer=b;
  const node=new AudioWorkletNode(c,'own-pass-complete',{numberOfInputs:1,numberOfOutputs:1,outputChannelCount:[2],channelCount:2,channelCountMode:'explicit'});
  let timer;const terminal=new Promise((resolve,reject)=>{timer=setTimeout(()=>reject(new Error('WorkletTerminalTimeout')),5000);node.port.onmessage=e=>{if(e.data?.terminal){clearTimeout(timer);resolve(e.data);}};node.addEventListener('processorerror',()=>{clearTimeout(timer);reject(new Error('WorkletProcessorError'));},{once:true});});
  source.connect(node);node.connect(c.destination);source.start();let rendered,receipt;
  try{[rendered,receipt]=await Promise.all([c.startRendering(),terminal]);}finally{clearTimeout(timer);node.port.close();source.disconnect();node.disconnect();}
  const channels=[];for(let ch=0;ch<2;ch++){const data=rendered.getChannelData(ch);channels.push({channel:ch,length:data.length,maxError:Math.max(...Array.from(data,x=>Math.abs(x-(ch===0?0.25:-0.5))))});}
  result.worklet={moduleLoaded:true,renderCompleted:true,state:c.state,receipt,channels,outputLength:rendered.length,portClosed:true,nodesDisconnected:true};
  for(const [name,operation] of [['unknown-processor',()=>new AudioWorkletNode(c,'absent-owned-processor')],['zero-input-output',()=>new AudioWorkletNode(c,'own-pass-complete',{numberOfInputs:0,numberOfOutputs:0})]]){let error=null;try{operation();}catch(e){error=e.name;}result.invalid.push({name,error});}
 }catch(e){result.errors.push({phase:'worklet-completion',error:e.message==='WorkletTerminalTimeout'?'WorkletTerminalTimeout':e.name});}
 const c=new OfflineAudioContext(1,128,rate),a=c.createAnalyser();
 for(const [name,operation] of [['invalid-fft',()=>a.fftSize=100],['invalid-smoothing',()=>a.smoothingTimeConstant=2],['invalid-channels',()=>new OfflineAudioContext(0,128,rate)]]){let error=null;try{operation();}catch(e){error=e.name;}result.invalid.push({name,error});}
 return result;
})()

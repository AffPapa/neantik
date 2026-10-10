(async()=>{
 const bytes=await(await fetch('/own-ahem.woff2')).arrayBuffer();
 const digest=await crypto.subtle.digest('SHA-256',bytes),fontSHA256=Array.from(new Uint8Array(digest),x=>x.toString(16).padStart(2,'0')).join('');
 const font=new FontFace('OwnTestAhem',bytes);await font.load();document.fonts.add(font);await document.fonts.ready;
 const text='AAAAA',metrics=c=>{c.font='20px OwnTestAhem';const m=c.measureText(text);return Object.fromEntries(['width','actualBoundingBoxLeft','actualBoundingBoxRight','actualBoundingBoxAscent','actualBoundingBoxDescent','fontBoundingBoxAscent','fontBoundingBoxDescent'].map(k=>[k,m[k]]));};
 const page=metrics(document.createElement('canvas').getContext('2d')),repeat=metrics(document.createElement('canvas').getContext('2d')),offscreen=metrics(new OffscreenCanvas(32,32).getContext('2d'));
 const source=`onmessage=async e=>{try{const f=new FontFace('OwnTestAhem',e.data);await f.load();fonts.add(f);const c=new OffscreenCanvas(32,32).getContext('2d');c.font='20px OwnTestAhem';const m=c.measureText('AAAAA');postMessage({fontLoaded:f.status==='loaded',metrics:Object.fromEntries(['width','actualBoundingBoxLeft','actualBoundingBoxRight','actualBoundingBoxAscent','actualBoundingBoxDescent','fontBoundingBoxAscent','fontBoundingBoxDescent'].map(k=>[k,m[k]]))});}catch(e){postMessage({error:e.name});}close();}`;
 const url=URL.createObjectURL(new Blob([source],{type:'text/javascript'})),w=new Worker(url);let worker,error=null;
 try{worker=await new Promise((ok,fail)=>{const timer=setTimeout(()=>fail(Error('WorkerTimeout')),5000);w.onmessage=e=>{clearTimeout(timer);ok(e.data);};w.onerror=()=>{clearTimeout(timer);fail(Error('WorkerError'));};w.postMessage(bytes);});}catch(e){error=e.message;}finally{w.terminate();URL.revokeObjectURL(url);document.fonts.delete(font);}
 return {kind:'controlled-font-metrics',fontSHA256,fontLoaded:font.status==='loaded',text,px:20,page,repeat,offscreen,worker,error};
})()

// Independent realm operations. A missing operation is never a coherence PASS.
(async()=>{
 const basic=await (BASIC_REALM_CAPTURE);
 const operations={canvas:{available:typeof OffscreenCanvas==='function'},webgl:[],dom:{available:typeof document==='object'},network:{available:typeof fetch==='function'},audio:{available:typeof OfflineAudioContext==='function'},errors:[]};
 const attempt=async(key,fn)=>{try{await fn();}catch(e){operations.errors.push({key,error:e.name});}};
 if(operations.canvas.available)await attempt('canvas',async()=>{
  const c=new OffscreenCanvas(4,3),g=c.getContext('2d',{willReadFrequently:true});if(!g)throw new Error('Canvas2DUnavailable');
  const read=(x,y,w,h)=>Array.from(g.getImageData(x,y,w,h).data);
  g.fillStyle='rgb(17,34,51)';g.fillRect(0,0,4,3);const solid=read(0,0,4,3),repeat=read(0,0,4,3),crop=read(1,1,2,1);
  g.clearRect(1,1,2,1);const cleared=read(0,0,4,3);g.putImageData(new ImageData(new Uint8ClampedArray([128,64,32,255]),1,1),2,1);const put=read(2,1,1,1);
  const png=await c.convertToBlob({type:'image/png'});const bytes=new Uint8Array(await png.arrayBuffer());const encoded={type:png.type,size:png.size,pngBase64:btoa(String.fromCharCode(...bytes)),decoded:null};
  if(typeof createImageBitmap==='function'){const image=await createImageBitmap(png);try{const check=new OffscreenCanvas(4,3);check.getContext('2d').drawImage(image,0,0);encoded.decoded=Array.from(check.getContext('2d').getImageData(0,0,4,3).data);}finally{image.close();}}
  const beforeResize=read(0,0,4,3);c.width=4;const resize=read(0,0,4,3);
  operations.canvas={available:true,solid,repeat,crop,cleared,put,encoded,beforeResize,resize};
 });
 if(operations.canvas.available)for(const kind of ['webgl','webgl2'])await attempt(kind,async()=>{
  const c=new OffscreenCanvas(3,2),g=c.getContext(kind,{antialias:false,preserveDrawingBuffer:true});if(!g){operations.webgl.push({kind,available:false});return;}
  g.clearColor(17/255,34/255,51/255,1);g.clear(g.COLOR_BUFFER_BIT);const read=(x,y,w,h)=>{const p=new Uint8Array(w*h*4);g.readPixels(x,y,w,h,g.RGBA,g.UNSIGNED_BYTE,p);return Array.from(p);};
  const solid=read(0,0,3,2),repeat=read(0,0,3,2),crop=read(1,0,1,2);g.enable(g.SCISSOR_TEST);g.scissor(1,0,1,1);g.clearColor(1,0,0,1);g.clear(g.COLOR_BUFFER_BIT);const scissor=read(0,0,3,2);g.disable(g.SCISSOR_TEST);
  const shader=(type,source)=>{const s=g.createShader(type);g.shaderSource(s,source);g.compileShader(s);if(!g.getShaderParameter(s,g.COMPILE_STATUS))throw new Error('ShaderCompileFailure');return s;};
  const v=shader(g.VERTEX_SHADER,kind==='webgl2'?'#version 300 es\nin vec2 p;void main(){gl_Position=vec4(p,0.,1.);}':'attribute vec2 p;void main(){gl_Position=vec4(p,0.,1.);}');
  const f=shader(g.FRAGMENT_SHADER,kind==='webgl2'?'#version 300 es\nprecision mediump float;out vec4 outColor;void main(){outColor=vec4(0.,1.,0.,1.);}':'precision mediump float;void main(){gl_FragColor=vec4(0.,1.,0.,1.);}');
  const program=g.createProgram();g.attachShader(program,v);g.attachShader(program,f);g.linkProgram(program);const linked=g.getProgramParameter(program,g.LINK_STATUS);if(!linked)throw new Error('ProgramLinkFailure');g.useProgram(program);const buffer=g.createBuffer();g.bindBuffer(g.ARRAY_BUFFER,buffer);g.bufferData(g.ARRAY_BUFFER,new Float32Array([-1,-1,3,-1,-1,3]),g.STATIC_DRAW);const loc=g.getAttribLocation(program,'p');g.enableVertexAttribArray(loc);g.vertexAttribPointer(loc,2,g.FLOAT,false,0,0);g.viewport(0,0,3,2);g.drawArrays(g.TRIANGLES,0,3);const draw=read(0,0,3,2),error=g.getError();
  const limits={maxTextureSize:g.getParameter(g.MAX_TEXTURE_SIZE),maxViewportDims:Array.from(g.getParameter(g.MAX_VIEWPORT_DIMS))};
  g.deleteBuffer(buffer);g.deleteProgram(program);g.deleteShader(v);g.deleteShader(f);
  operations.webgl.push({kind,available:true,solid,repeat,crop,scissor,draw,error,linked,limits});g.getExtension('WEBGL_lose_context')?.loseContext();
 });
 if(operations.dom.available)await attempt('dom',async()=>{
  await document.fonts.ready;const node=document.createElement('div');node.style.cssText='position:absolute;left:10px;top:20px;width:31px;height:19px;box-sizing:border-box';document.body.append(node);try{const a=node.getBoundingClientRect(),b=node.getBoundingClientRect(),r=node.getClientRects();operations.dom={available:true,box:{x:a.x,y:a.y,width:a.width,height:a.height},repeat:{x:b.x,y:b.y,width:b.width,height:b.height},rectCount:r.length,clientWidth:node.clientWidth,offsetWidth:node.offsetWidth};}finally{node.remove();}
 });
 if(operations.audio.available)await attempt('audio',async()=>{
  const context=new OfflineAudioContext(2,256,48000);const merger=context.createChannelMerger(2);for(let ch=0;ch<2;ch++){const source=context.createConstantSource();source.offset.value=ch===0?0.25:-0.5;source.connect(merger,0,ch);source.start();}merger.connect(context.destination);const rendered=await context.startRendering();const dc=[Array.from(rendered.getChannelData(0)),Array.from(rendered.getChannelData(1))];const quiet=await(new OfflineAudioContext(1,128,48000)).startRendering();operations.audio={available:true,length:rendered.length,channels:rendered.numberOfChannels,sampleRate:rendered.sampleRate,dc,silence:Array.from(quiet.getChannelData(0))};
 });
 if(operations.network.available)await attempt('network',async()=>{
  const url=basic.url==='about:blank'||basic.url==='about:srcdoc'?new URL('/identity?via=realm',document.baseURI).href:'/identity?via=realm';
  const requestNonce=crypto.randomUUID();const fullURL=new URL(url,typeof document==='object'?document.baseURI:location.href);fullURL.searchParams.set('realmNonce',basic.nonce);fullURL.searchParams.set('requestNonce',requestNonce);const response=await fetch(fullURL,{cache:'no-store',signal:AbortSignal.timeout(5000)});if(!response.ok)throw new Error('OwnEndpointFailure');const http=await response.json();operations.network={available:true,requestNonce,http};
 });
 return {...basic,operations};
})()

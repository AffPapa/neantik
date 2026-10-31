// Owned framebuffer reference; byte comparisons occur outside the browser.
(async()=>{
 const w=8,h=6,result={kind:'webgl-readback-semantics',schemaVersion:1,cases:[],errors:[]};
 for(const version of [1,2]){
  let phase='create';try{
   const canvas=document.createElement('canvas');canvas.width=w;canvas.height=h;
   const gl=canvas.getContext(version===2?'webgl2':'webgl',{antialias:false,preserveDrawingBuffer:true});
   if(!gl){result.cases.push({version,available:false});continue;}
   const takeError=()=>gl.getError(),calls=[];
   const record=(name,bytes,extra={})=>calls.push({name,bytes:Array.from(bytes),error:takeError(),...extra});
   phase='texture';const texture=gl.createTexture();gl.bindTexture(gl.TEXTURE_2D,texture);
   gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.NEAREST);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.NEAREST);
   const pixels=new Uint8Array(w*h*4);for(let y=0;y<h;y++)for(let x=0;x<w;x++){const o=(y*w+x)*4;pixels.set([17+x*13,23+y*19,31+(x+y)*7,255],o);}
   gl.texImage2D(gl.TEXTURE_2D,0,version===2?gl.RGBA8:gl.RGBA,w,h,0,gl.RGBA,gl.UNSIGNED_BYTE,pixels);
   const framebuffer=gl.createFramebuffer();gl.bindFramebuffer(gl.FRAMEBUFFER,framebuffer);gl.framebufferTexture2D(gl.FRAMEBUFFER,gl.COLOR_ATTACHMENT0,gl.TEXTURE_2D,texture,0);
   const complete=gl.checkFramebufferStatus(gl.FRAMEBUFFER)===gl.FRAMEBUFFER_COMPLETE;
   gl.disable(gl.BLEND);gl.disable(gl.DITHER);const setupError=takeError();
   phase='read';for(const name of ['full','repeat']){const b=new Uint8Array(w*h*4);gl.readPixels(0,0,w,h,gl.RGBA,gl.UNSIGNED_BYTE,b);record(name,b);}
   const crop=new Uint8Array(3*2*4);gl.readPixels(2,1,3,2,gl.RGBA,gl.UNSIGNED_BYTE,crop);record('crop',crop,{x:2,y:1,width:3,height:2});
   const zero=new Uint8Array(12).fill(165);gl.readPixels(0,0,0,0,gl.RGBA,gl.UNSIGNED_BYTE,zero);record('zero',zero);
   const short=new Uint8Array(4).fill(165);gl.readPixels(0,0,w,h,gl.RGBA,gl.UNSIGNED_BYTE,short);record('short',short);
   if(version===2){
    phase='packed';const offset=7,b=new Uint8Array(7+w*h*4+11).fill(165);gl.readPixels(0,0,w,h,gl.RGBA,gl.UNSIGNED_BYTE,b,offset);record('dst-offset',b,{offset});
    gl.pixelStorei(gl.PACK_ROW_LENGTH,7);gl.pixelStorei(gl.PACK_SKIP_PIXELS,1);gl.pixelStorei(gl.PACK_SKIP_ROWS,1);gl.pixelStorei(gl.PACK_ALIGNMENT,8);
    const packed=new Uint8Array(160).fill(165);gl.readPixels(2,1,3,2,gl.RGBA,gl.UNSIGNED_BYTE,packed,5);record('packed',packed,{offset:5,rowStride:32,skipRows:1,skipPixels:1,x:2,y:1,width:3,height:2});
    gl.pixelStorei(gl.PACK_ROW_LENGTH,0);gl.pixelStorei(gl.PACK_SKIP_PIXELS,0);gl.pixelStorei(gl.PACK_SKIP_ROWS,0);gl.pixelStorei(gl.PACK_ALIGNMENT,4);
    phase='pbo';const pbo=gl.createBuffer();gl.bindBuffer(gl.PIXEL_PACK_BUFFER,pbo);const init=new Uint8Array(16+w*h*4+12).fill(165);gl.bufferData(gl.PIXEL_PACK_BUFFER,init,gl.STREAM_READ);
    gl.readPixels(0,0,w,h,gl.RGBA,gl.UNSIGNED_BYTE,16);const out=new Uint8Array(init.length);gl.getBufferSubData(gl.PIXEL_PACK_BUFFER,0,out);record('pbo',out,{offset:16});
    const invalid=new Uint8Array(w*h*4).fill(165);gl.readPixels(0,0,w,h,gl.RGBA,gl.UNSIGNED_BYTE,invalid);record('typed-with-pbo',invalid);
    gl.bindBuffer(gl.PIXEL_PACK_BUFFER,null);gl.readPixels(0,0,w,h,gl.RGBA,gl.UNSIGNED_BYTE,0);calls.push({name:'offset-without-pbo',error:takeError()});gl.deleteBuffer(pbo);
   }
   phase='clear';gl.clearColor(0,0,0,0);gl.clear(gl.COLOR_BUFFER_BIT);const clear=new Uint8Array(w*h*4);gl.readPixels(0,0,w,h,gl.RGBA,gl.UNSIGNED_BYTE,clear);record('transparent',clear);
   const ext=gl.getExtension('WEBGL_debug_renderer_info');
   const identity={vendor:gl.getParameter(gl.VENDOR),renderer:gl.getParameter(gl.RENDERER),unmaskedVendor:ext?gl.getParameter(ext.UNMASKED_VENDOR_WEBGL):null,unmaskedRenderer:ext?gl.getParameter(ext.UNMASKED_RENDERER_WEBGL):null};
   const precision={};for(const kind of ['VERTEX_SHADER','FRAGMENT_SHADER']){const q=gl.getShaderPrecisionFormat(gl[kind],gl.HIGH_FLOAT);precision[kind]=q?{rangeMin:q.rangeMin,rangeMax:q.rangeMax,precision:q.precision}:null;}
   phase='shader';const program=gl.createProgram();let shaderCompiled=true;for(const [kind,source] of [[gl.VERTEX_SHADER,version===2?'#version 300 es\nin vec2 p;void main(){gl_Position=vec4(p,0,1);}':'attribute vec2 p;void main(){gl_Position=vec4(p,0,1);}'],[gl.FRAGMENT_SHADER,version===2?'#version 300 es\nprecision mediump float;out vec4 color;void main(){color=vec4(1,0,0,1);}':'precision mediump float;void main(){gl_FragColor=vec4(1,0,0,1);}']]){const shader=gl.createShader(kind);gl.shaderSource(shader,source);gl.compileShader(shader);shaderCompiled=shaderCompiled&&gl.getShaderParameter(shader,gl.COMPILE_STATUS)===true;gl.attachShader(program,shader);gl.deleteShader(shader);}
   gl.linkProgram(program);const linked=gl.getProgramParameter(program,gl.LINK_STATUS)===true;
   let draw=null;if(shaderCompiled&&linked){gl.useProgram(program);const vb=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,vb);gl.bufferData(gl.ARRAY_BUFFER,new Float32Array([-1,-1,3,-1,-1,3]),gl.STATIC_DRAW);const loc=gl.getAttribLocation(program,'p');gl.enableVertexAttribArray(loc);gl.vertexAttribPointer(loc,2,gl.FLOAT,false,0,0);gl.viewport(0,0,w,h);gl.drawArrays(gl.TRIANGLES,0,3);const b=new Uint8Array(w*h*4);gl.readPixels(0,0,w,h,gl.RGBA,gl.UNSIGNED_BYTE,b);draw={bytes:Array.from(b),error:takeError()};gl.deleteBuffer(vb);}
   gl.deleteProgram(program);gl.deleteFramebuffer(framebuffer);gl.deleteTexture(texture);
   result.cases.push({version,available:true,width:w,height:h,complete,setupError,calls,shaderCompiled,linked,draw,identity,precision,limits:{texture:gl.getParameter(gl.MAX_TEXTURE_SIZE),renderbuffer:gl.getParameter(gl.MAX_RENDERBUFFER_SIZE)},extensions:gl.getSupportedExtensions(),finalError:takeError()});
  }catch(e){result.errors.push({version,phase,error:e.name});}
 }
 return result;
})()

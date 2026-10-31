// Finite synthetic identity projection; no user data or full fingerprint hashes.
(async()=>{
 const errors=[];
 async function capture(){
  const raw=await navigator.userAgentData.getHighEntropyValues(['architecture','bitness','platform','platformVersion']);
  const hints=Object.fromEntries(['architecture','bitness','mobile','platform','platformVersion'].map(key=>[key,raw[key]]));
  const canvas=document.createElement('canvas'),gl=canvas.getContext('webgl');
  if(!gl)throw Error('WebGL unavailable');
  const extension=gl.getExtension('WEBGL_debug_renderer_info');
  if(!extension)throw Error('Renderer observation unavailable');
  const renderer=gl.getParameter(extension.UNMASKED_RENDERER_WEBGL);
  gl.getExtension('WEBGL_lose_context')?.loseContext();
  return {cpu:navigator.hardwareConcurrency,memory:navigator.deviceMemory,
   screen:[screen.width,screen.height,screen.availWidth,screen.availHeight,screen.colorDepth,devicePixelRatio].join('x'),
   hints,renderer};
 }
 try{return {kind:'finite-cohort-projection',first:await capture(),repeat:await capture(),errors};}
 catch(error){return {kind:'finite-cohort-projection',errors:[error.name]};}
})()

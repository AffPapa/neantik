// Own scope-aware observations: absent APIs are explicit, exceptions are errors.
(async()=>{
 const errors=[],available={};
 const read=(key,fn)=>{try{const value=fn();available[key]=value!==undefined;return value===undefined?null:value;}catch(e){errors.push({key,error:e.name});return null;}};
 const nav=typeof navigator==='object'?navigator:null;
 const nonce=globalThis.__OWN_REALM_NONCE??=(typeof crypto==='object'&&typeof crypto.randomUUID==='function'?crypto.randomUUID():String(Math.random())+':'+String(Date.now()));
 const result={nonce,secure:typeof isSecureContext==='boolean'?isSecureContext:null,url:typeof location==='object'?location.href:null,token:globalThis.OWN_REALM_TOKEN??null,realm:globalThis.constructor?.name??'unknown',available,errors,
  userAgent:read('userAgent',()=>nav?.userAgent),platform:read('platform',()=>nav?.platform),languages:read('languages',()=>nav?.languages?Array.from(nav.languages):undefined),
  hardwareConcurrency:read('hardwareConcurrency',()=>nav?.hardwareConcurrency),deviceMemory:read('deviceMemory',()=>nav?.deviceMemory),
  timezone:read('timezone',()=>typeof Intl==='object'&&typeof Intl.DateTimeFormat==='function'?Intl.DateTimeFormat().resolvedOptions().timeZone:undefined),
  locale:read('locale',()=>typeof Intl==='object'&&typeof Intl.DateTimeFormat==='function'?Intl.DateTimeFormat().resolvedOptions().locale:undefined),
  offscreenCanvas:read('offscreenCanvas',()=>typeof OffscreenCanvas==='function'),
  dom:read('dom',()=>typeof document==='object'),
  audioWorkletSampleRate:read('audioWorkletSampleRate',()=>typeof sampleRate==='number'?sampleRate:undefined)};
 if(nav?.userAgentData){try{result.clientHints=await nav.userAgentData.getHighEntropyValues(['architecture','bitness','platform','platformVersion','fullVersionList']);available.clientHints=true;}catch(e){errors.push({key:'clientHints',error:e.name});}}
 else{available.clientHints=false;result.clientHints=null;}
 return result;
})()

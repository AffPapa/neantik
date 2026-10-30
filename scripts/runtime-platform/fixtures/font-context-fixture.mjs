// Owned two-site font-only producer. No installed-font inventory or external URL.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
const sha=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
const names=['page','DedicatedWorker','SharedWorker','ServiceWorker','AudioWorklet','same-origin iframe','about:blank iframe','srcdoc iframe','cross-origin OOPIF'];
const json=value=>JSON.stringify(value).replaceAll('<','\\u003c');
const nonce=value=>typeof value==='string'&&/^[a-f0-9]{32}$/.test(value);
export const fontContextNames=Object.freeze(names);
export function fontFrameMarkup(config) {
  assert(nonce(config.nonce)&&nonce(config.contextNonce));
  for(const key of ['origin','parentOrigin'])assert(/^http:\/\/(127\.0\.0\.1|localhost):[0-9]+$/.test(config[key]));
  return `<!doctype html><meta charset="utf-8"><title>Owned font frame</title><body><script src="${config.origin}/realm.js?nonce=${config.nonce}"></script><script src="${config.origin}/generic.js?nonce=${config.nonce}"></script><script>
globalThis.__OWN_REALM_NONCE=${json(config.contextNonce)};
Promise.all([runOwnFontPolicyRealm(${json(config)}),runOwnGenericFontRealm(${json(config.nonce)})]).then(([font,generics])=>parent.postMessage({kind:'own-font-frame',contextNonce:${json(config.contextNonce)},value:{contextNonce:${json(config.contextNonce)},font,generics}},${json(config.parentOrigin)})).catch(()=>parent.postMessage({kind:'own-font-frame',contextNonce:${json(config.contextNonce)},error:true},${json(config.parentOrigin)}));</script>`;
}
export function fontWorkerSource(kind,ownedNonce) {
  assert(['dedicated','shared','service'].includes(kind)&&nonce(ownedNonce));
  const capture=`importScripts('/realm.js?nonce=${ownedNonce}','/generic.js?nonce=${ownedNonce}');async function capture(config){globalThis.__OWN_REALM_NONCE=config.contextNonce;return {contextNonce:config.contextNonce,font:await runOwnFontPolicyRealm(config),generics:await runOwnGenericFontRealm(config.nonce)};}`;
  const handle=`if(data.shutdown){port.postMessage({ownShutdown:data.contextNonce});port.close?.();close();return;}capture(data).then(value=>port.postMessage(value)).catch(()=>port.postMessage({error:true}));`;
  if(kind==='dedicated')return capture+`onmessage=e=>{const data=e.data,port=globalThis;${handle}};`;
  if(kind==='shared')return capture+`onconnect=e=>{const port=e.ports[0];port.onmessage=e=>{const data=e.data;${handle}};port.start();};`;
  return capture+`addEventListener('install',e=>e.waitUntil(skipWaiting()));addEventListener('activate',e=>e.waitUntil(clients.claim()));addEventListener('message',e=>{const port=e.ports[0];e.waitUntil(capture(e.data).then(value=>port.postMessage(value)).catch(()=>port.postMessage({error:true})));});`;
}
export function fontWorkletSource(contextNonce) {
  assert(nonce(contextNonce));
  return `globalThis.__OWN_REALM_NONCE=${json(contextNonce)};class OwnFontScope extends AudioWorkletProcessor{constructor(){super();this.port.postMessage({contextNonce:${json(contextNonce)},available:{fontFace:typeof FontFace==='function',fontSet:typeof fonts==='object',canvas:typeof OffscreenCanvas==='function',dom:typeof document==='object'}});}process(inputs,outputs){for(const channel of outputs[0]??[])channel.fill(0.25);return true;}}registerProcessor('own-font-scope',OwnFontScope);`;
}
export async function createFontContextFixture({browserCustody,confirm}) {
  assert.equal(typeof browserCustody,'function');assert.equal(typeof confirm,'function');
  const realm=fs.readFileSync(new URL('./font-policy-realm.js',import.meta.url)),page=fs.readFileSync(new URL('./font-context-page.js',import.meta.url)),generic=fs.readFileSync(new URL('./font-generic-realm.js',import.meta.url));
  const canary=fs.readFileSync(new URL('../../../runtime/font-policy-v1/witness/fonts/owned-canary.ttf',import.meta.url)),ahem=fs.readFileSync(new URL('./vector-semantics/own-ahem.woff2',import.meta.url));
  let state=null;const sockets=new Set(),servers=[],origins=[];
  function handler(index){return async(req,res)=>{
    res.setHeader('Cache-Control','no-store');res.setHeader('X-Content-Type-Options','nosniff');
    let u;try{u=new URL(req.url,origins[index]);}catch{res.writeHead(400).end();return;}
    const active=state;if(!active||u.origin!==origins[index]||req.headers.host!==new URL(origins[index]).host||u.searchParams.get('nonce')!==active.nonce){res.writeHead(404).end();return;}
    let custody;try{custody=browserCustody(req.socket.remotePort,servers[index].address().port);}catch{}
    if(!custody?.sameProcessGroup||!custody?.runtimePathBound||!/^[a-f0-9]{64}$/.test(custody.generationSHA256??'')){res.writeHead(403).end();return;}
    const request={site:index,path:u.pathname,method:req.method,custody,...(u.pathname==='/worklet.js'?{contextNonce:u.searchParams.get('contextNonce')}: {})};active.requests.push(request);
    const config={nonce:active.nonce,origin:origins[index],crossOrigin:origins[1],fontURL:origins[index]+'/canary.ttf?nonce='+active.nonce,ahemURL:origins[index]+'/ahem.woff2?nonce='+active.nonce,parentOrigin:origins[0]};
    if(req.method==='GET'&&u.pathname==='/own'&&index===0){res.setHeader('Content-Type','text/html; charset=utf-8');res.end(`<!doctype html><meta charset="utf-8"><title>NeAntik own font contexts</title><body><script>globalThis.OWN_FONT_CONTEXT_CONFIG=${json(config)};</script><script src="/realm.js?nonce=${active.nonce}"></script><script src="/generic.js?nonce=${active.nonce}"></script><script src="/font-context-page.js?nonce=${active.nonce}"></script>`);return;}
    if(req.method==='GET'&&['/realm.js','/generic.js','/font-context-page.js','/canary.ttf','/ahem.woff2'].includes(u.pathname)){
      const data={'/realm.js':[realm,'text/javascript'],'/generic.js':[generic,'text/javascript'],'/font-context-page.js':[page,'text/javascript'],'/canary.ttf':[canary,'font/ttf'],'/ahem.woff2':[ahem,'font/woff2']}[u.pathname];res.setHeader('Content-Type',data[1]);res.end(data[0]);return;
    }
    if(req.method==='GET'&&['/dedicated.js','/shared.js','/service.js'].includes(u.pathname)&&index===0){res.setHeader('Content-Type','text/javascript');res.end(fontWorkerSource(u.pathname.slice(1,-3),active.nonce));return;}
    if(req.method==='GET'&&u.pathname==='/worklet.js'&&index===0&&nonce(u.searchParams.get('contextNonce'))){res.setHeader('Content-Type','text/javascript');const module=fontWorkletSource(u.searchParams.get('contextNonce'));request.servedModuleSHA256=sha(module);request.served=true;res.end(module);return;}
    if(req.method==='GET'&&u.pathname==='/frame'&&names.slice(5).includes(u.searchParams.get('name'))&&nonce(u.searchParams.get('contextNonce'))){res.setHeader('Content-Type','text/html; charset=utf-8');res.end(fontFrameMarkup({...config,contextNonce:u.searchParams.get('contextNonce')}));return;}
    if(req.method==='GET'&&u.pathname==='/confirm'&&index===0&&names.includes(u.searchParams.get('name'))&&nonce(u.searchParams.get('contextNonce'))){
      let value;try{value=await confirm(u.searchParams.get('name'),u.searchParams.get('contextNonce'));}catch{res.writeHead(500).end();return;}
      if(state!==active){res.writeHead(409).end();return;}res.setHeader('Content-Type','application/json');res.end(JSON.stringify(value));return;
    }
    if(req.method==='GET'&&u.pathname==='/phase'&&index===0){res.setHeader('Content-Type','application/json');res.end(JSON.stringify({teardown:active.teardown}));return;}
    if(req.method==='POST'&&index===0&&['/result','/closed'].includes(u.pathname)){
      const key=u.pathname==='/result'?'result':'closed';
      if(req.headers.origin!==origins[0]||req.headers['content-type']!=='application/json'||active[key]){res.writeHead(409).end();return;}
      let size=0;const chunks=[];
      try{
        for await(const bytes of req){size+=bytes.length;if(size>1048576)throw Error('OwnResultTooLarge');chunks.push(bytes);}
        const value=JSON.parse(Buffer.concat(chunks));if(value?.nonce!==active.nonce||state!==active||active[key])throw Error('OwnEnvelope');
        if(key==='result')assert(value.schemaVersion===1&&Array.isArray(value.results)&&value.results.length<=9);
        else assert(typeof value.teardownAllowed==='boolean'&&Number.isSafeInteger(value.completed)&&value.completed>=0&&value.completed<=16&&Array.isArray(value.errors));
        active[key]=value;res.writeHead(204).end();
      }catch{res.writeHead(400).end();}return;
    }
    res.writeHead(404).end();
  };}
  try {for(let i=0;i<2;i++){
    const server=http.createServer(handler(i));servers.push(server);server.requestTimeout=10000;server.headersTimeout=10000;
    server.on('connection',socket=>{sockets.add(socket);socket.once('close',()=>sockets.delete(socket));});
    await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});origins.push('http://'+(i===0?'127.0.0.1':'localhost')+':'+server.address().port);
  }}catch(error){for(const server of servers)server.close();throw error;}
  return {origins,resourceHashes:{realmSHA256:sha(realm),pageSHA256:sha(page),genericSHA256:sha(generic),canarySHA256:sha(canary),ahemSHA256:sha(ahem)},
    begin(value=crypto.randomBytes(16).toString('hex')){assert(!state&&nonce(value));state={nonce:value,requests:[],result:null,closed:null,teardown:false};return {nonce:value,url:origins[0]+'/own?nonce='+value};},
    observation(){return state?structuredClone(state):null;},requestTeardown(){assert(state);state.teardown=true;},finish(){assert(state);const value=state;state=null;return value;},
    async close(){const owned=[...sockets],closed=owned.map(socket=>new Promise(resolve=>socket.once('close',resolve))),stopped=servers.map(server=>new Promise(resolve=>server.close(resolve)));for(const socket of owned)socket.destroy();await Promise.all([...closed,...stopped]);assert.equal(sockets.size,0);}
  };
}

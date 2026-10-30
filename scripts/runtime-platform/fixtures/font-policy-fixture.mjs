// Loopback fixture for the next headed font-policy gate. No browser launch here.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';

const digest=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
export async function createFontPolicyFixture({browserCustody}) {
  assert.equal(typeof browserCustody,'function','Kernel browser custody callback required');
  const realm=fs.readFileSync(new URL('./font-policy-realm.js',import.meta.url),'utf8');
  const canary=fs.readFileSync(new URL('../../../runtime/font-policy-v1/witness/fonts/owned-canary.ttf',import.meta.url));
  const ahem=fs.readFileSync(new URL('./vector-semantics/own-ahem.woff2',import.meta.url));
  let active=null,port=0;const sockets=new Set();
  const server=http.createServer(async(req,res)=>{
    res.setHeader('Cache-Control','no-store');res.setHeader('X-Content-Type-Options','nosniff');
    let url;
    try {url=new URL(req.url,'http://127.0.0.1');}catch {res.writeHead(400).end();return;}
    if(!active||req.headers.host!==`127.0.0.1:${port}`||url.searchParams.get('nonce')!==active.nonce) {res.writeHead(404).end();return;}
    const state=active;
    let custody;
    try {custody=browserCustody(req.socket.remotePort,port);}catch {custody=null;}
    if(!custody?.sameProcessGroup||!custody?.runtimePathBound||!/^[a-f0-9]{64}$/.test(custody.generationSHA256??'')) {res.writeHead(403).end();return;}
    state.requests.push({path:url.pathname,method:req.method,custody});
    const suffix='?nonce='+state.nonce;
    if(req.method==='GET'&&url.pathname==='/own') {
      const config={nonce:state.nonce,fontURL:`http://127.0.0.1:${port}/canary.ttf${suffix}`,ahemURL:`http://127.0.0.1:${port}/ahem.woff2${suffix}`};
      res.setHeader('Content-Type','text/html; charset=utf-8');
      res.end(`<!doctype html><meta charset="utf-8"><title>NeAntik owned font QA</title><body data-own-font-qa="${state.nonce}"><script src="/realm.js${suffix}"></script><script>
(async()=>{const config=${JSON.stringify(config)};let worker=null,url=null;const report={schemaVersion:1,nonce:config.nonce,realms:[],error:null,workerTerminationRequested:false};
try{report.realms.push(await runOwnFontPolicyRealm(config));
const source=${JSON.stringify(realm).replaceAll('<','\\u003c')}+';onmessage=async e=>{try{postMessage(await runOwnFontPolicyRealm(e.data));}catch(e){postMessage({error:e.name});}finally{close();}}';
url=URL.createObjectURL(new Blob([source],{type:'text/javascript'}));worker=new Worker(url);
report.realms.push(await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('OwnWorkerTimeout')),15000);worker.onmessage=e=>{clearTimeout(timer);resolve(e.data);};worker.onerror=()=>{clearTimeout(timer);reject(Error('OwnWorkerError'));};worker.postMessage(config);}));
}catch(e){report.error=e.name;}finally{if(worker){worker.terminate();report.workerTerminationRequested=true;}if(url)URL.revokeObjectURL(url);}
await fetch('/result?nonce='+config.nonce,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(report)});
})().catch(()=>{});</script>`);return;
    }
    if(req.method==='GET'&&url.pathname==='/realm.js') {res.setHeader('Content-Type','text/javascript');res.end(realm);return;}
    if(req.method==='GET'&&['/canary.ttf','/ahem.woff2'].includes(url.pathname)) {res.setHeader('Content-Type',url.pathname==='/canary.ttf'?'font/ttf':'font/woff2');res.end(url.pathname==='/canary.ttf'?canary:ahem);return;}
    if(req.method==='POST'&&url.pathname==='/result') {
      if(req.headers.origin!==`http://127.0.0.1:${port}`||req.headers['content-type']!=='application/json'||state.result) {res.writeHead(409).end();return;}
      let size=0;const pieces=[];
      try {
        for await(const bytes of req){size+=bytes.length;if(size>131072)throw Error('OwnResultTooLarge');pieces.push(bytes);}
        const value=JSON.parse(Buffer.concat(pieces).toString('utf8'));
        if(value?.schemaVersion!==1||value.nonce!==state.nonce||!Array.isArray(value.realms)||value.realms.length>2)throw Error('OwnResultEnvelope');
        if(active!==state||state.result)throw Error('OwnResultSessionChanged');
        state.result=value;res.writeHead(204).end();
      }catch {res.writeHead(400).end();}
      return;
    }
    res.writeHead(404).end();
  });
  server.on('connection',socket=>{sockets.add(socket);socket.once('close',()=>sockets.delete(socket));});
  server.requestTimeout=10000;server.headersTimeout=10000;
  await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
  port=server.address().port;
  return {origin:`http://127.0.0.1:${port}`,resourceHashes:{canarySHA256:digest(canary),ahemSHA256:digest(ahem),realmSHA256:digest(realm)},
    begin(nonce=crypto.randomBytes(16).toString('hex')){assert(!active,'One owned session at a time');assert(/^[a-f0-9]{32}$/.test(nonce),'Owned nonce required');active={nonce,requests:[],result:null};return {nonce:active.nonce,url:`http://127.0.0.1:${port}/own?nonce=${active.nonce}`};},
    observation(){return active?structuredClone(active):null;},
    finish(){assert(active);const result=active;active=null;return result;},
    async close(){
      // server.close's callback can precede each socket's close notification.
      // Observe those notifications instead of treating destroy() as cleanup.
      const owned=[...sockets],closed=owned.map(socket=>new Promise(resolve=>socket.once('close',resolve)));
      const stopped=new Promise(resolve=>server.close(resolve));
      for(const socket of owned)socket.destroy();
      await Promise.all([stopped,...closed]);assert.equal(sockets.size,0);
    },
    scope:'loopback producer only; actual browser/probe execution and qualification are separate'};
}

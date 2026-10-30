import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import vm from 'node:vm';
const sha=value=>crypto.createHash('sha256').update(value).digest('hex'),valid=value=>typeof value==='string'&&/^[a-f0-9]{32}$/.test(value),json=value=>JSON.stringify(value).replaceAll('<','\\u003c');
export const ownFontAccessNames=['NeAntikFontPolicyCanary','NeAntikFontPolicyFamilyCollision','Helvetica-Light'];
export function fontAccessForeignSource(config){return `
(async()=>{const names=${json([...ownFontAccessNames,'NeAntikMissing_'+config.nonce])};let value=null,error=false;
try{const permission=await navigator.permissions.query({name:'local-fonts'}),policy=document.permissionsPolicy??document.featurePolicy;
let count=null,queryError=null;try{count=(await queryLocalFonts({postscriptNames:names})).length;}catch(e){queryError=['SecurityError','NotAllowedError'].includes(e.name)?e.name:'unexpected';}
value={permission:permission.state,policyAllowed:policy?.allowsFeature('local-fonts')===true,activeGesture:navigator.userActivation.isActive,count,queryError};}catch{error=true;}
parent.postMessage({kind:'own-font-access-foreign',nonce:${json(config.nonce)},value,error},${json(config.origin)});})().catch(()=>{});`;}
export function fontAccessTopSource(config){return `
(async()=>{const names=${json([...ownFontAccessNames,'NeAntikMissing_'+config.nonce])};let value=null,error=false;
try{const permission=await navigator.permissions.query({name:'local-fonts'}),policy=document.permissionsPolicy??document.featurePolicy;
let count=null,queryError=null;try{count=(await queryLocalFonts({postscriptNames:names})).length;}catch(e){queryError=['SecurityError','NotAllowedError'].includes(e.name)?e.name:'unexpected';}
value={topLevel:top===self,visible:document.visibilityState==='visible',permission:permission.state,policyAllowed:policy?.allowsFeature('local-fonts')===true,activeGesture:navigator.userActivation.isActive,count,queryError};}catch{error=true;}
await fetch('/top-result?nonce=${config.nonce}',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({nonce:${json(config.nonce)},value,error})});})().catch(()=>{});`;}
export async function createFontAccessFixture({browserCustody}){
  assert.equal(typeof browserCustody,'function');
  const page=fs.readFileSync(new URL('./font-access-page.js',import.meta.url)),sfnt=fs.readFileSync(new URL('./font-access-sfnt.js',import.meta.url));
  const context=vm.createContext({Uint8Array,DataView,Map});vm.runInContext(sfnt.toString(),context);
  const files=['owned-canary.ttf','owned-family-collision.ttf'].map(name=>new URL('../../../runtime/font-policy-v1/witness/fonts/'+name,import.meta.url));
  const ownTables=files.map((file,index)=>{const parsed=context.readOwnFontSFNT(new Uint8Array(fs.readFileSync(file)),ownFontAccessNames[index]);return Object.fromEntries(['cmap','glyf','loca','hmtx','maxp'].map(tag=>{assert(parsed.tables.has(tag));return [tag,sha(parsed.tables.get(tag))];}));});
  let state=null;const servers=[],origins=[],sockets=new Set();
  const handle=index=>async(req,res)=>{
    res.setHeader('Cache-Control','no-store');res.setHeader('X-Content-Type-Options','nosniff');
    let url;try{url=new URL(req.url,origins[index]);}catch{res.writeHead(400).end();return;}
    const active=state;if(!active||req.headers.host!==new URL(origins[index]).host||url.origin!==origins[index]||url.searchParams.get('nonce')!==active.nonce){res.writeHead(404).end();return;}
    let custody;try{custody=browserCustody(req.socket.remotePort,servers[index].address().port);}catch{}
    if(custody?.sameProcessGroup!==true||custody.runtimePathBound!==true||!/^[a-f0-9]{64}$/.test(custody.generationSHA256??'')){res.writeHead(403).end();return;}
    active.requests.push({site:index,path:url.pathname,method:req.method,custody});
    const config={nonce:active.nonce,origin:origins[0],foreignOrigin:origins[1],names:ownFontAccessNames,ownTables};
    if(req.method==='GET'&&url.pathname==='/access'&&index===0){res.setHeader('Content-Type','text/html; charset=utf-8');res.end(`<!doctype html><meta charset="utf-8"><title>NeAntik owned Font Access QA</title><body><script>globalThis.OWN_FONT_ACCESS_CONFIG=${json(config)};</script><script src="/sfnt.js?nonce=${active.nonce}"></script><script src="/access.js?nonce=${active.nonce}"></script>`);return;}
    if(req.method==='GET'&&url.pathname==='/foreign'&&index===1){res.setHeader('Content-Type','text/html; charset=utf-8');res.end(`<!doctype html><meta charset="utf-8"><title>Owned foreign Font Access</title><script>${fontAccessForeignSource(config)}</script>`);return;}
    if(req.method==='GET'&&url.pathname==='/top-foreign'&&index===1){res.setHeader('Content-Type','text/html; charset=utf-8');res.end(`<!doctype html><meta charset="utf-8"><title>Owned standalone Font Access</title><script>${fontAccessTopSource(config)}</script>`);return;}
    if(req.method==='GET'&&index===0&&['/sfnt.js','/access.js'].includes(url.pathname)){res.setHeader('Content-Type','text/javascript');res.end(url.pathname==='/sfnt.js'?sfnt:page);return;}
    if(req.method==='GET'&&url.pathname==='/phase'&&index===0){active.mainVisible=url.searchParams.get('visible')==='1';res.setHeader('Content-Type','application/json');res.end(json({phase:active.phase,topForeign:active.topForeign}));return;}
    if(req.method==='POST'&&((index===0&&['/ready','/step','/result'].includes(url.pathname))||(index===1&&url.pathname==='/top-result'))){
      if(req.headers.origin!==origins[index]||req.headers['content-type']!=='application/json'){res.writeHead(409).end();return;}
      let bytes=0;const chunks=[];
      try{
        for await(const chunk of req){bytes+=chunk.length;if(bytes>32768)throw Error('OwnAccessPayload');chunks.push(chunk);}
        const value=JSON.parse(Buffer.concat(chunks));assert.equal(value.nonce,active.nonce);assert.equal(state,active);
        if(url.pathname==='/ready'){assert.equal(active.ready,null);assert(value.ready&&typeof value.ready==='object');active.ready=value.ready;}
        if(url.pathname==='/step'){assert.equal(value.stage?.phase,active.phase);assert(active.steps.length<3&&!active.steps.some(row=>row.phase===value.stage.phase));active.steps.push(value.stage);}
        if(url.pathname==='/result'){assert.equal(active.result,null);assert.equal(value.schemaVersion,1);assert(Array.isArray(value.stages)&&value.stages.length<=3);active.result=value;}
        if(url.pathname==='/top-result'){assert.equal(active.topForeign,null);assert.equal(value.error,false);assert(value.value?.topLevel===true);active.topForeign=value.value;active.mainVisible=false;}
        res.writeHead(204).end();
      }catch{res.writeHead(400).end();}return;
    }
    res.writeHead(404).end();
  };
  try{for(let index=0;index<2;index++){
    const server=http.createServer(handle(index));servers.push(server);server.requestTimeout=10000;server.headersTimeout=10000;server.on('connection',socket=>{sockets.add(socket);socket.once('close',()=>sockets.delete(socket));});
    await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});origins.push('http://'+(index===0?'127.0.0.1':'localhost')+':'+server.address().port);
  }}catch(error){for(const server of servers)server.close();throw error;}
  return {origins,sourceHashes:{page:sha(page),sfnt:sha(sfnt),fonts:files.map(file=>sha(fs.readFileSync(file)))},
    begin(nonce=crypto.randomBytes(16).toString('hex')){assert(!state&&valid(nonce));state={nonce,phase:'idle',ready:null,steps:[],result:null,requests:[],topForeign:null,mainVisible:false};return {nonce,url:origins[0]+'/access?nonce='+nonce};},
    phase(value){assert(state&&['denied-initial','granted','denied-revoked'].includes(value));state.phase=value;},observation(){return state?structuredClone(state):null;},finish(){assert(state);const value=state;state=null;return value;},
    async close(){const owned=[...sockets],stopped=servers.map(server=>new Promise(resolve=>server.close(resolve))),closed=owned.map(socket=>new Promise(resolve=>socket.once('close',resolve)));for(const socket of owned)socket.destroy();await Promise.all([...stopped,...closed]);assert.equal(sockets.size,0);}
  };
}

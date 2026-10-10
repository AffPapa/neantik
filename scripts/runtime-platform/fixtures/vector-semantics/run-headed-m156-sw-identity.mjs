// Own headed runtime fixture. Never touches a user-data-dir outside its mkdtemp.
import assert from 'node:assert/strict';
import {runtimeBinding,applyManagerLaunch,digest} from '../candidate-binding.mjs';
import {browserFixtureEnvironment} from '../qa-browser-environment.mjs';
import {fixtureSourceProvenance,assertFixtureSourcesUnchanged,preserveFixtureSources} from '../fixture-source-provenance.mjs';
import fs from 'node:fs';import path from 'node:path';import crypto from 'node:crypto';
import http from 'node:http';import dgram from 'node:dgram';import {spawn,spawnSync} from 'node:child_process';
import {setTimeout as delay} from 'node:timers/promises';import {fileURLToPath} from 'node:url';
import {OwnContextLifecycleRecorder} from './context-lifecycle-recorder.mjs';
import {OwnedDownloadObserver,ownedDownloadPayload} from './download-observer.mjs';
import {observeDisabledPVT,verifyDisabledPVT} from './disabled-pvt-cdp-hook-m156.mjs';
import {sendOwnedRawCDP} from './owned-raw-cdp.mjs';
const home=path.dirname(fileURLToPath(import.meta.url));
const [runtimeApp,label,mode,requiredHash,extraFile,probeName="page-probe.js"]=process.argv.slice(2);
assert(path.isAbsolute(runtimeApp)&&label.length<=160&&/^[a-z0-9-]+$/.test(label)&&['neantik-configured','unconfigured','fury-configured','webrtc-direct','webrtc-guarded','webrtc-url-override','webrtc-extension-direct','webrtc-extension-guarded','webrtc-policy-direct','webrtc-policy-guarded','webrtc-localip-direct','webrtc-localip-guarded'].includes(mode)&&/^[0-9a-f]{64}$/.test(requiredHash));
const outputPath=path.join(home,`${label}-observations.json`);assert(!fs.existsSync(outputPath),'An existing observation cannot be replaced');
function plist(key){const r=spawnSync('plutil',['-extract',key,'raw','-o','-',path.join(runtimeApp,'Contents/Info.plist')],{encoding:'utf8'});assert.equal(r.status,0);return r.stdout.trim();}
const executable=path.join(runtimeApp,'Contents/MacOS',plist('CFBundleExecutable'));
assert.equal(crypto.createHash('sha256').update(fs.readFileSync(executable)).digest('hex'),requiredHash);
const packagedVersion=plist('CFBundleShortVersionString');
const candidateBinding=runtimeBinding(runtimeApp,requiredHash);assert.equal(packagedVersion,candidateBinding.binding.runtimeVersion);
const signatureCheck=spawnSync('/usr/bin/codesign',['--verify','--deep','--strict',runtimeApp],{encoding:'utf8'});assert.equal(signatureCheck.status,0,'Exact fixture runtime signature invalid');
const osVersion=spawnSync('/usr/bin/sw_vers',['-productVersion'],{encoding:'utf8'});assert.equal(osVersion.status,0);
assert(/^[a-z0-9-]+\.js$/.test(probeName));const probe=fs.readFileSync(path.join(home,probeName),'utf8');
const root=fs.mkdtempSync('/private/tmp/neantik-vector-semantics-');fs.chmodSync(root,0o700);
const fixtureNonce=crypto.randomBytes(16).toString('hex');
let fixtureResponses=0,fixtureDocument=null,downloadObserver=null;const ownIdentityReceipts=[];
let crossServer,crossOrigin=null,stunServer=null,stunPort=null,stunRequests=0,proxyServer=null,proxyRequests=0,ownOrigin=null;
const pvtProbe=probeName==='disabled-pvt-probe.js';let pvtRawResponses=[],pvtFeatureOverride=false;
const dprEmulation=probeName==='dpr-emulation-probe.js';
const dprProbe=probeName==='dpr-probe.js'||dprEmulation;let ownDPRReceipts=[],zoomPreferenceReceipt=null;
const webrtcProbe=probeName==='webrtc-probe.js';
const extensionFixture=webrtcProbe&&(mode.includes('extension')||mode.includes('policy'));
const managedPolicyFixture=mode.includes('policy');
let extensionEvidence=null;
const operationsProbe=probeName==='context-operations-probe.js';
const lifecycleProbe=probeName==='context-lifecycle-probe.js'||operationsProbe;
const contextProbe=probeName==='context-probe.js'||lifecycleProbe;let lifecycleRecorder=null;
const provenanceFiles=[new URL('./context-lifecycle-recorder.mjs',import.meta.url),new URL('./download-observer.mjs',import.meta.url),new URL(import.meta.url),new URL('../qa-browser-environment.mjs',import.meta.url),new URL('../fixture-source-provenance.mjs',import.meta.url),new URL('../candidate-binding.mjs',import.meta.url),path.join(home,probeName)];
if(pvtProbe)provenanceFiles.push(path.join(home,'disabled-pvt-cdp-hook-m156.mjs'),path.join(home,'owned-raw-cdp.mjs'));
if(probeName==='identity-sw-probe.js')provenanceFiles.push(path.join(home,'identity-sw-worker.js'));
if(contextProbe)provenanceFiles.push(path.join(home,'realm-capture.js'));
if(operationsProbe)provenanceFiles.push(path.join(home,'realm-operations-capture.js'));
if(extensionFixture)provenanceFiles.push(path.join(home,'webrtc-extension-receipt.js'));
if(probeName==='geometry-font-probe.js')provenanceFiles.push(path.join(home,'own-ahem.woff2'));
const fixtureProvenance=fixtureSourceProvenance(provenanceFiles);
const fixtureSourceArchive=preserveFixtureSources(fixtureProvenance);
const basicRealmSource=contextProbe?fs.readFileSync(path.join(home,'realm-capture.js'),'utf8'):null;
const realmSource=operationsProbe?fs.readFileSync(path.join(home,'realm-operations-capture.js'),'utf8').replace('BASIC_REALM_CAPTURE',basicRealmSource):basicRealmSource;
async function ownHandler(req,res){
 res.setHeader('Cache-Control','no-store');const url=new URL(req.url,'http://127.0.0.1');
 if(probeName==='download-operations-probe.js'){
  if(url.pathname==='/own-download-receipt'){
   const name=url.searchParams.get('case');assert(['complete','cancel'].includes(name));
   assert(downloadObserver);res.setHeader('Content-Type','application/json');res.end(JSON.stringify(await downloadObserver.receipt(name)));return;
  }
  if(url.pathname==='/own-download'){
   const name=url.searchParams.get('case');assert(['complete','cancel'].includes(name));
   res.setHeader('Content-Type','application/octet-stream');res.setHeader('Content-Disposition','attachment; filename="owned-fixture.bin"');
   res.setHeader('Content-Length',name==='complete'?ownedDownloadPayload.length:1024*1024);
   if(name==='complete'){res.end(ownedDownloadPayload);return;}
   let bytes=0;const chunk=Buffer.alloc(1024,0x5a),timer=setInterval(()=>{if(res.destroyed){clearInterval(timer);return;}res.write(chunk);bytes+=chunk.length;if(bytes===1024*1024){clearInterval(timer);res.end();}},50);
   res.once('close',()=>clearInterval(timer));return;
  }
 }

 if(dprProbe){
  res.setHeader('Accept-CH','Sec-CH-DPR, DPR');
  const receipt={path:url.pathname,requestNonce:url.searchParams.get('requestNonce'),fixtureNonce,headers:{dpr:req.headers.dpr??null,'sec-ch-dpr':req.headers['sec-ch-dpr']??null},destination:req.headers['sec-fetch-dest']??null};ownDPRReceipts.push(receipt);
  if(url.pathname==='/dpr-echo'){res.setHeader('Content-Type','application/json');res.end(JSON.stringify(receipt));return;}
  if(dprEmulation&&url.pathname==='/dpr-child'){
   res.setHeader('Content-Type','text/html');res.end('<!doctype html><body data-own-fixture="'+fixtureNonce+'"><script>globalThis.OWN_DPR_CHILD='+JSON.stringify(url.searchParams.get('childNonce'))+';('+probe+').then(data=>parent.postMessage({ownDPRChild:globalThis.OWN_DPR_CHILD,data},"*"))<\/script>');return;
  }
 }
 if(probeName==='identity-probe.js'||probeName==='identity-sw-probe.js'||operationsProbe){
  res.setHeader('Accept-CH','Sec-CH-UA-Arch, Sec-CH-UA-Bitness, Sec-CH-UA-Platform-Version, Sec-CH-UA-Full-Version-List, Sec-CH-Device-Memory, Device-Memory');
  if(url.pathname==='/identity-redirect'){res.writeHead(302,{Location:'/identity?via=redirect'});res.end();return;}
  if(url.pathname==='/identity'){
   const keys=['user-agent','accept-language','sec-ch-ua','sec-ch-ua-mobile','sec-ch-ua-platform','sec-ch-ua-arch','sec-ch-ua-bitness','sec-ch-ua-platform-version','sec-ch-ua-full-version-list','sec-ch-device-memory','device-memory'];
   const receipt={via:url.searchParams.get('via'),realmNonce:url.searchParams.get('realmNonce'),requestNonce:url.searchParams.get('requestNonce'),headers:Object.fromEntries(keys.map(k=>[k,req.headers[k]??null]))};ownIdentityReceipts.push(receipt);res.setHeader('Content-Type','application/json');res.end(JSON.stringify(receipt));return;
  }
  if(url.pathname==='/identity-worker.js'){
   res.setHeader('Content-Type','text/javascript');res.end('onmessage=async()=>{try{const js={userAgent:navigator.userAgent,languages:Array.from(navigator.languages),deviceMemory:navigator.deviceMemory,hints:await navigator.userAgentData.getHighEntropyValues(["architecture","bitness","platformVersion","fullVersionList"])};const http=await(await fetch("/identity?via=worker")).json();postMessage({js,http});}catch(e){postMessage({error:e.name});}close();}');return;
  }
 }

 if(probeName==='identity-sw-probe.js'&&url.pathname==='/owned-identity-sw.js'){res.setHeader('Content-Type','text/javascript');res.end(fs.readFileSync(path.join(home,'identity-sw-worker.js')));return;}
 if(probeName==='geometry-font-probe.js'&&url.pathname==='/own-ahem.woff2'){res.setHeader('Content-Type','font/woff2');res.end(fs.readFileSync(path.join(home,'own-ahem.woff2')));return;}
 if(webrtcProbe&&url.pathname==='/stun-config'){res.setHeader('Content-Type','application/json');res.end(JSON.stringify({url:'stun:127.0.0.1:'+stunPort}));return;}
 if(contextProbe){
  if(url.pathname==='/lifecycle-confirm'){const result=await lifecycleRecorder.confirm(url.searchParams.get('name'),url.searchParams.get('nonce'));res.setHeader('Content-Type','application/json');res.end(JSON.stringify(result));return;}
  if(url.pathname==='/oopif-target-confirm'){
   const expected=crossOrigin+'/frame?token='+encodeURIComponent(url.searchParams.get('token'));
   let evidence={confirmed:false};try{
    const t=await command(browser,'Target.getTargets'),target=t.targetInfos.find(x=>x.type==='iframe'&&x.url===expected);
    if(target){const attached=await command(browser,'Target.attachToTarget',{targetId:target.targetId,flatten:true});const sid=attached.sessionId;let contexts=[];const listen=e=>{try{const d=JSON.parse(e.data);if(d.sessionId===sid&&d.method==='Runtime.executionContextCreated')contexts.push(d.params.context);}catch{}};browser.addEventListener('message',listen);
     try{await command(browser,'Runtime.enable',{},sid);const tree=await command(browser,'Page.getFrameTree',{},sid),parentTree=await command(page,'Page.getFrameTree');const context=contexts.find(x=>x.auxData?.isDefault===true&&x.auxData?.frameId===tree.frameTree.frame.id);const evaluated=await command(browser,'Runtime.evaluate',{expression:'({token:globalThis.OWN_REALM_TOKEN,nonce:globalThis.__OWN_REALM_NONCE,url:location.href,origin:location.origin})',returnByValue:true,contextId:context?.id},sid);const value=evaluated.result?.value;const childFrame=tree.frameTree.frame,parentFrame=parentTree.frameTree.frame;const linked=childFrame.parentId===parentFrame.id&&childFrame.url===expected;evidence={confirmed:!!context&&linked&&value?.url===expected&&value?.token===url.searchParams.get('token'),targetType:target.type,sessionAttached:true,frameLinked:linked,childParentAvailable:!!childFrame.parentId,defaultContextVerified:!!context,childValue:value};}
     finally{browser.removeEventListener('message',listen);await command(browser,'Target.detachFromTarget',{sessionId:sid});}
    }
   }catch{evidence.error='OOPIFEvidenceError';}
   res.setHeader('Content-Type','application/json');res.end(JSON.stringify(evidence));return;
  }
  const sources={
   '/realm-capture.js':realmSource,
   '/dedicated.js':`onmessage=async()=>{postMessage(await (${realmSource}));${lifecycleProbe?'':'close();'}};`,
   '/shared.js':`onconnect=e=>{const p=e.ports[0];p.onmessage=async e=>{if(e.data?.shutdown){p.postMessage({ownShutdown:true});p.close();close();return;}p.postMessage(await (${realmSource}));${lifecycleProbe?'':'p.close();close();'}};p.start();};`,
   '/service.js':`addEventListener('install',e=>e.waitUntil(skipWaiting()));addEventListener('activate',e=>e.waitUntil(clients.claim()));addEventListener('message',e=>e.waitUntil((async()=>{e.ports[0].postMessage(await (${realmSource}));e.ports[0].close();})()));`,
   '/worklet.js':`class OwnRealmProbe extends AudioWorkletProcessor{constructor(){super();this.capture=(${realmSource});this.sent=false;}process(){if(!this.sent){this.sent=true;const frame=currentFrame;this.capture.then(value=>this.port.postMessage({...value,processingReceipt:{calls:1,frame}})).catch(()=>this.port.postMessage({errors:[{key:'capture',error:'WorkletError'}]}));}return false;}}registerProcessor('own-realm-probe',OwnRealmProbe);`
  };
  if(operationsProbe)sources['/worklet.js']=`class OwnRealmProbe extends AudioWorkletProcessor{constructor(){super();this.capture=(${realmSource});this.sent=false;}process(inputs,outputs){const input=inputs[0]?.[0],output=outputs[0]?.[0];if(input&&output)output.set(input);if(!this.sent){this.sent=true;const frame=currentFrame,receipt={calls:1,frame,input:Array.from(input??[]),output:Array.from(output??[])};this.capture.then(value=>this.port.postMessage({...value,processingReceipt:receipt})).catch(()=>this.port.postMessage({errors:[{key:'capture',error:'WorkletError'}]}));}return false;}}registerProcessor('own-realm-probe',OwnRealmProbe);`;
  if(Object.hasOwn(sources,url.pathname)){res.setHeader('Content-Type','text/javascript');res.end(sources[url.pathname]);return;}
  if(url.pathname==='/frame'){
   res.setHeader('Content-Type','text/html');const token=JSON.stringify(url.searchParams.get('token'));res.end('<!doctype html><script>globalThis.OWN_REALM_TOKEN='+token+';('+realmSource+').then(value=>parent.postMessage({token:'+token+',value},"*")).catch(()=>parent.postMessage({token:'+token+',error:true},"*"))<\/script>');return;
  }
 }
 res.setHeader('Content-Type','text/html');fixtureResponses++;res.end('<!doctype html><meta charset="utf-8"><title>Own Web Platform fixture</title><body data-own-fixture="'+fixtureNonce+'">'+(contextProbe||dprEmulation?'<script>globalThis.OWN_LIFECYCLE='+JSON.stringify(lifecycleProbe)+';globalThis.OWN_CROSS_ORIGIN='+JSON.stringify(crossOrigin)+'<\/script>':'')+'</body>');
}
const server=http.createServer((req,res)=>{ownHandler(req,res).catch(()=>{res.statusCode=500;res.end('Own fixture error');});});
let child,browser,page,group,startError=false,captured=null,cleanup=false,sequence=0,configFD=null,config=null,phase='server',diagnosticFD=null;
const env=browserFixtureEnvironment();
const flags=['--use-mock-keychain','--remote-debugging-address=127.0.0.1','--remote-debugging-port=0','--no-first-run','--no-default-browser-check','--new-window','--disable-background-networking','--disable-component-update','--disable-sync','--disable-extensions'];
if(mode==='neantik-configured'){
 config={profileSeed:21,scope:'synthetic-direct-manager-policy',launchReceiptSHA256:applyManagerLaunch(flags,env)};
}
if(pvtProbe&&extraFile&&extraFile!=='-'){
 assert(mode==='neantik-configured'&&path.isAbsolute(extraFile));const options=JSON.parse(fs.readFileSync(extraFile,'utf8'));
 assert(Object.keys(options).length===1&&options.enablePrivateTokens===true);pvtFeatureOverride=true;flags.push('--enable-features=EnablePrivateVerificationTokens');
}
if(probeName==='webgpu-observation-probe.js'&&mode==='neantik-configured')flags.push('--disable-features=WebGPUService');
if(mode==='fury-configured'){
 assert(path.isAbsolute(extraFile));const extras=JSON.parse(fs.readFileSync(extraFile,'utf8'));
 assert(extras.schema_version===1&&Object.keys(extras).every(k=>['schema_version','noise'].includes(k)));
 if(extras.noise){assert(Object.keys(extras.noise).every(k=>['canvasSeed','audioSeed'].includes(k)));for(const v of Object.values(extras.noise))assert(Number.isInteger(v)&&v>=0&&v<=2147483647);}
 config=extras;const file=path.join(root,'synthetic-config.json');fs.writeFileSync(file,JSON.stringify(config),{mode:0o600});configFD=fs.openSync(file,'r');flags.push('--fury-fp-fd=3');
}
if(extensionFixture){
 const dir=path.join(root,'owned-extension');fs.mkdirSync(dir,{mode:0o700});
 const manifest={manifest_version:3,name:'NeAntik owned WebRTC control',version:'1.0',permissions:['privacy'],background:{service_worker:'background.js'}};
 fs.writeFileSync(path.join(dir,'manifest.json'),JSON.stringify(manifest),{mode:0o600});
 fs.writeFileSync(path.join(dir,'background.js'),'chrome.runtime.onInstalled.addListener(()=>{});',{mode:0o600});
 fs.writeFileSync(path.join(dir,'probe.html'),'<!doctype html><meta charset="utf-8"><body data-own-extension="'+fixtureNonce+'"><script src="probe.js"></script>',{mode:0o600});
 const script=fs.readFileSync(path.join(home,'webrtc-extension-receipt.js'),'utf8').replace('OWN_POLICY_MODE',JSON.stringify(managedPolicyFixture));fs.writeFileSync(path.join(dir,'probe.js'),script,{mode:0o600});
 flags.splice(flags.indexOf('--disable-extensions'),1);flags.push('--load-extension='+dir,'--disable-extensions-except='+dir);
 if(managedPolicyFixture)fs.writeFileSync(path.join(root,'Local State'),JSON.stringify({local_test_policies_for_next_startup:JSON.stringify([{level:1,scope:0,source:1,namespace:'chrome',name:'WebRtcIPHandling',value:'default'}])}),{mode:0o600});
}
async function connect(url){const u=new URL(url);assert(u.hostname==='127.0.0.1'&&u.protocol==='ws:');return await new Promise((ok,fail)=>{const socket=new WebSocket(url);const t=setTimeout(()=>{socket.close();fail(Error('CDP connect timeout'));},10000);socket.addEventListener('open',()=>{clearTimeout(t);ok(socket);},{once:true});socket.addEventListener('error',()=>{clearTimeout(t);fail(Error('CDP connect failed'));},{once:true});});}
async function command(socket,method,params={},sessionId=null){return await new Promise((ok,fail)=>{const id=++sequence;const t=setTimeout(()=>{socket.removeEventListener('message',on);fail(Error('CDP command timeout'));},45000);function on(e){let d;try{d=JSON.parse(e.data);}catch{return;}if(d.id!==id)return;clearTimeout(t);socket.removeEventListener('message',on);d.error?fail(Error('CDP error')):ok(d.result);}socket.addEventListener('message',on);socket.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}: {})}));});}
function exited(){return !child||startError||child.exitCode!==null||child.signalCode!==null;}
async function waitExit(ms){const deadline=Date.now()+ms;while(!exited()&&Date.now()<deadline)await delay(100);return exited();}
function ownCount(){const r=spawnSync('/bin/ps',['-axo','pgid=,command='],{encoding:'utf8'});assert.equal(r.status,0);const rows=r.stdout.trim().split('\n');return rows.filter(line=>{const m=line.trim().match(/^(\d+)\s+(.*)$/);return m&&(Number(m[1])===group||(` ${m[2]} `).includes(` --user-data-dir=${root} `));}).length;}
try{
 if(contextProbe||dprEmulation){crossServer=http.createServer((req,res)=>{ownHandler(req,res).catch(()=>{res.statusCode=500;res.end('Own fixture error');});});await new Promise((ok,fail)=>{crossServer.once('error',fail);crossServer.listen(0,'127.0.0.1',ok);});crossOrigin=`http://localhost:${crossServer.address().port}`;}
 await new Promise((ok,fail)=>{server.once('error',fail);server.listen(0,'127.0.0.1',ok);});const origin=`http://127.0.0.1:${server.address().port}`;
 ownOrigin=origin;
 if(webrtcProbe){
  stunServer=dgram.createSocket('udp4');stunServer.on('message',(packet,rinfo)=>{if(packet.length<20||packet.readUInt16BE(0)!==1||packet.readUInt32BE(4)!==0x2112a442)return;stunRequests++;const out=Buffer.alloc(32);out.writeUInt16BE(0x0101,0);out.writeUInt16BE(12,2);packet.copy(out,4,4,20);out.writeUInt16BE(0x0020,20);out.writeUInt16BE(8,22);out[25]=1;out.writeUInt16BE(rinfo.port^0x2112,26);out.writeUInt32BE((0x7f000001^0x2112a442)>>>0,28);stunServer.send(out,rinfo.port,'127.0.0.1');});
  await new Promise((ok,fail)=>{stunServer.once('error',fail);stunServer.bind(0,'127.0.0.1',ok);});stunPort=stunServer.address().port;
  if(!mode.endsWith('-direct')){
   proxyServer=http.createServer((req,res)=>{let u;try{u=new URL(req.url);assert(u.origin===origin);}catch{res.writeHead(403);res.end();return;}proxyRequests++;const upstream=http.request(u,{method:req.method,headers:{...req.headers,connection:'close'}},incoming=>{res.writeHead(incoming.statusCode,incoming.headers);incoming.pipe(res);});upstream.once('error',()=>{res.writeHead(502);res.end();});req.pipe(upstream);});
   await new Promise((ok,fail)=>{proxyServer.once('error',fail);proxyServer.listen(0,'127.0.0.1',ok);});
   flags.push('--proxy-server=http://127.0.0.1:'+proxyServer.address().port,'--proxy-bypass-list=<-loopback>','--webrtc-ip-handling-policy=disable_non_proxied_udp');
   const preferences={webrtc:{ip_handling_policy:'default',ip_handling_url:mode==='webrtc-url-override'?[{url:'http://127.0.0.1:*',handling:'default'}]:[]}};fs.mkdirSync(path.join(root,'Default'));fs.writeFileSync(path.join(root,'Default/Preferences'),JSON.stringify(preferences),{mode:0o600});
  }else flags.push('--webrtc-ip-handling-policy=default');
  if(mode.includes('localip')){const dir=path.join(root,'Default');fs.mkdirSync(dir,{recursive:true});const preferences={webrtc:{ip_handling_policy:'default',local_ips_allowed_urls:['http://127.0.0.1:*']}};fs.writeFileSync(path.join(dir,'Preferences'),JSON.stringify(preferences),{mode:0o600});}

 }
 if(dprProbe){
  assert(path.isAbsolute(extraFile));const extras=JSON.parse(fs.readFileSync(extraFile,'utf8'));
  assert(Object.keys(extras).length===1&&[1,1.25,0.8].includes(extras.zoomFactor));
  const preferences={partition:{default_zoom_level:{x:Math.log(extras.zoomFactor)/Math.log(1.2)}}};
  const folder=path.join(root,'Default');fs.mkdirSync(folder,{recursive:true});const serialized=JSON.stringify(preferences);fs.writeFileSync(path.join(folder,'Preferences'),serialized,{mode:0o600});
  zoomPreferenceReceipt={zoomFactor:extras.zoomFactor,partitionKey:'x',zoomLevel:preferences.partition.default_zoom_level.x,preferencesSHA256:crypto.createHash('sha256').update(serialized).digest('hex'),source:'owned prelaunch native Preferences'};
 }
 phase='spawn';diagnosticFD=fs.openSync(path.join(root,'own-runtime-stderr.log'),'wx',0o600);child=spawn(executable,[`--user-data-dir=${root}`,...flags,origin+'/'],{env,stdio:configFD===null?['ignore','ignore',diagnosticFD]:['ignore','ignore',diagnosticFD,configFD],detached:true});fs.closeSync(diagnosticFD);diagnosticFD=null;if(configFD!==null){fs.closeSync(configFD);configFD=null;}group=child.pid;child.once('error',()=>{startError=true;});
 phase='readiness';let port;const deadline=Date.now()+30000;
 while(Date.now()<deadline){const p=path.join(root,'DevToolsActivePort');if(fs.existsSync(p)){port=Number(fs.readFileSync(p,'utf8').split('\n')[0]);if(Number.isInteger(port)&&port>0&&port<=65535)break;port=undefined;}assert(!exited(),'Own browser exited before readiness');await delay(100);}
 assert(port,'Own CDP readiness timeout');phase='version';const v=await(await fetch(`http://127.0.0.1:${port}/json/version`,{signal:AbortSignal.timeout(3000)})).json();
 const runtimeVersion=v.Browser?.match(/^[^/]+\/(\d+\.\d+\.\d+\.\d+)$/)?.[1];assert.equal(runtimeVersion,packagedVersion);
 phase='browser-CDP';browser=await connect(v.webSocketDebuggerUrl);let target;
 for(let i=0;i<100;i++){const ts=await(await fetch(`http://127.0.0.1:${port}/json/list`,{signal:AbortSignal.timeout(3000)})).json();target=ts.find(t=>t.type==='page'&&t.url===origin+'/');if(target)break;await delay(100);}
 assert(target,'Own headed page missing');phase='page-CDP';page=await connect(target.webSocketDebuggerUrl);
 if(extensionFixture){
  phase='extension-receipt';let extensionTarget;for(let i=0;i<100;i++){const list=await command(browser,'Target.getTargets');extensionTarget=list.targetInfos.find(t=>t.type==='service_worker'&&/^chrome-extension:\/\/[a-p]{32}\/background\.js$/.test(t.url));if(extensionTarget)break;await delay(100);}
  assert(extensionTarget,'Owned extension target missing');const extensionURL=new URL(extensionTarget.url);const extensionOrigin=extensionURL.protocol+'//'+extensionURL.host;const created=await command(browser,'Target.createTarget',{url:extensionOrigin+'/probe.html'});const attached=await command(browser,'Target.attachToTarget',{targetId:created.targetId,flatten:true});
  try{let data;for(let i=0;i<100;i++){data=await command(browser,'Runtime.evaluate',{expression:'globalThis.OWN_EXTENSION_RECEIPT??null',returnByValue:true},attached.sessionId);if(data.result?.value)break;await delay(100);}assert(data.result?.value,'Owned extension receipt missing');extensionEvidence=data.result.value;assert(extensionEvidence.documentNonce===fixtureNonce&&extensionEvidence.runtimeID===extensionURL.host&&extensionEvidence.origin===extensionOrigin,'Owned extension identity mismatch');}finally{await command(browser,'Target.detachFromTarget',{sessionId:attached.sessionId});await command(browser,'Target.closeTarget',{targetId:created.targetId});}
 }
 phase='navigate-owned-fixture';await command(page,'Page.enable');const navigation=await command(page,'Page.navigate',{url:origin+'/'});assert(!navigation.errorText,'Own fixture navigation failed');
 phase='document-ready';
 // Requested Target URL and a body also exist on browser error pages. Bind the
 // loaded document to our actual response before interpreting any Web API.
 const documentDeadline=Date.now()+10000;
 do {const ready=await command(page,'Runtime.evaluate',{expression:'({href:location.href,url:document.URL,origin:location.origin,secure:isSecureContext,ready:document.readyState,marker:document.body?.dataset.ownFixture??null})',returnByValue:true});fixtureDocument=ready.result?.value??null;if(fixtureDocument?.marker===fixtureNonce&&fixtureDocument.ready!=="loading")break;await delay(100);}while(Date.now()<documentDeadline);
 const tree=await command(page,'Page.getFrameTree');const frame=tree.frameTree.frame;
 const fixtureLoaded=fixtureResponses>0&&fixtureDocument?.marker===fixtureNonce&&fixtureDocument?.href===origin+'/'&&fixtureDocument?.url===origin+'/'&&fixtureDocument?.origin===origin&&frame.url===origin+'/'&&frame.securityOrigin===origin&&!frame.unreachableUrl;
 const documentEvidence={loaded:fixtureLoaded,responseCount:fixtureResponses,nonceMatched:fixtureDocument?.marker===fixtureNonce,documentMatches:fixtureDocument?.href===origin+'/'&&fixtureDocument?.url===origin+'/',originMatches:fixtureDocument?.origin===origin,frameMatches:frame.url===origin+'/'&&frame.securityOrigin===origin,unreachable:!!frame.unreachableUrl,secure:fixtureDocument?.secure??null,ready:fixtureDocument?.ready??null};
 fs.writeFileSync(path.join(home,`${label}-document-evidence.json`),JSON.stringify(documentEvidence,null,2)+'\n');
 assert(fixtureLoaded,'Own fixture navigation not proved');
 // Headed geometry observes animation frames; make the owned page foreground
 // instead of changing throttling flags or timing assertions.
 await command(page,'Page.bringToFront');
 if(probeName==='download-operations-probe.js'){phase='download-observer';downloadObserver=new OwnedDownloadObserver(browser,command,origin,root);await downloadObserver.start();}
 if(lifecycleProbe){phase='lifecycle-recorder';lifecycleRecorder=new OwnContextLifecycleRecorder(browser,command,[origin,crossOrigin]);await lifecycleRecorder.start(target.id);}
 phase='evaluate';const result=await command(page,'Runtime.evaluate',{expression:probe,awaitPromise:true,returnByValue:true,userGesture:contextProbe});if(result.exceptionDetails){const e=result.exceptionDetails;console.error(JSON.stringify({ownFixtureError:e.text,line:e.lineNumber,column:e.columnNumber,exceptionClass:e.exception?.className,description:probeName==='geometry-font-probe.js'?e.exception?.description?.slice(0,180):undefined}));}assert(!result.exceptionDetails&&result.result?.value,'Own probe error');
 captured={schemaVersion:1,candidateBindingSHA256:candidateBinding.bindingSHA256,runtimeFrameworkSHA256:digest(candidateBinding.framework),fixtureProvenance,fixtureSourceArchive,label,mode,headed:true,runtimeVersion,executableSHA256:requiredHash,probeSHA256:crypto.createHash('sha256').update(probe).digest('hex'),runnerSHA256:crypto.createHash('sha256').update(fs.readFileSync(fileURLToPath(import.meta.url))).digest('hex'),capturedAt:new Date().toISOString(),platform:process.platform,architecture:process.arch,osVersion:osVersion.stdout.trim(),launchFlags:['--user-data-dir=<owned temporary root>',...flags.map(f=>f.replaceAll(root,'<owned temporary root>'))],syntheticConfiguration:config,extensionEvidence,documentEvidence,ownIdentityReceipts,ownDPRReceipts,zoomPreferenceReceipt,data:result.result.value};
 if(pvtProbe){
  phase='disabled-pvt-raw-CDP';
  const browserVersion=await command(browser,'Browser.getVersion');captured.data={...captured.data,versionEndpoints:{httpProduct:v.Browser,CDPProduct:browserVersion.product},rawResponses:pvtRawResponses};assert.equal(browserVersion.product,v.Browser,'Actual browser CDP version mismatch');
  const observation=await observeDisabledPVT(async(method,params)=>{
   const response=await sendOwnedRawCDP(page,++sequence,method,params);
   pvtRawResponses.push({method,params,targetID:target.id,response});return response;
  },origin+'/');
  captured.data={...captured.data,observation,rawResponses:pvtRawResponses,featureOverride:pvtFeatureOverride,actualHeadedCDPContractVerified:false,runtimeQualified:false,releaseReady:false};const verdict=verifyDisabledPVT(observation);
  captured.data={kind:'disabled-pvt-cdp',ownedOrigin:fixtureDocument.origin,provenDocument:{url:fixtureDocument.url,origin:fixtureDocument.origin,frameURL:frame.url,frameOrigin:frame.securityOrigin},observation,verdict,rawResponses:pvtRawResponses,targetID:target.id,browserProduct:browserVersion.product,featureOverride:pvtFeatureOverride,actualHeadedCDPContractVerified:true,runtimeQualified:false,releaseReady:false};
 }
 if(dprEmulation){
  async function dprNavigationSample(){
   const navigationNonce=crypto.randomUUID(),url=origin+'/?requestNonce='+navigationNonce;
   const nav=await command(page,'Page.navigate',{url});assert(!nav.errorText,'Own fixture navigation failed');
   let ready=false;for(let i=0;i<100;i++){const state=await command(page,'Runtime.evaluate',{expression:'({url:location.href,marker:document.body?.dataset.ownFixture,ready:document.readyState})',returnByValue:true});if(state.result?.value?.url===url&&state.result.value.marker===fixtureNonce&&state.result.value.ready==='complete'){ready=true;break;}await delay(50);}
   assert(ready,'Own fixture navigation not proved');
   const matches=ownDPRReceipts.filter(x=>x.requestNonce===navigationNonce&&x.destination==='document');assert(matches.length===1,'Own navigation receipt missing');
   const sampled=await command(page,'Runtime.evaluate',{expression:probe,awaitPromise:true,returnByValue:true});assert(!sampled.exceptionDetails&&sampled.result?.value,'Own probe error');
   return {data:sampled.result.value,navigationReceipt:matches[0],navigationNonce};
  }
  const observations=[{step:'ordinary',...await dprNavigationSample()}];
  for(const [step,requested,mobile] of [['desktop1',1,false],['desktop3',3,false],['desktop0',0,false],['mobile2',2,true],['clear',null,false]]){
   phase='dpr-emulation-'+step;
   if(requested===null)await command(page,'Emulation.clearDeviceMetricsOverride');
   else await command(page,'Emulation.setDeviceMetricsOverride',{width:900,height:700,deviceScaleFactor:requested,mobile});
   await delay(250);observations.push({step,requestedDSF:requested,mobile,...await dprNavigationSample()});
  }
  captured.data={kind:'dpr-emulation-http-js-css',observations,limitations:['Native headed observation; ordinary OOPIF emulation parity must be measured separately before state propagation changes.']};
 }
 if(lifecycleProbe){captured.data.liveNegativeControl={receipts:lifecycleRecorder.summary(),scope:'actual live independently nonce-bound contexts before teardown; must fail destruction gate'};phase='individual-teardown';const teardown=await command(page,'Runtime.evaluate',{expression:'globalThis.OWN_TEARDOWN()',awaitPromise:true,returnByValue:true});assert(!teardown.exceptionDetails&&Array.isArray(teardown.result?.value),'Own context teardown failed');captured.data.results=teardown.result.value;captured.data.lifecycle=await lifecycleRecorder.finish(target.id);lifecycleRecorder.dispose();}
 if(webrtcProbe){await delay(1000);captured.data.stunRequests=stunRequests;captured.data.proxyRequests=proxyRequests;captured.data.mode=mode;}
 phase='close';let closeAcknowledged=false;try{await command(browser,'Browser.close');closeAcknowledged=true;}catch{}const gracefulParentExit=await waitExit(10000);captured.browserClosure={closeAcknowledged,gracefulParentExit,parentExitCode:child.exitCode,parentSignal:child.signalCode};
}catch(e){let diagnostics=[];const file=path.join(root,'own-runtime-stderr.log');if(fs.existsSync(file)){diagnostics=fs.readFileSync(file,'utf8').split('\n').filter(x=>/dyld|Library not loaded|Reason:|FATAL|snapshot|code signature|No such file/i.test(x)).slice(0,8).map(x=>x.replaceAll(root,'<owned-root>').replaceAll(runtimeApp,'<owned-runtime>').replace(/\/Users\/[^\s:]*/g,'<local-path>').slice(0,350));}console.error(JSON.stringify({failureType:e.name,phase,childExitCode:child?.exitCode,childSignal:child?.signalCode,diagnostics,knownReason:['CDP connect timeout','CDP connect failed','CDP command timeout','CDP error','Own probe error','Own browser exited before readiness','Own CDP readiness timeout','Own headed page missing','Own fixture navigation not proved','Own fixture navigation failed','Owned extension target missing','Owned extension receipt missing','Owned extension identity mismatch'].includes(e.message)?e.message:'redacted unknown error'}));process.exitCode=1;}
finally{
 downloadObserver?.dispose();lifecycleRecorder?.dispose();if(configFD!==null){fs.closeSync(configFD);configFD=null;}page?.close();browser?.close();if(child&&!exited()){child.kill('SIGTERM');if(!await waitExit(5000))child.kill('SIGKILL');}
 await waitExit(3000);const deadline=Date.now()+5000;while(ownCount()&&Date.now()<deadline)await delay(100);
 cleanup=exited()&&ownCount()===0;await new Promise(ok=>server.close(ok));if(crossServer)await new Promise(ok=>crossServer.close(ok));if(proxyServer)await new Promise(ok=>proxyServer.close(ok));if(stunServer)await new Promise(ok=>stunServer.close(ok));
 if(cleanup)fs.rmSync(root,{recursive:true});else{console.error('Own fixture process residue; root retained');process.exitCode=1;}
}
if(captured&&cleanup){assert.equal(digest(candidateBinding.framework),candidateBinding.binding.runtimeFrameworkSHA256);assertFixtureSourcesUnchanged(fixtureProvenance,provenanceFiles);assert.equal(crypto.createHash('sha256').update(fs.readFileSync(executable)).digest('hex'),requiredHash,'Runtime executable changed during observation');if(webrtcProbe){captured.data.stunRequests=stunRequests;captured.data.proxyRequests=proxyRequests;captured.data.countersCapturedAfterServerClose=true;}captured.cleanupVerified=true;fs.writeFileSync(outputPath,JSON.stringify(captured,null,2)+'\n',{flag:'wx',mode:0o600});console.log(JSON.stringify({label,mode,headed:true,runtimeVersion:captured.runtimeVersion,executableSHA256:requiredHash,probeKind:captured.data.kind??'drawing-invariants',canvasCases:Array.isArray(captured.data.canvas)?captured.data.canvas.length:null,audioCases:Array.isArray(captured.data.audio)?captured.data.audio.length:null,probeErrors:captured.data.errors?.length??null,cleanupVerified:true,semanticsVerified:false}));}
else process.exitCode=1;

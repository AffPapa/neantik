// Own nonce-bound HTTPS via loopback proxy; no arbitrary JS evaluation or sites.
import assert from 'node:assert/strict';
import fs from 'node:fs';import path from 'node:path';import crypto from 'node:crypto';
import dgram from 'node:dgram';import https from 'node:https';import http from 'node:http';import net from 'node:net';
import {spawn,spawnSync} from 'node:child_process';import {setTimeout as delay} from 'node:timers/promises';
import {fileURLToPath} from 'node:url';
import {browserFixtureEnvironment} from '../runtime-platform/fixtures/qa-browser-environment.mjs';
import {page,rtcPage,workerSource,serviceWorkerSource} from './probe.mjs';
const project=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const [runtime,output,mode='isolation']=process.argv.slice(2);assert(['isolation','surface','rtc-proxy','rtc-control','override-locked','override-control'].includes(mode));assert(runtime&&output&&path.isAbsolute(runtime)&&path.isAbsolute(output));
assert.equal(fs.realpathSync(runtime),runtime);fs.mkdirSync(output,{mode:0o700});
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const exe=path.join(runtime,'Contents/MacOS/NeAntik Browser');
const expected='be743b4f09d96da901701d3b517e0a64daaac9535150172701c099964902492d';assert.equal(sha(fs.readFileSync(exe)),expected);
assert.equal(spawnSync('/usr/bin/codesign',['--verify','--deep','--strict',runtime],{stdio:'ignore'}).status,0);
const root=fs.mkdtempSync('/private/tmp/neantik-privacy20-qa.');fs.chmodSync(root,0o700);
const report={schemaVersion:1,status:'not-run',runtimeExecutableSHA256:expected,releaseQualified:false,rows:[],sources:{}};
for(const name of ['run.mjs','probe.mjs'])report.sources[name]=sha(fs.readFileSync(path.join(project,'scripts/privacy20',name)));
const evidenceInputs=path.join(output,'source-inputs');fs.mkdirSync(evidenceInputs,{mode:0o700});
for(const name of ['run.mjs','probe.mjs'])fs.copyFileSync(path.join(project,'scripts/privacy20',name),path.join(evidenceInputs,name));
const resources=path.join(project,'Resources/SiteProtection');report.protectionResources=Object.fromEntries(fs.readdirSync(resources).sort().map(name=>[name,sha(fs.readFileSync(path.join(resources,name)))]));
fs.cpSync(resources,path.join(evidenceInputs,'SiteProtection'),{recursive:true});

const save=()=>fs.writeFileSync(path.join(output,'report.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});
let active,origin,proxyEnabled=true,child,pipe,proxy,tlsServer;const sockets=new Set();const connects=[],denied=[],tlsRows=[],cacheHits=[],proxyClients=new Set();let socketSequence=0,udpPackets=0;let udpServer;
const track=s=>{sockets.add(s);s.on('error',()=>{});s.once('close',()=>sockets.delete(s));};
const listen=s=>new Promise((resolve,reject)=>{s.once('error',reject);s.listen(0,'127.0.0.1',resolve)});
const until=async(f,ms)=>{const end=Date.now()+ms;while(Date.now()<end){if(await f())return true;await delay(50)}return false};
class OwnPipe {
 constructor(input,output){this.input=input;this.pending=new Map();this.seq=0;this.buffer='';output.on('data',d=>{this.buffer+=d.toString();let n;while((n=this.buffer.indexOf('\0'))>=0){const raw=this.buffer.slice(0,n);this.buffer=this.buffer.slice(n+1);const m=JSON.parse(raw);if(m.id){const p=this.pending.get(m.id);if(p){this.pending.delete(m.id);clearTimeout(p.timer);m.error?p.reject(Error(m.error.message)):p.resolve(m.result)}}}})}
 command(method,params={},sessionId){assert(['Browser.getVersion','Target.createTarget','Target.attachToTarget','Page.enable','Page.navigate','Browser.setDownloadBehavior','Browser.close'].includes(method));if(method==='Browser.setDownloadBehavior')assert.deepEqual(params,{behavior:'allow',downloadPath:active.downloadDirectory});if(method==='Target.createTarget')assert.deepEqual(params,{url:'about:blank'});if(method==='Page.navigate')assert.equal(params.url,active.url);return new Promise((resolve,reject)=>{const id=++this.seq;const timer=setTimeout(()=>{this.pending.delete(id);reject(Error('owned CDP timeout'))},10000);this.pending.set(id,{resolve,reject,timer});this.input.write(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})})+'\0')})}
 close(){for(const p of this.pending.values()){clearTimeout(p.timer);p.reject(Error('closed'))}this.pending.clear()}
}
try{
 udpServer=dgram.createSocket('udp4');udpServer.on('message',(message,peer)=>{assert.equal(peer.address,'127.0.0.1');udpPackets++;if(message.length<20||message.readUInt32BE(4)!==0x2112a442)return;const answer=Buffer.alloc(32);answer.writeUInt16BE(0x0101,0);answer.writeUInt16BE(12,2);answer.writeUInt32BE(0x2112a442,4);message.copy(answer,8,8,20);answer.writeUInt16BE(0x0020,20);answer.writeUInt16BE(8,22);answer[25]=1;answer.writeUInt16BE(peer.port^0x2112,26);answer.writeUInt32BE((0x7f000001^0x2112a442)>>>0,28);udpServer.send(answer,peer.port,'127.0.0.1')});await new Promise(resolve=>udpServer.bind(0,'127.0.0.1',resolve));
 const config=path.join(root,'certificate.cnf');fs.writeFileSync(config,'[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=Owned NeAntik privacy20 QA\n[ext]\nsubjectAltName=DNS:a.qa.invalid,DNS:b.qa.invalid\nbasicConstraints=critical,CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n',{mode:0o600});
 const key=path.join(root,'key.pem'),cert=path.join(root,'cert.pem');assert.equal(spawnSync('/usr/bin/openssl',['req','-x509','-newkey','rsa:2048','-nodes','-days','1','-config',config,'-keyout',key,'-out',cert],{stdio:'ignore'}).status,0);fs.chmodSync(key,0o600);
 const certificate=fs.readFileSync(cert),spki=crypto.createHash('sha256').update(new crypto.X509Certificate(certificate).publicKey.export({format:'der',type:'spki'})).digest('base64');
 tlsServer=https.createServer({key:fs.readFileSync(key),cert:certificate,minVersion:'TLSv1.2',maxVersion:'TLSv1.2'},async(req,res)=>{
  try{const u=new URL(req.url,origin);res.setHeader('Cache-Control','no-store');if(!active){res.writeHead(404);res.end();return}
   if(u.pathname==='/owned-http-cache'){cacheHits.push({phase:active.phase});res.setHeader('Cache-Control','private,max-age=3600');res.setHeader('Content-Type','text/plain');res.end(active.marker);return}
   if(u.pathname==='/owned-connection'||u.pathname==='/owned-tls-close'){res.setHeader('Content-Type','application/json');if(u.pathname==='/owned-tls-close')res.setHeader('Connection','close');res.end(JSON.stringify({socket:req.socket.ownQAID,reused:req.socket.isSessionReused()}));return}
   if(u.pathname==='/begin-failure'){res.setHeader('Connection','close');res.end('own failure scheduled');setTimeout(()=>{proxyEnabled=false;for(const c of proxyClients)c.destroy();setTimeout(()=>{proxyEnabled=true},1800)},30);return}
   if(u.pathname==='/owned-download'){res.setHeader('Content-Disposition','attachment; filename="owned-test.txt"');res.setHeader('Content-Type','text/plain');res.end('OWN_DOWNLOAD '+active.nonce);return}
   if(u.pathname==='/owned-keepalive'||u.pathname==='/owned-worker-network'){res.end('owned-network-ok');return}
   if(u.pathname==='/failure-check'||u.pathname==='/recovery'){res.end('own recovery');return}

   if(u.pathname==='/result'&&req.method==='POST'){assert.equal(req.headers.origin,origin);assert.equal(u.searchParams.get('nonce'),active.nonce);let raw='';for await(const d of req){raw+=d;assert(raw.length<65536)}const value=JSON.parse(raw);assert.equal(value.nonce,active.nonce);assert.equal(active.result,null);active.result=value;res.end('ok');return}
   res.setHeader('Content-Type',u.pathname.endsWith('.js')?'text/javascript':'text/html;charset=utf-8');
   if(u.pathname==='/owned-worker.js')res.end(workerSource);else if(u.pathname==='/owned-sw.js')res.end(serviceWorkerSource);else {assert.equal(u.pathname,'/probe');assert.equal(u.searchParams.get('nonce'),active.nonce);res.end(mode.startsWith('rtc-')?rtcPage(active.nonce,udpServer.address().port):page(active.nonce,active.phase,active.marker))}
  }catch{res.writeHead(400);res.end()}
 });tlsServer.on('upgrade',(req,socket)=>{if(req.url!=='/owned-ws'||typeof req.headers['sec-websocket-key']!=='string'){socket.destroy();return}const accept=crypto.createHash('sha1').update(req.headers['sec-websocket-key']+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+'\r\n\r\n');const body=Buffer.from('owned-websocket-ok');socket.write(Buffer.concat([Buffer.from([0x81,body.length]),body]));socket.on('data',()=>{socket.end(Buffer.from([0x88,0]))})});tlsServer.on('connection',track);tlsServer.on('secureConnection',socket=>{socket.ownQAID=++socketSequence;tlsRows.push({phase:active?.phase,socket:socket.ownQAID,reused:socket.isSessionReused()})});await listen(tlsServer);origin='https://a.qa.invalid:'+tlsServer.address().port;
 proxy=http.createServer((_q,s)=>{s.writeHead(403);s.end()});proxy.on('connection',track);
 proxy.on('connect',(req,client,head)=>{proxyClients.add(client);client.once('close',()=>proxyClients.delete(client));const allowed=proxyEnabled&&req.url==='a.qa.invalid:'+tlsServer.address().port;if(!allowed){denied.push({phase:active?.phase,authority:req.url});client.end('HTTP/1.1 403 Forbidden\r\n\r\n');return}connects.push({phase:active?.phase,authority:req.url});const upstream=net.connect(tlsServer.address().port,'127.0.0.1',()=>{client.write('HTTP/1.1 200 Connection Established\r\n\r\n');if(head.length)upstream.write(head);upstream.pipe(client);client.pipe(upstream)});track(upstream)});await listen(proxy);
 for(const profile of ['A','B'])fs.mkdirSync(path.join(root,profile),{mode:0o700});
 const markers={A:crypto.randomBytes(16).toString('hex'),B:crypto.randomBytes(16).toString('hex')};
 for(const [phase,name] of (mode!=='isolation'?[['A1','A']]:[['A1','A'],['B1','B'],['A2','A']])){
  const admission=spawnSync('/usr/local/bin/python3',['-B',path.join(project,'scripts/native-qa-readiness.py'),'--check'],{encoding:'utf8'});report.admission=JSON.parse(admission.stdout);assert.equal(admission.status,0,'native resource gate refused');
  const extension=path.join(root,'extension-'+phase);fs.cpSync(path.join(project,'Resources/SiteProtection'),extension,{recursive:true});fs.rmSync(path.join(extension,'seal.json'));
  if(mode.startsWith('override-')){
    const manifestPath=path.join(extension,'manifest.json'),manifest=JSON.parse(fs.readFileSync(manifestPath));manifest.permissions.push('proxy');fs.writeFileSync(manifestPath,JSON.stringify(manifest));
    fs.appendFileSync(path.join(extension,'worker.mjs'),`\n(async()=>{try{await chrome.proxy.settings.set({value:{mode:'direct'},scope:'regular'});const result=await chrome.proxy.settings.get({incognito:false});console.error('OWN_PROXY_OVERRIDE mode='+result.value.mode+' control='+result.levelOfControl)}catch{console.error('OWN_PROXY_OVERRIDE refused')}})();\n`);
    const overlay=path.join(evidenceInputs,'OverrideOverlay');fs.cpSync(extension,overlay,{recursive:true});
  }

  active={phase,marker:markers[name],nonce:crypto.randomBytes(16).toString('hex'),result:null};active.url=origin+'/probe?nonce='+active.nonce;active.downloadDirectory=path.join(root,'downloads-'+phase);fs.mkdirSync(active.downloadDirectory,{mode:0o700});
  const args=[`--user-data-dir=${path.join(root,name)}`,'--use-mock-keychain','--no-first-run','--no-default-browser-check','--new-window','--remote-debugging-pipe','--enable-logging=stderr','--disable-background-networking','--disable-component-update','--disable-sync','--disable-quic','--webrtc-ip-handling-policy=disable_non_proxied_udp',`--proxy-server=http://127.0.0.1:${proxy.address().port}`,'--proxy-bypass-list=<-loopback>','--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1','--disable-features=AsyncDns,DnsOverHttpsUpgrade,DirectSockets,DirectSocketsInSharedWorkers,DirectSocketsInServiceWorkers,WebGPUService','--enable-features=LocalNetworkAccessChecks,LocalNetworkAccessChecksWebRTC,DIPS',`--ignore-certificate-errors-spki-list=${spki}`,`--load-extension=${extension}`,`--disable-extensions-except=${extension}`,'about:blank'];
  const env={...browserFixtureEnvironment(),NEANTIK_PROFILE_PROXY_REQUIRED:'1',NEANTIK_PROFILE_SEED:name==='A'?'22':'33',NEANTIK_FONT_POLICY:'system-v1',NEANTIK_PROFILE_TIMEZONE:'Europe/London',NEANTIK_PROFILE_RTC:'off',NEANTIK_PROFILE_LAN:'deny',NEANTIK_PROFILE_MEDIA:'deny',NEANTIK_PROFILE_GRAPHICS:'minimal',NEANTIK_PROFILE_VIEWPORT:'standard',NEANTIK_PROFILE_AUTOFILL:'off',NEANTIK_PROFILE_PRIVACY_EXTENSION_ID:'amkgfbjfocbfnpeamfekgijcnfnegndh',NEANTIK_PROFILE_PRIVACY_BASELINE_RULES:'253',NEANTIK_PROFILE_QUERY_CLEANUP:'1'};
  if(mode.startsWith('rtc-'))delete env.NEANTIK_PROFILE_RTC;
  if(mode==='override-control')delete env.NEANTIK_PROFILE_PROXY_REQUIRED;
  if(mode==='rtc-control'){delete env.NEANTIK_PROFILE_LAN;const i=args.indexOf('--webrtc-ip-handling-policy=disable_non_proxied_udp');assert(i>=0);args[i]='--webrtc-ip-handling-policy=default_public_interface_only';}
  const log=fs.openSync(path.join(output,phase+'-private.log'),'wx',0o600);child=spawn(exe,args,{env,stdio:['ignore','ignore',log,'pipe','pipe'],detached:true});await new Promise((resolve,reject)=>{child.once('spawn',resolve);child.once('error',reject)});pipe=new OwnPipe(child.stdio[3],child.stdio[4]);
  assert.equal((await pipe.command('Browser.getVersion')).product.split('/').at(-1),'156.0.8078.80');if(mode.startsWith('override-'))await delay(1000);await pipe.command('Browser.setDownloadBehavior',{behavior:'allow',downloadPath:active.downloadDirectory});const target=await pipe.command('Target.createTarget',{url:'about:blank'});const {sessionId}=await pipe.command('Target.attachToTarget',{targetId:target.targetId,flatten:true});await pipe.command('Page.enable',{},sessionId);const nav=await pipe.command('Page.navigate',{url:active.url},sessionId);if(mode==='override-control'){
    assert.equal(nav.errorText,'net::ERR_NAME_NOT_RESOLVED');
    assert(await until(()=>fs.readFileSync(path.join(output,phase+'-private.log'),'utf8').includes('OWN_PROXY_OVERRIDE mode=direct control=controlled_by_this_extension'),3000),'proxy override positive control not applied');
    report.rows.push({phase,proxyPreference:'controlled extension direct',navigation:'name-not-resolved after proxy override',actualBrowser:true});
    await pipe.command('Browser.close').catch(()=>{});assert(await until(()=>child.exitCode!==null||child.signalCode!==null,10000));assert.equal(child.exitCode,0);pipe.close();pipe=null;child=null;fs.closeSync(log);continue;
  }
  assert(!nav.errorText,nav.errorText);assert(await until(()=>active.result!==null,30000),'synthetic page timed out');
  const r=active.result;report.rows.push(r);save();if(mode==='override-locked')assert(fs.readFileSync(path.join(output,phase+'-private.log'),'utf8').includes('OWN_PROXY_OVERRIDE mode=direct control=controlled_by_this_extension'),'hostile extension never controlled prefs');assert.equal(r.status,'observed');
  if(mode.startsWith('rtc-')){
    assert.equal(r.rtc,'created');assert.equal(r.webTransport,'rejected');
    if(mode==='rtc-proxy')assert.equal(udpPackets,0,'non-proxied UDP escaped');else assert(udpPackets>0,'UDP positive control did not reach owned responder');
  }else {
assert.equal(r.rtc,'NotAllowedError');assert.equal(r.webgl,true);assert.equal(r.debugRenderer,false);assert.equal(r.debugEnumerated,false);assert(r.geometry.innerWidth%200===0&&r.geometry.innerHeight%100===0);assert.equal(r.timezone,'Europe/London');assert(Object.values(r.lan).every(x=>x==='rejected'));assert.equal(r.tracker,'rejected');assert(Object.values(r.permissions).every(x=>x==='denied'));assert(r.fontVectors.every(x=>x.width>0));assert.equal(r.websocket,'owned-websocket-ok');assert.equal(r.keepalive,'owned-network-ok');assert.equal(r.worker.fetch,'owned-network-ok');assert.equal(r.worker.websocket,'rejected');
  const download=path.join(active.downloadDirectory,'owned-test.txt');assert(await until(()=>fs.existsSync(download),5000),'owned download absent');assert.equal(fs.readFileSync(download,'utf8'),'OWN_DOWNLOAD '+active.nonce);
  assert(r.httpCache.every(x=>x===markers[name]));assert.equal(cacheHits.filter(x=>x.phase===phase).length,phase==='A2'?0:1);
  assert.equal(r.connections[0].socket,r.connections[1].socket,'within-profile connection reuse positive control');
  assert.equal(tlsRows.find(x=>x.phase===phase)?.reused,false,'first connection may not resume another process');
  assert.equal(r.tlsSecond.reused,true,'within-profile TLS1.2 resumption positive control');
  if(phase==='A2'){assert.equal(r.proxyFailure,'rejected');assert.equal(r.proxyRecovery,true)}

  if(phase!=='A2'){assert.equal(r.before.local,null);assert.equal(r.before.idb,null);assert.equal(r.before.cache,null);assert(!r.before.cookie.includes('owned_marker='))}else{assert.equal(r.before.local,markers.A);assert.equal(r.before.idb,markers.A);assert.equal(r.before.cache,markers.A);assert(r.before.cookie.includes(markers.A))}
  }
  await pipe.command('Browser.close').catch(()=>{});assert(await until(()=>child.exitCode!==null||child.signalCode!==null,10000),'browser did not close');assert.equal(child.exitCode,0);pipe.close();pipe=null;child=null;fs.closeSync(log);
 }
 assert(!connects.some(x=>!x.authority.startsWith('a.qa.invalid:')));assert(!denied.some(x=>/127\.0\.0\.1|localhost|192\.168\.1\.1|doubleclick/.test(x.authority)),'blocked destinations reached proxy');
 report.status='scoped-pass';report.mode=mode;report.udpPackets=udpPackets;report.networkState={protocol:'TLS1.2 synthetic server only',tlsRows,cacheHits};report.scope=['mainframe WebSocket through proxy','dedicated-worker and keepalive HTTP','worker WebSocket explicitly rejected','download exact bytes in owned directory','HTTP diskcache A-B-A','per-process TLS session/socket separation with positive reuse controls','proxy failure and recovery','RTC constructor off','literal LAN guard','WebGL debug renderer hidden','letterbox dimensions','timezone main/worker','cookies/localStorage/IndexedDB/CacheStorage A-B-A','service worker per-profile registration','media permission deny','font seven script width smoke','third-party tracker block before proxy'];if(mode.startsWith('rtc-'))report.scope=[mode==='rtc-proxy'?'RTC constructor enabled with fixedproxy; owned STUN UDP zero':'UDP fixture positive control with ordinary RTC policy/LAN unset', 'WebTransport refuses non-direct proxy route'];if(mode.startsWith('override-'))report.scope=[mode==='override-locked'?'Extension proxy prefs controlled direct while native mandatory route still reached own proxy':'Ordinary runtime accepts extension direct override positive control'];if(mode==='surface')report.scope=report.scope.filter(x=>!x.includes('A-B-A')&&!x.includes('separation')&&!x.includes('failure and recovery'));report.unverified=['DNS/UDP packet-wide leakage','TCP TURN media success unmeasured','font origin canary/language glyph correctness','manager integration','malware/phishing negative controls','production readiness'];
}catch(e){report.status='failed';report.failure={name:e.name,message:String(e.message).slice(0,300)};process.exitCode=1}
finally{
 if(pipe)await pipe.command('Browser.close').catch(()=>{});if(child&&!await until(()=>child.exitCode!==null||child.signalCode!==null,5000)){try{process.kill(-child.pid,'SIGTERM')}catch{}}
 if(udpServer)await new Promise(resolve=>udpServer.close(resolve));for(const s of sockets)s.destroy();for(const s of [proxy,tlsServer])if(s)await new Promise(resolve=>s.close(resolve));
 report.connects=connects;report.denied=denied;report.finishedAt=new Date().toISOString();save();
 // Synthetic TLS key and browser roots never enter evidence or source.
 if(!child||await until(()=>child.exitCode!==null||child.signalCode!==null,3000)){if(report.status==='scoped-pass')fs.rmSync(root,{recursive:true});else report.privateDiagnosticRoot=root;}save();
}
console.log(JSON.stringify({status:report.status,rows:report.rows.length,releaseQualified:false}));

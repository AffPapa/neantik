// Headed signed runtime QA, fixed local pages only. No production profile or MCP.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import http from 'node:http';
import {spawn,spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';
import {WEBRTC_CASES,PREF_KEYS,storedPreferences,verifyWebRTCCase,verifyWebRTCSuite} from './webrtc-boundary-semantics.mjs';
import {WebRTCBoundaryPipe,DOCUMENT_READY,PREFERENCE_READ,EXTENSION_READ,WEBRTC_PROBE} from './webrtc-boundary-pipe.mjs';
import {OwnedSTUNFixture} from './webrtc-stun-fixture.mjs';
import {verifyMachOClosure} from '../runtime-platform/fixtures/font-runtime-closure.mjs';
import {browserFixtureEnvironment} from '../runtime-platform/fixtures/qa-browser-environment.mjs';

const args=process.argv.slice(2),options={};
while(args.length){const key=args.shift();assert(['--app','--binding','--output','--case','--resume'].includes(key)&&!Object.hasOwn(options,key));options[key]=key==='--resume'?true:args.shift();}
for(const key of ['--app','--binding','--output'])assert(typeof options[key]==='string'&&path.isAbsolute(options[key]));
const runtime=fs.realpathSync(options['--app']);assert.equal(runtime,options['--app']);
const output=options['--output'];
if(!options['--resume'])fs.mkdirSync(output,{mode:0o700});
const outputStat=fs.lstatSync(output);assert(outputStat.isDirectory()&&!outputStat.isSymbolicLink()&&outputStat.uid===process.getuid()&&(outputStat.mode&0o777)===0o700);
const sha=bytes=>crypto.createHash('sha256').update(bytes).digest('hex'),digest=file=>sha(fs.readFileSync(file));
const bindingFile=options['--binding'],binding=JSON.parse(fs.readFileSync(bindingFile));binding.bindingSHA256=digest(bindingFile);
const executable=path.join(runtime,'Contents/MacOS/NeAntik Browser');
assert(/^Contents\/Frameworks\/[^\0]+$/.test(binding.runtimeFrameworkRelativePath)&&!binding.runtimeFrameworkRelativePath.split('/').includes('..'));
const framework=path.join(runtime,binding.runtimeFrameworkRelativePath);
const rootProject=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const sourceFiles=['scripts/runtime-network/run-webrtc-boundaries.mjs','scripts/runtime-network/webrtc-boundary-pipe.mjs',
  'scripts/runtime-network/webrtc-boundary-semantics.mjs','scripts/runtime-network/webrtc-boundary-probe.js',
  'scripts/runtime-network/webrtc-extension-receipt.js','scripts/runtime-network/webrtc-stun-fixture.mjs',
  'scripts/runtime-platform/fixtures/font-lifecycle-pipe.mjs','scripts/runtime-platform/fixtures/qa-browser-environment.mjs',
  'scripts/runtime-platform/fixtures/font-runtime-closure.mjs','scripts/native-qa-readiness.py'];
const sourceSHA256=Object.fromEntries(sourceFiles.map(name=>[name,digest(path.join(rootProject,name))]));
const write=(name,value)=>fs.writeFileSync(path.join(output,name),JSON.stringify(value,null,2)+'\n',{flag:'wx',mode:0o600});
function inputsUnchanged(){
  assert.equal(digest(bindingFile),binding.bindingSHA256);assert.equal(digest(executable),binding.runtimeExecutableSHA256);
  assert.equal(digest(framework),binding.runtimeFrameworkSHA256);
  for(const [name,hash]of Object.entries(sourceSHA256))assert.equal(digest(path.join(rootProject,name)),hash);
}
function inventory(){
  const result=spawnSync('/bin/ps',['-axo','pid=,pgid=,uid=,comm='],{encoding:'utf8'});assert.equal(result.status,0);
  return result.stdout.split('\n').flatMap(line=>{const m=line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(.+)$/);return m?[{pid:+m[1],group:+m[2],uid:+m[3],executable:m[4]}]:[];});
}
const owned=()=>inventory().filter(item=>item.executable.startsWith(runtime+'/Contents/'));
const until=async(test,ms)=>{const deadline=Date.now()+ms;while(Date.now()<deadline){if(await test())return true;await delay(70);}return false;};
const environment=browserFixtureEnvironment();
const os=spawnSync('/usr/bin/sw_vers',['-productVersion'],{encoding:'utf8'});assert.equal(os.status,0);assert.equal(os.stdout.trim(),binding.macOS);
assert.equal(process.arch,'arm64');assert.equal(binding.architecture,'arm64');assert.equal(binding.schemaVersion,1);
inputsUnchanged();verifyMachOClosure(runtime,binding.machO);
assert.equal(sha(Buffer.from(JSON.stringify(Object.entries(binding.machO).sort()))),binding.machOClosureSHA256);
assert.equal(spawnSync('/usr/bin/codesign',['--verify','--deep','--strict',runtime],{stdio:'ignore'}).status,0);
if(!options['--resume']){
  fs.mkdirSync(path.join(output,'source-inputs'),{mode:0o700});
  for(const [name,hash]of Object.entries(sourceSHA256))fs.writeFileSync(path.join(output,'source-inputs',hash),fs.readFileSync(path.join(rootProject,name)),{mode:0o600,flag:'wx'});
  write('inputs.json',{bindingSHA256:binding.bindingSHA256,sourceSHA256,macOS:binding.macOS,nodeVersion:process.version});
}else assert.deepEqual(JSON.parse(fs.readFileSync(path.join(output,'inputs.json'))),{bindingSHA256:binding.bindingSHA256,sourceSHA256,macOS:binding.macOS,nodeVersion:process.version});

async function run(spec){
  const row={id:spec.id,actualBrowser:false,headed:true,...Object.fromEntries(['runtimeExecutableSHA256','runtimeFrameworkSHA256','machOClosureSHA256','bindingSHA256'].map(key=>[key,binding[key]])),
    preferences:{},extension:null,proxyRequests:0,sourceSHA256,startedAt:new Date().toISOString()};
  let profile,profileStat,child,pipe,stderr,originServer,proxyServer,stun,forced=false,graceful=false;
  const sockets=new Set(),nonce=crypto.randomBytes(16).toString('hex');let origin,extensionOrigin=null;
  const track=server=>server.on('connection',socket=>{sockets.add(socket);socket.once('close',()=>sockets.delete(socket));});
  let failure;
  try{
    inputsUnchanged();assert.equal(owned().length,0,'Another process uses the selected runtime');
    const readiness=spawnSync('/usr/local/bin/python3',['-B',path.join(rootProject,'scripts/native-qa-readiness.py'),'--check'],{encoding:'utf8'});
    row.readiness=JSON.parse(readiness.stdout);assert.equal(readiness.status,0,'Native resource admission refused');
    assert.equal(row.readiness.memoryPressure,0);assert.equal(row.readiness.thermalState,0);
    profile=fs.mkdtempSync('/private/tmp/neantik-webrtc-boundary-');fs.chmodSync(profile,0o700);profileStat=fs.lstatSync(profile);
    stun=await new OwnedSTUNFixture().start();row.collector=await stun.verifyAndReset();
    originServer=http.createServer((request,response)=>{
      response.setHeader('Cache-Control','no-store');
      if(request.method!=='GET'){response.writeHead(405);response.end();return;}
      if(request.url==='/stun-config'){
        response.setHeader('Content-Type','application/json');response.end(JSON.stringify({url:'stun:127.0.0.1:'+stun.port,nonce}));return;
      }
      if(request.url!=='/'){response.writeHead(404);response.end();return;}
      response.setHeader('Content-Type','text/html');response.end('<!doctype html><title>OWN WebRTC '+spec.id+'</title><body data-own-fixture="'+nonce+'">Owned WebRTC policy fixture</body>');
    });track(originServer);
    await new Promise((resolve,reject)=>{originServer.once('error',reject);originServer.listen(0,'127.0.0.1',resolve);});
    origin='http://127.0.0.1:'+originServer.address().port;
    const flags=['--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-sync','--disable-component-update',
      '--use-mock-keychain','--remote-debugging-pipe','--new-window'];
    if(spec.guarded){
      proxyServer=http.createServer((request,response)=>{
        let url;try{url=new URL(request.url);assert.equal(url.origin,origin);assert(request.method==='GET'&&['/','/stun-config','/favicon.ico'].includes(url.pathname));}
        catch{response.writeHead(403);response.end();return;}
        row.proxyRequests++;
        const upstream=http.request(url,{headers:{...request.headers,connection:'close'}},incoming=>{response.writeHead(incoming.statusCode,incoming.headers);incoming.pipe(response);});
        upstream.once('error',()=>{response.writeHead(502);response.end();});request.pipe(upstream);
      });track(proxyServer);proxyServer.on('connect',(_req,socket)=>socket.destroy());
      await new Promise((resolve,reject)=>{proxyServer.once('error',reject);proxyServer.listen(0,'127.0.0.1',resolve);});
      flags.push('--proxy-server=http://127.0.0.1:'+proxyServer.address().port,'--proxy-bypass-list=<-loopback>','--webrtc-ip-handling-policy=disable_non_proxied_udp');
    }else flags.push('--no-proxy-server');
    const expected=storedPreferences(spec);
    fs.mkdirSync(path.join(profile,'Default'));
    fs.writeFileSync(path.join(profile,'Default/Preferences'),JSON.stringify({webrtc:{ip_handling_policy:expected[PREF_KEYS[0]],ip_handling_url:expected[PREF_KEYS[1]],local_ips_allowed_urls:expected[PREF_KEYS[2]]}}),{mode:0o600,flag:'wx'});
    if(spec.extension){
      const extension=path.join(profile,'own-extension');fs.mkdirSync(extension,{mode:0o700});
      const {publicKey}=crypto.generateKeyPairSync('rsa',{modulusLength:2048});const key=publicKey.export({type:'spki',format:'der'});
      const extensionID=sha(key).slice(0,32).split('').map(value=>String.fromCharCode(97+parseInt(value,16))).join('');extensionOrigin='chrome-extension://'+extensionID;
      fs.writeFileSync(path.join(extension,'manifest.json'),JSON.stringify({manifest_version:3,name:'Own local WebRTC control',version:'1.0',key:key.toString('base64'),permissions:['privacy']}),{mode:0o600,flag:'wx'});
      fs.writeFileSync(path.join(extension,'probe.html'),'<!doctype html><body data-own-extension="'+nonce+'"><script src="probe.js"></script></body>',{mode:0o600,flag:'wx'});
      const script=fs.readFileSync(new URL('./webrtc-extension-receipt.js',import.meta.url),'utf8').replace('OWN_POLICY_MODE',JSON.stringify(spec.policy));
      fs.writeFileSync(path.join(extension,'probe.js'),script,{mode:0o600,flag:'wx'});
      flags.push('--disable-extensions-except='+extension,'--load-extension='+extension);
      if(spec.policy)fs.writeFileSync(path.join(profile,'Local State'),JSON.stringify({local_test_policies_for_next_startup:JSON.stringify([{level:1,scope:0,source:1,namespace:'chrome',name:'WebRtcIPHandling',value:'default'}])}),{mode:0o600,flag:'wx'});
    }
    stderr=fs.openSync(path.join(output,spec.id+'-runtime.log'),'wx',0o600);
    child=spawn(executable,['--user-data-dir='+profile,...flags,'about:blank'],{env:environment,detached:true,stdio:['ignore','ignore',stderr,'pipe','pipe']});
    let spawnError=null;child.once('error',error=>{spawnError=error;});
    pipe=new WebRTCBoundaryPipe(child.stdio[3],child.stdio[4],origin,extensionOrigin);
    const version=await pipe.command('Browser.getVersion');assert.equal(version.product.split('/').at(-1),binding.runtimeVersion);assert.equal(spawnError,null);row.actualBrowser=true;
    await pipe.command('Target.setDiscoverTargets',{discover:true});
    async function pageAt(url){
      const target=await pipe.command('Target.createTarget',{url:'about:blank'});
      const attached=await pipe.command('Target.attachToTarget',{targetId:target.targetId,flatten:true});const session=attached.sessionId;
      await pipe.command('Runtime.enable',{},session);await pipe.command('Page.enable',{},session);
      const navigation=await pipe.command('Page.navigate',{url},session);assert(!navigation.errorText);
      assert(await until(()=>pipe.ready(session),5000),'Owned target default realm unavailable');
      return {target:target.targetId,session};
    }
    if(spec.extension){
      const extension=await pageAt(extensionOrigin+'/probe.html');let receipt;
      assert(await until(async()=>{receipt=await pipe.evaluate(EXTENSION_READ,extension.session);return receipt!==null;},7000),'Own extension setter/getter missing');
      row.extension={...receipt,nonceMatched:receipt.nonce===nonce,runtimeIDMatched:receipt.runtimeID===extensionOrigin.slice('chrome-extension://'.length)};
      delete row.extension.nonce;delete row.extension.runtimeID;
      await pipe.command('Target.closeTarget',{targetId:extension.target});
    }
    for(const key of PREF_KEYS){
      const pref=await pageAt('chrome://prefs-internals/'+key);row.preferences[key]=await pipe.evaluate(PREFERENCE_READ,pref.session);
      await pipe.command('Target.closeTarget',{targetId:pref.target});
    }
    const page=await pageAt(origin+'/');let ready;
    assert(await until(async()=>{ready=await pipe.evaluate(DOCUMENT_READY,page.session);return ready.ready!=='loading'&&ready.nonce===nonce;},3000),'Owned document not ready');
    row.document={loaded:ready.href===origin+'/'&&ready.origin===origin&&ready.ready!=='loading',nonceMatched:ready.nonce===nonce,defaultRealm:true};
    assert(row.document.loaded&&row.document.nonceMatched);
    const probe=await pipe.evaluate(WEBRTC_PROBE,page.session);row.probe={...probe,nonceMatched:probe.nonce===nonce};delete row.probe.nonce;
    await delay(150);row.status='observations-collected';
  }catch(error){failure=error;row.status='failed';row.failure={kind:error.name};}
  finally{
    let remaining=null;
    try{
      if(child){
        if(pipe&&child.exitCode===null&&child.signalCode===null)await pipe.command('Browser.close').catch(()=>{});
        graceful=await until(()=>child.exitCode!==null||child.signalCode!==null,7000);
        if(!graceful){forced=true;child.kill('SIGTERM');await until(()=>child.exitCode!==null||child.signalCode!==null,3000);}
        await until(()=>owned().length===0,4000);
        if(owned().length){
          const group=inventory().filter(item=>item.group===child.pid);
          assert(group.length>0&&group.every(item=>item.uid===process.getuid()&&item.executable.startsWith(runtime+'/Contents/')),'No authority over unexpected process group');
          forced=true;try{process.kill(-child.pid,'SIGTERM');}catch(error){if(error.code!=='ESRCH')throw error;}
          assert(await until(()=>owned().length===0,5000));
        }
      }
    }catch(error){failure??=error;row.status='failed';row.cleanupFailure={kind:error.name};}
    finally{
      pipe?.close();if(stderr!==undefined)fs.closeSync(stderr);
      for(const socket of sockets)socket.destroy();
      const serverResults=await Promise.allSettled([proxyServer,originServer].filter(Boolean).map(server=>new Promise(resolve=>{
        server.closeAllConnections();server.close(resolve);
      })));
      try{
      assert(serverResults.every(result=>result.status==='fulfilled'));
      const final=stun?await stun.close():null;
      remaining=owned().length;
      row.udp={...final,closedAfterBrowserExit:!!child&&graceful&&remaining===0,finalCounters:stun?.closed===true};
      let removed=false;
      if(profile&&remaining===0){const current=fs.lstatSync(profile);assert(current.dev===profileStat.dev&&current.ino===profileStat.ino&&current.uid===process.getuid()&&current.isDirectory()&&!current.isSymbolicLink());fs.rmSync(profile,{recursive:true});removed=true;}
      row.cleanup={graceful,exitCode:child?.exitCode??null,signal:child?.signalCode??null,forcedTermination:forced,ownedProcessesRemaining:remaining,ownedProfileRemoved:removed};
      inputsUnchanged();
      if(!failure){row.verification=verifyWebRTCCase(row,binding);row.status='scoped-case-pass';}
      }catch(error){failure??=error;row.status='failed';row.cleanupFailure={kind:error.name};}
    }
    row.finishedAt=new Date().toISOString();write(spec.id+'.json',row);
    console.log(JSON.stringify({id:spec.id,status:row.status,stun:row.udp?.browserRequests??null,graceful:row.cleanup?.graceful??false,actualBrowser:row.actualBrowser}));
  }
  if(failure)throw failure;
  return row;
}

const selected=options['--case']?WEBRTC_CASES.filter(spec=>spec.id===options['--case']):WEBRTC_CASES;assert(selected.length>0);
let failure;
try{
  for(const spec of selected){
    const file=path.join(output,spec.id+'.json');
    if(options['--resume']&&fs.existsSync(file)){
      const row=JSON.parse(fs.readFileSync(file));assert.deepEqual(row.sourceSHA256,sourceSHA256);verifyWebRTCCase(row,binding);continue;
    }
    assert(!fs.existsSync(file),'Existing case cannot be replaced');await run(spec);
  }
}catch(error){failure=error;}
finally{
  inputsUnchanged();verifyMachOClosure(runtime,binding.machO);
  const rows=WEBRTC_CASES.flatMap(spec=>{const file=path.join(output,spec.id+'.json');return fs.existsSync(file)?[JSON.parse(fs.readFileSync(file))]:[];});
  let aggregate=null;
  if(!failure&&rows.length===WEBRTC_CASES.length)aggregate=verifyWebRTCSuite(rows,binding);
  const suffix=crypto.randomBytes(6).toString('hex');write('progress-'+suffix+'.json',{status:failure?'failed':aggregate?.status??'partial-matrix',cases:rows.map(row=>({id:row.id,status:row.status})),aggregate,releaseQualified:false});
}
if(failure){console.error(JSON.stringify({status:'failed',kind:failure.name,browserRestarted:false}));process.exitCode=1;}

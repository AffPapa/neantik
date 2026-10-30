// Own headed Chromium DNS/failure observations. No user profiles or JS eval.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import {EventEmitter} from 'node:events';
import fs from 'node:fs';
import path from 'node:path';
import {spawn, spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';
import {browserFixtureEnvironment} from '../runtime-platform/fixtures/qa-browser-environment.mjs';

const methods = new Set(['Target.createTarget', 'Target.attachToTarget', 'Page.enable', 'Page.navigate',
  'Page.getFrameTree', 'Browser.getVersion', 'Browser.close', 'Fetch.enable', 'Fetch.continueRequest', 'Fetch.continueWithAuth']);
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
const digest = file => sha(fs.readFileSync(file));
const here = path.dirname(fileURLToPath(import.meta.url));

export class OwnedPipeCDP extends EventEmitter {
  constructor(input, output, timeout = 15000) {
    super(); this.input=input; this.output=output; this.timeout=timeout;
    this.sequence=0; this.buffer=Buffer.alloc(0); this.pending=new Map(); this.closed=false;
    output.on('data', data => this.receive(data));
    output.on('end', () => this.close());
    output.on('error', () => this.close());
    input.on('error', () => this.close());
  }
  receive(data) {
    if (this.closed) return;
    this.buffer=Buffer.concat([this.buffer,data]);
    if (this.buffer.length>262144) { this.close(); return; }
    for (;;) {
      const end=this.buffer.indexOf(0); if (end<0) break;
      const text=this.buffer.subarray(0,end); this.buffer=this.buffer.subarray(end+1);
      if (!text.length) continue;
      let item; try { item=JSON.parse(text); } catch { this.close(); return; }
      if (!item || typeof item!=='object' || Array.isArray(item)) { this.close(); return; }
      if (Object.hasOwn(item,'id')) {
        const pending=this.pending.get(item.id); if (!pending) { this.close(); return; }
        this.pending.delete(item.id); clearTimeout(pending.timer);
        item.error ? pending.reject(Error('CDP-command-refused')) : pending.resolve(item.result);
      } else if (typeof item.method==='string') this.emit('event',item);
      else { this.close(); return; }
    }
  }
  command(method, params={}, sessionId=null) {
    assert(methods.has(method), 'CDP method outside owned navigation/auth scope');
    if (this.closed) return Promise.reject(Error('CDP-pipe-closed'));
    return new Promise((resolve,reject) => {
      const id=++this.sequence;
      const timer=setTimeout(() => { this.pending.delete(id); reject(Error('CDP-command-timeout')); this.close(); },this.timeout);
      this.pending.set(id,{resolve,reject,timer});
      this.input.write(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})})+'\0');
    });
  }
  close() {
    this.closed=true;
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(Error('CDP-pipe-closed')); }
    this.pending.clear(); this.buffer=Buffer.alloc(0);
  }
}

function privateJSON(file,value) { fs.writeFileSync(file,JSON.stringify(value,null,2)+'\n',{mode:0o600,flag:'wx'}); }
function ownDirectory(dir) {
  assert(path.isAbsolute(dir)); const info=fs.lstatSync(dir);
  assert(info.isDirectory()&&!info.isSymbolicLink()&&info.uid===process.getuid()&&(info.mode&0o077)===0);
}
function privateRead(file) {
  const fd=fs.openSync(file,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);
  try { const info=fs.fstatSync(fd); assert(info.isFile()&&info.uid===process.getuid()&&(info.mode&0o077)===0&&info.size<=65536); return JSON.parse(fs.readFileSync(fd,'utf8')); }
  finally { fs.closeSync(fd); }
}
function plist(file,key) {
  const value=spawnSync('/usr/bin/plutil',['-extract',key,'raw','-o','-',file],{encoding:'utf8'});
  assert.equal(value.status,0); return value.stdout.trim();
}
function ledger(root) { return JSON.parse(fs.readFileSync(path.join(root,'observations.json'),'utf8')); }
async function until(predicate,ms=5000) {
  const end=Date.now()+ms; while(Date.now()<end) { if (await predicate()) return true; await delay(50); } return false;
}
function counts(root,phase) {
  const events=ledger(root).filter(e=>e.phase===phase), dns=events.filter(e=>e.kind==='dns-wire');
  return {udpAnswers:dns.filter(e=>e.transport==='udp'&&e.rcode===0&&e.queryType===1).length,
    udpFailures:dns.filter(e=>e.transport==='udp'&&e.rcode===2).length,
    dohAnswers:dns.filter(e=>e.transport==='https'&&e.rcode===0&&e.queryType===1).length,
    dohFailures:dns.filter(e=>e.transport==='https'&&e.rcode===2).length,
    protectedOrigins:events.filter(e=>e.kind==='origin'&&e.throughOwnedUpstream===true).length,
    directOrigins:events.filter(e=>e.kind==='origin'&&e.throughOwnedUpstream===false).length};
}
function observation(root,phase,navigation) { return {phase,...counts(root,phase),...navigation}; }

async function main() {
  const args=process.argv.slice(2);
  assert.equal(args.length,4,'Usage: node run-controlled-dns.mjs APP RELEASE_REPORT FIXTURE_ROOT OUTPUT_ROOT');
  const [app,releaseFile,fixtureRoot,out]=args;
  assert([app,releaseFile,fixtureRoot,out].every(path.isAbsolute)); ownDirectory(fixtureRoot); ownDirectory(out);
  assert.equal(fs.readdirSync(out).length,0,'Output must be a fresh own private directory');
  const fixture=privateRead(path.join(fixtureRoot,'fixture-private.json'));
  assert.equal(fixture.schemaVersion,1);
  const doh=new URL(fixture.dohURL);
  assert.equal(doh.hostname,'127.0.0.1'); assert.equal(doh.protocol,'https:'); assert.equal(doh.pathname,'/dns-query');
  assert(/^[A-Za-z0-9+/]{43}=$/.test(fixture.testCertificateSPKI));
  for (const value of Object.values(fixture.urls)) {
    const u=new URL(value); assert.equal(u.protocol,'http:'); assert(/^[a-f0-9]{32}\.neantik-dns\.test$/.test(u.hostname));
    assert.equal(Number(u.port),fixture.originPort); assert.equal(u.pathname,'/owned-route');
  }
  const release=JSON.parse(fs.readFileSync(releaseFile,'utf8'));
  const runtime=path.join(app,'Contents/Resources/NeAntik Browser.app'), runtimePlist=path.join(runtime,'Contents/Info.plist');
  const binary=path.join(runtime,'Contents/MacOS',plist(runtimePlist,'CFBundleExecutable'));
  const version=plist(runtimePlist,'CFBundleShortVersionString');
  assert.equal(version,release.runtime.chromiumVersion);
  const framework=path.join(runtime,'Contents/Frameworks/NeAntik Browser Framework.framework/Versions',version,'NeAntik Browser Framework');
  assert.equal(digest(binary),release.runtime.executableSHA256); assert.equal(digest(framework),release.runtime.frameworkSHA256);
  assert.equal(digest(path.join(app,'Contents/MacOS/NeAntik')),release.managerSHA256);
  const signature=spawnSync('/usr/bin/codesign',['--verify','--strict',runtime],{stdio:'ignore'}); assert.equal(signature.status,0);
  const report={schemaVersion:1,status:'incomplete',scope:'headed raw signed Chromium; not manager/relay, global DNS or UDP qualification',
    headed:true,releaseVersion:release.version,releaseBuild:release.build,runtimeVersion:version,
    runtimeSHA256:digest(binary),frameworkSHA256:digest(framework),managerSHA256:release.managerSHA256,
    releaseReportSHA256:digest(releaseFile),fixtureConfigurationSHA256:sha(JSON.stringify(fixture)),
    environment:{platform:process.platform,architecture:process.arch,os:spawnSync('/usr/bin/sw_vers',['-productVersion'],{encoding:'utf8'}).stdout.trim()},
    tlsBoundary:'own self-signed DoH certificate; scoped SPKI test override, not OS-default TLS trust',
    sessions:[],admissionAttempts:[],sourceFiles:{},startedAt:new Date().toISOString()};
  for(const file of [fileURLToPath(import.meta.url),path.join(here,'controlled-dns-fixture.py'),path.join(here,'manager-route-fixture.py'),
      path.join(here,'../runtime-platform/fixtures/qa-browser-environment.mjs')]) {
    const data=fs.readFileSync(file); report.sourceFiles[path.basename(file)]=sha(data);
    fs.writeFileSync(path.join(out,path.basename(file)),data,{mode:0o600,flag:'wx'});
  }
  let failure=null;
  async function session(mode,action) {
    const gate=spawnSync('python3',['-B',path.join(here,'../native-qa-readiness.py'),'--check'],{encoding:'utf8'});
    const readiness=JSON.parse(gate.stdout);
    report.admissionAttempts.push({mode,exitCode:gate.status,readiness});
    if (gate.status!==0 || !readiness.eligibleForAttempt) { report.status='resource-blocked'; throw Error('native-resource-admission'); }
    const profile=fs.mkdtempSync(path.join(out,mode+'-')); fs.chmodSync(profile,0o700);
    const localState={dns_over_https:{mode:'secure',templates:fixture.dohURL,automatic_mode_fallback_to_doh:false}};
    privateJSON(path.join(profile,'Local State'),localState);
    const flags=['--user-data-dir='+profile,'--use-mock-keychain','--no-first-run','--no-default-browser-check',
      '--new-window','--remote-debugging-pipe','--disable-background-networking','--disable-component-update',
      '--disable-sync','--disable-extensions','--disable-quic','--webrtc-ip-handling-policy=disable_non_proxied_udp',
      '--ignore-certificate-errors-spki-list='+fixture.testCertificateSPKI];
    if(mode==='direct') flags.push('--no-proxy-server');
    else flags.push('--proxy-server=http://127.0.0.1:'+fixture.proxyPort,
      '--proxy-bypass-list=<-loopback>'+(mode==='bypass'?';*.neantik-dns.test':''));
    flags.push('about:blank');
    const entry={mode,sessionID:crypto.randomUUID(),profileRootSHA256:sha(profile),configurationSHA256:sha(JSON.stringify({flags,localState})),
      readiness,observations:[],status:'incomplete',cleanup:null,stage:'launch',
      auth:{challenges:0,provided:0,cancelled:0,handlerErrors:0}}; report.sessions.push(entry);
    const stderr=fs.openSync(path.join(profile,'runtime-stderr.log'),'wx',0o600);
    let child,cdp,errored=false;
    const exited=()=>!child||errored||child.exitCode!==null||child.signalCode!==null;
    try {
      child=spawn(binary,flags,{env:browserFixtureEnvironment(),stdio:['ignore','ignore',stderr,'pipe','pipe'],detached:true});
      child.once('error',()=>{errored=true;});
      cdp=new OwnedPipeCDP(child.stdio[3],child.stdio[4]);
      entry.stage='cdp-version';
      const actual=await cdp.command('Browser.getVersion');
      assert.equal(actual.product.split('/').at(-1),version,'Unexpected running runtime');
      const target=await cdp.command('Target.createTarget',{url:'about:blank'});
      const attached=await cdp.command('Target.attachToTarget',{targetId:target.targetId,flatten:true});
      const sid=attached.sessionId; let authFailures=0;
      cdp.on('event',event=>{
        if(event.sessionId!==sid) return;
        let command;
        if(event.method==='Fetch.requestPaused') command=cdp.command('Fetch.continueRequest',{requestId:event.params.requestId},sid);
        if(event.method==='Fetch.authRequired') {
          const challenge=event.params.authChallenge;
          const own=mode!=='direct'&&challenge.source==='Proxy'&&challenge.origin==='http://127.0.0.1:'+fixture.proxyPort;
          entry.auth.challenges++; entry.auth[own?'provided':'cancelled']++;
          command=cdp.command('Fetch.continueWithAuth',{requestId:event.params.requestId,authChallengeResponse:own?
            {response:'ProvideCredentials',username:'owned-fixture-user',password:'not-a-real-proxy-password'}:{response:'CancelAuth'}},sid);
        }
        if(command) command.catch(()=>{authFailures++; entry.auth.handlerErrors++;});
      });
      await cdp.command('Page.enable',{},sid);
      if(mode!=='direct') await cdp.command('Fetch.enable',{handleAuthRequests:true,patterns:[{urlPattern:'*'}]},sid);
      async function navigate(phase) {
        entry.stage=phase;
        const url=fixture.urls[phase]; assert(url);
        const result=await cdp.command('Page.navigate',{url},sid);
        let committed=false;
        if(!result.errorText) committed=await until(async()=>{
          const tree=await cdp.command('Page.getFrameTree',{},sid); return tree.frameTree.frame.url===url;
        });
        await delay(200);
        const navigationError=result.errorText&&/^net::ERR_[A-Z_]+$/.test(result.errorText)?result.errorText:result.errorText?'navigation-error':null;
        return observation(fixtureRoot,phase,{committed,navigationError});
      }
      await action(navigate,entry);
      assert.equal(authFailures,0,'Auth pipe handler failed'); entry.status='observed'; entry.stage='complete';
    } finally {
      fs.closeSync(stderr);
      if(cdp&&!exited()) { await cdp.command('Browser.close').catch(()=>{}); }
      let graceful=await until(exited,7000);
      if(!graceful&&child&&!errored) child.kill('SIGTERM');
      await until(exited,3000); cdp?.close();
      function ownedProcesses() {
        const inventory=spawnSync('/bin/ps',['-axo','pgid=,command='],{encoding:'utf8'}); assert.equal(inventory.status,0);
        return inventory.stdout.split('\n').filter(line=>{
          const row=line.trim().match(/^(\d+)\s+(.*)$/); return row&&(Number(row[1])===child?.pid||row[2].includes('--user-data-dir='+profile));
        }).length;
      }
      let remaining=ownedProcesses();
      if(remaining&&!errored&&child) {
        // Child created its own process group. Confirm a remaining owned root
        // before terminating orphaned helpers; never use bundle ID targeting.
        const inventory=spawnSync('/bin/ps',['-axo','pgid=,command='],{encoding:'utf8'});
        const owned=inventory.stdout.split('\n').some(line=>line.trim().startsWith(child.pid+' ')&&line.includes(profile));
        if(owned) { try { process.kill(-child.pid,'SIGTERM'); } catch(error) { if(error.code!=='ESRCH') throw error; } }
        await until(()=>ownedProcesses()===0,5000); remaining=ownedProcesses();
      }
      entry.cleanup={browserExited:exited(),gracefulBrowserClose:graceful,ownedProcessesRemaining:remaining};
      assert.equal(remaining,0,'Owned Chromium process did not settle'); assert(exited());
      // This does not qualify preservation of browser data after close.
    }
  }
  try {
    await session('proxy',async(navigate,entry)=>{
      entry.observations.push(await navigate('proxy-success'));
      assert(await until(()=>ledger(fixtureRoot).some(e=>e.kind==='stream-first-heartbeat'&&e.throughOwnedUpstream===true)),'Protected stream missing');
      fs.writeFileSync(path.join(fixtureRoot,'cut-upstream'),'',{flag:'wx',mode:0o600});
      assert(await until(()=>ledger(fixtureRoot).some(e=>e.kind==='cut-active-local-channels'&&e.channels>=2)),'Established connection not cut');
      entry.establishedStreamCut=true;
      entry.observations.push(await navigate('upstream-cut'));
      fs.unlinkSync(path.join(fixtureRoot,'cut-upstream')); await delay(150);
      fs.writeFileSync(path.join(fixtureRoot,'fail-dns'),'',{flag:'wx',mode:0o600});
      entry.observations.push(await navigate('dns-refused')); fs.unlinkSync(path.join(fixtureRoot,'fail-dns'));
      fs.writeFileSync(path.join(fixtureRoot,'drop-upstream'),'',{flag:'wx',mode:0o600});
      entry.observations.push(await navigate('upstream-refused')); fs.unlinkSync(path.join(fixtureRoot,'drop-upstream'));
      entry.observations.push(await navigate('proxy-recovered'));
    });
    await session('direct',async(navigate,entry)=>{
      fs.writeFileSync(path.join(fixtureRoot,'fail-doh'),'',{flag:'wx',mode:0o600});
      entry.observations.push(await navigate('doh-refused')); fs.unlinkSync(path.join(fixtureRoot,'fail-doh'));
      entry.observations.push(await navigate('direct-control'));
    });
    await session('bypass',async(navigate,entry)=>{entry.observations.push(await navigate('bypass-control'));});
    report.status='observed';
  } catch(error) { failure=error; if(report.status!=='resource-blocked') report.status='failed'; report.error='owned-DNS-stage-incomplete'; }
  finally {
    for(const flag of ['fail-dns','fail-doh','cut-upstream','drop-upstream']) {
      const file=path.join(fixtureRoot,flag); if(fs.existsSync(file)) fs.unlinkSync(file);
    }
    report.completedAt=new Date().toISOString(); privateJSON(path.join(out,'observations.json'),report);
    console.log(JSON.stringify({status:report.status,sessions:report.sessions.length,actualBrowser:report.sessions.length>0}));
  }
  if(failure) throw Error(failure.message.startsWith('native-resource')?'native-resource-admission':'owned-DNS-stage-incomplete');
}

if(process.argv[2]==='--protocol-controls') {
  const {PassThrough}=await import('node:stream');
  let controls=0;
  const input=new PassThrough(), output=new PassThrough(), pipe=new OwnedPipeCDP(input,output,500);
  input.once('data',data=>{const request=JSON.parse(data.subarray(0,-1)); output.write(JSON.stringify({id:request.id,result:{own:true}})+'\0');});
  assert.deepEqual(await pipe.command('Browser.getVersion'),{own:true}); controls++;
  assert.throws(()=>pipe.command('Runtime.evaluate')); controls++;
  let events=0; pipe.on('event',()=>events++); output.write('{"method":"Page.loadEventFired","params":{}}\0'); assert.equal(events,1); controls++;
  output.write('{"id":999,"result":{}}\0'); assert(pipe.closed); controls++;
  const other=new OwnedPipeCDP(new PassThrough(),new PassThrough()); other.receive(Buffer.alloc(262145)); assert(other.closed); controls++;
  const timeout=new OwnedPipeCDP(new PassThrough(),new PassThrough(),10); await assert.rejects(timeout.command('Browser.getVersion')); assert(timeout.closed); controls++;
  console.log(JSON.stringify({protocolControls:controls,actualBrowser:false}));
} else if(process.argv[1]&&fileURLToPath(import.meta.url)===path.resolve(process.argv[1])) {
  main().catch(()=>{console.error('Controlled DNS runner failed; retained own report, no raw error or URL emitted'); process.exitCode=1;});
}

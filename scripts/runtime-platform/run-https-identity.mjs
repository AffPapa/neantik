// Finite headed HTTPS identity qualification. Browser data, keys and raw values
// belong to a new private fixture. No manager/relay or system DNS claim implied.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawn,spawnSync} from 'node:child_process';
import {setTimeout as delay} from 'node:timers/promises';
import {fileURLToPath} from 'node:url';
import {OwnedPipeCDP} from '../runtime-network/run-controlled-dns.mjs';
import {browserFixtureEnvironment} from './fixtures/qa-browser-environment.mjs';
import {createIdentityFixture} from './fixtures/https-identity-fixture.mjs';

const here=path.dirname(fileURLToPath(import.meta.url));
const sha=x=>crypto.createHash('sha256').update(x).digest('hex');
const digest=file=>sha(fs.readFileSync(file));
const privateJSON=(file,value)=>fs.writeFileSync(file,JSON.stringify(value,null,2)+'\n',{mode:0o600,flag:'wx'});
function plist(app,key){const r=spawnSync('/usr/bin/plutil',['-extract',key,'raw','-o','-',path.join(app,'Contents/Info.plist')],{encoding:'utf8'});assert.equal(r.status,0);return r.stdout.trim();}
function runtime(app,expected,reference=false){
  const binary=path.join(app,'Contents/MacOS',plist(app,'CFBundleExecutable'));
  const version=plist(app,'CFBundleShortVersionString');
  const framework=reference?path.join(app,'Contents/Frameworks/Google Chrome Framework.framework/Versions',version,'Google Chrome Framework'):
    path.join(app,'Contents/Frameworks/NeAntik Browser Framework.framework/Versions',version,'NeAntik Browser Framework');
  assert.equal(version,expected.version);assert.equal(digest(binary),expected.executableSHA256);assert.equal(digest(framework),expected.frameworkSHA256);
  assert.equal(spawnSync('/usr/bin/codesign',['--verify','--deep','--strict',app],{stdio:'ignore'}).status,0,'Runtime signature failed');
  return {app,binary,framework,version,executableSHA256:expected.executableSHA256,frameworkSHA256:expected.frameworkSHA256};
}
async function until(predicate,ms){const end=Date.now()+ms;while(Date.now()<end){if(await predicate())return true;await delay(100);}return false;}
function privateDirectory(dir){assert(path.isAbsolute(dir));const s=fs.lstatSync(dir);assert(s.isDirectory()&&!s.isSymbolicLink()&&s.uid===process.getuid()&&(s.mode&0o077)===0);}

export function browserSocketCustody(clientPort,proxyPort,owned) {
  if(!owned)return null;
  const r=spawnSync('/usr/sbin/lsof',['-nP','-iTCP@127.0.0.1:'+proxyPort,'-Fpn'],{encoding:'utf8',timeout:3000});
  if(r.status!==0)return null;
  let pid=null,peers=[];
  for(const line of r.stdout.split('\n')){
    if(line.startsWith('p'))pid=Number(line.slice(1));
    if(line==='n127.0.0.1:'+clientPort+'->127.0.0.1:'+proxyPort&&Number.isSafeInteger(pid))peers.push(pid);
  }
  peers=[...new Set(peers)];if(peers.length!==1)return null;
  const q=spawnSync('/bin/ps',['-p',String(peers[0]),'-o','pgid=,uid=,lstart=,comm='],{encoding:'utf8',timeout:3000});
  const match=q.stdout.trim().match(/^(\d+)\s+(\d+)\s+(.{24})\s+(.+)$/);
  if(q.status!==0||!match||Number(match[1])!==owned.pid||Number(match[2])!==process.getuid()||!match[4].startsWith(owned.runtimeApp+'/Contents/'))return null;
  return {sameProcessGroup:true,runtimePathBound:true,generationSHA256:sha(JSON.stringify({pid:peers[0],pgid:match[1],started:match[3],path:match[4]}))};
}

async function main(){
  const [app,releaseFile,chromeApp,referenceFile,out]=process.argv.slice(2);
  assert.equal(process.argv.length,7,'Usage: node run-https-identity.mjs APP RELEASE CHROME_APP REFERENCE_BINDING OUTPUT');
  assert([app,releaseFile,chromeApp,referenceFile,out].every(x=>path.isAbsolute(x)));
  privateDirectory(out);assert.equal(fs.readdirSync(out).length,0,'Fresh own output required');
  const release=JSON.parse(fs.readFileSync(releaseFile)),reference=JSON.parse(fs.readFileSync(referenceFile));
  assert.equal(digest(path.join(app,'Contents/MacOS/NeAntik')),release.managerSHA256);
  const own=runtime(path.join(app,'Contents/Resources/NeAntik Browser.app'),{version:release.runtime.chromiumVersion,executableSHA256:release.runtime.executableSHA256,frameworkSHA256:release.runtime.frameworkSHA256});
  const chrome=runtime(chromeApp,reference,true);
  const sourcePaths=[fileURLToPath(import.meta.url),path.join(here,'fixtures/https-identity-fixture.mjs'),path.join(here,'fixtures/https-identity-probe.mjs'),path.join(here,'fixtures/qa-browser-environment.mjs'),path.join(here,'../runtime-network/run-controlled-dns.mjs')];
  const report={schemaVersion:1,status:'incomplete',scope:'headed raw signed runtime HTTPS identity, own CONNECT; not manager relay/global DNS or OS-default upstream trust',
    releaseVersion:release.version,releaseBuild:release.build,releaseReportSHA256:digest(releaseFile),managerSHA256:release.managerSHA256,
    runtime:{version:own.version,executableSHA256:own.executableSHA256,frameworkSHA256:own.frameworkSHA256},
    reference:{...reference,bindingSHA256:digest(referenceFile)},environment:{os:spawnSync('/usr/bin/sw_vers',['-productVersion'],{encoding:'utf8'}).stdout.trim(),architecture:process.arch,headed:true},
    startedAt:new Date().toISOString(),sources:Object.fromEntries(sourcePaths.map(f=>[path.relative(path.dirname(here),f),digest(f)])),sessions:[],admissionAttempts:[],cleanup:null};
  fs.mkdirSync(path.join(out,'sources'),{mode:0o700});for(let i=0;i<sourcePaths.length;i++)fs.copyFileSync(sourcePaths[i],path.join(out,'sources',i+'-'+path.basename(sourcePaths[i])));
  let currentOwner=null,fixture=null,failure=null;
  try {
    fixture=await createIdentityFixture(out,{browserCustody:(client,proxy)=>browserSocketCustody(client,proxy,currentOwner)});
    report.certificate={spkiSHA256:sha(fixture.certificate.spki),certificateSHA256:sha(fixture.certificate.cert),scope:'One-day own certificate; only own SPKI override; system trust unchanged'};
    for(const mode of ['chrome-reference','unconfigured','configured','direct-negative']){
      const readiness=spawnSync('python3',['-B',path.join(here,'../native-qa-readiness.py'),'--check'],{encoding:'utf8'});
      let gate;try{gate=JSON.parse(readiness.stdout);}catch{throw Error('readiness-unavailable');}
      report.admissionAttempts.push({mode,exitCode:readiness.status,readiness:gate});
      if(readiness.status!==0||gate.eligibleForAttempt!==true){report.status='resource-blocked';throw Error('resource-admission');}
      const selected=mode==='chrome-reference'?chrome:own,id=crypto.randomUUID(),state=fixture.begin(id);
      const profile=fs.mkdtempSync(path.join(out,mode+'-'));fs.chmodSync(profile,0o700);
      const flags=['--user-data-dir='+profile,'--use-mock-keychain','--no-first-run','--no-default-browser-check','--new-window','--remote-debugging-pipe',
        '--disable-background-networking','--disable-component-update','--disable-sync','--disable-extensions','--disable-quic',
        '--webrtc-ip-handling-policy=disable_non_proxied_udp','--ignore-certificate-errors-spki-list='+fixture.certificate.spki];
      if(mode==='direct-negative')flags.push('--no-proxy-server');else flags.push('--proxy-server=http://127.0.0.1:'+fixture.proxyPort,'--proxy-bypass-list=<-loopback>');
      flags.push('about:blank');const env=browserFixtureEnvironment();if(['configured','direct-negative'].includes(mode))env.NEANTIK_PROFILE_SEED='21';
      const entry={mode,id,status:'incomplete',profileRootSHA256:sha(profile),configurationSHA256:sha(JSON.stringify({flags,seed:env.NEANTIK_PROFILE_SEED??null})),
        launchArguments:flags,profileSeed:env.NEANTIK_PROFILE_SEED??null,
        runtimeVersion:selected.version,runtimeSHA256:selected.executableSHA256,frameworkSHA256:selected.frameworkSHA256,headed:true,cleanup:null};report.sessions.push(entry);
      const stderr=fs.openSync(path.join(profile,'runtime-stderr.log'),'wx',0o600);let child,cdp,spawnFailed=false;
      try{
        child=spawn(selected.binary,flags,{env,stdio:['ignore','ignore',stderr,'pipe','pipe'],detached:true});child.once('error',()=>{spawnFailed=true;});
        currentOwner={pid:child.pid,runtimeApp:selected.app};cdp=new OwnedPipeCDP(child.stdio[3],child.stdio[4]);
        const version=await cdp.command('Browser.getVersion');assert.equal(version.product.split('/').at(-1),selected.version);
        const target=await cdp.command('Target.createTarget',{url:'about:blank'}),attached=await cdp.command('Target.attachToTarget',{targetId:target.targetId,flatten:true});
        await cdp.command('Page.enable',{},attached.sessionId);
        const url=fixture.config.a+'/?token='+state.token,navigation=await cdp.command('Page.navigate',{url},attached.sessionId);assert(!navigation.errorText,'Own TLS navigation failed');
        assert(await until(()=>state.result!==null,25000),'Own probe result missing');
        assert(!state.result.error,'Own browser probe incomplete');
        const tree=await cdp.command('Page.getFrameTree',{},attached.sessionId);assert.equal(tree.frameTree.frame.url,url);
        entry.documentConfirmed=true;entry.status='observed';
      }finally{
        if(cdp&&child?.exitCode===null)await cdp.command('Browser.close').catch(()=>{});
        const exited=()=>!child||spawnFailed||child.exitCode!==null||child.signalCode!==null;
        const graceful=await until(exited,7000);if(!graceful)child?.kill('SIGTERM');await until(exited,3000);cdp?.close();fs.closeSync(stderr);
        const inventory=()=>{const ps=spawnSync('/bin/ps',['-axo','pgid=,command='],{encoding:'utf8'});assert.equal(ps.status,0);return ps.stdout.split('\n').filter(line=>{const m=line.trim().match(/^(\d+)\s+(.*)$/);return m&&(Number(m[1])===child?.pid||m[2].includes('--user-data-dir='+profile));});};
        let remaining=inventory();if(remaining.length&&remaining.some(x=>x.includes(profile))&&child){try{process.kill(-child.pid,'SIGTERM');}catch(e){if(e.code!=='ESRCH')throw e;}await until(()=>inventory().length===0,5000);remaining=inventory();}
        entry.cleanup={browserExited:exited(),gracefulBrowserClose:graceful,exitCode:child?.exitCode??null,ownedProcessesRemaining:remaining.length};
        Object.assign(entry,fixture.finish());currentOwner=null;assert.equal(remaining.length,0,'Owned browser processes remain');assert(exited()&&graceful&&child.exitCode===0,'Browser did not close gracefully');
      }
    }
    report.status='observed';
  }catch(error){failure=error;if(report.status!=='resource-blocked')report.status='failed';report.failureClass=String(error.message).startsWith('resource')?'resource-admission':'owned-fixture-stage-incomplete';}
  finally{
    try{if(fixture)await fixture.close();report.cleanup={fixtureClosed:true,temporaryTLSKeyRemoved:true};}catch{report.cleanup={fixtureClosed:false};failure??=Error('fixture-cleanup');report.status='failed';}
    try{
      for(const f of sourcePaths)assert.equal(digest(f),report.sources[path.relative(path.dirname(here),f)],'Source changed during run');
      for(const r of [own,chrome]){assert.equal(digest(r.binary),r.executableSHA256);assert.equal(digest(r.framework),r.frameworkSHA256);}
      assert.equal(digest(path.join(app,'Contents/MacOS/NeAntik')),release.managerSHA256);
      report.runtimeHashesRechecked=true;
    }catch{report.runtimeHashesRechecked=false;report.status='failed';failure??=Error('inputs-changed');}
    report.completedAt=new Date().toISOString();privateJSON(path.join(out,'observations.json'),report);
    console.log(JSON.stringify({status:report.status,sessions:report.sessions.length,fixtureClosed:report.cleanup.fixtureClosed}));
  }
  if(failure)process.exitCode=1;
}

if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))main().catch(()=>{console.error('HTTPS identity setup failed; no raw identities or credentials emitted');process.exitCode=1;});

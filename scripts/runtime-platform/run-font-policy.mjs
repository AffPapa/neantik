// Finite research-only headed font witness. No manager activation or release PASS.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {spawn,spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';
import {OwnedPipeCDP} from '../runtime-network/run-controlled-dns.mjs';
import {browserSocketCustody} from './run-https-identity.mjs';
import {browserFixtureEnvironment} from './fixtures/qa-browser-environment.mjs';
import {createFontPolicyFixture} from './fixtures/font-policy-fixture.mjs';
import {checkFontSession,checkFontABA,validateFontMeasurement} from './fixtures/font-policy-semantics.mjs';
import {verifyMachOClosure} from './fixtures/font-runtime-closure.mjs';
import {consumeFontWarningPhase,assessFontAdmission} from './fixtures/font-headed-admission.mjs';
const here=path.dirname(fileURLToPath(import.meta.url));
const sha=value=>crypto.createHash('sha256').update(value).digest('hex');
const digest=file=>sha(fs.readFileSync(file));
const save=(file,value)=>fs.writeFileSync(file,JSON.stringify(value,null,2)+'\n',{mode:0o600,flag:'wx'});
const certificate='474F7C78F33EE324C24F6F5AE0443EB713E85E60';
const closureTool=path.join(here,'../verify-direct-update-runtime-pins.py');
const inputContracts=Object.freeze(['chromium-host-font-policy.json','chromium-font-witness.json','chromium-font-cleanup.json','chromium-font-cleanup-cstring.json']);
export const modes=Object.freeze(['native','seeded-native','policy-a','policy-b','policy-a-repeat']);
export function parseAcknowledgements(text,nonce) {
  assert(/^[a-f0-9]{32}$/.test(nonce));
  const rows=[];
  for(const match of text.matchAll(/NEANTIK_FONT_QA_V1 nonce=([a-f0-9]{32}) pid=([1-9][0-9]*) role=(browser|renderer) complete=1 unique=1 family=1\n/g)) {
    assert.equal(match[1],nonce,'Unrelated or stale QA acknowledgement');
    const pid=Number(match[2]);assert(Number.isSafeInteger(pid)&&pid<=2147483647,'Invalid PID witness');
    rows.push({pid,role:match[3],complete:true,uniqueSelected:true,familySelected:true});
  }
  assert(rows.length>0,'No completed native registration witness');
  assert.equal(rows.length,[...text.matchAll(/NEANTIK_FONT_QA_V1/g)].length,'Malformed or partial native acknowledgement');
  assert.equal(new Set(rows.map(row=>row.pid)).size,rows.length,'Duplicate PID witness');
  return rows;
}
export function validateProbeEnvelope(value,nonce,hashes) {
  assert.equal(value?.schemaVersion,1);assert.equal(value.nonce,nonce);assert.equal(value.error,null);assert.equal(value.workerTerminationRequested,true);
  assert(Array.isArray(value.realms)&&value.realms.length===2);
  assert.deepEqual(value.realms.map(row=>row.realm).sort(),['page','worker']);
  for(const realm of value.realms) {
    assert.equal(realm.kind,'own-font-policy-realm');assert.equal(realm.nonce,nonce);
    for(const api of ['canvas','fontFace','fontSet'])assert.equal(realm.available?.[api],true);
    assert.equal(realm.available.dom,realm.realm==='page');assert.deepEqual(realm.errors,[]);assert.equal(realm.ownFontFacesRemoved,true);assert.equal(realm.fontSetReadyAfterLoads,true);
    assert(Array.isArray(realm.local)&&realm.local.length===2);assert.deepEqual(realm.local.map(row=>row.kind),['known-own-unique','invented-missing']);
    for(const face of realm.local){assert.equal(typeof face.loaded,'boolean');assert.equal(face.timedOut,false);}
    assert(Array.isArray(realm.resources)&&realm.resources.length===2);
    for(const [family,hash] of [['QARemoteCanary',hashes.canarySHA256],['QARemoteAhem',hashes.ahemSHA256]]) {
      const faces=realm.resources.filter(row=>row.family===family);assert.equal(faces.length,1);
      assert.equal(faces[0].loaded,true);assert.equal(faces[0].timedOut,false);assert.equal(faces[0].sha256,hash);assert(Number.isSafeInteger(faces[0].bytes)&&faces[0].bytes>0);
    }
    const expected=new Set();
    for(const family of ['NeAntikFontPolicyCanary','Helvetica',`NeAntikMissing_${nonce}`])for(const fallback of ['monospace','serif'])for(const style of ['normal 400','normal 700','italic 400'])for(const text of ['ABABA','A B A B'])expected.add(JSON.stringify([family,fallback,style,text]));
    for(const family of ['QALocalUnique','QARemoteCanary','QARemoteAhem'])for(const fallback of ['monospace','serif'])expected.add(JSON.stringify([family,fallback,'normal 400','ABABA']));
    assert(Array.isArray(realm.measurements)&&realm.measurements.length===42);
    for(const row of realm.measurements) {
      const key=JSON.stringify([row.family,row.fallback,row.style,row.text]);assert(expected.delete(key),'Unknown/duplicate measurement');
      validateFontMeasurement(row,realm.realm);
    }
    assert.equal(expected.size,0);
  }
  // Envelope completeness is not font semantics or a browser qualification.
  return true;
}
function plist(app,key) {
  const r=spawnSync('/usr/bin/plutil',['-extract',key,'raw','-o','-',path.join(app,'Contents/Info.plist')],{encoding:'utf8'});
  assert.equal(r.status,0);return r.stdout.trim();
}
export function inspectRuntime(app,binding) {
  assert.equal(binding.schemaVersion,1);assert.equal(binding.status,'research-only');
  assert.equal(fs.realpathSync(app),app);
  const researchRoot=path.dirname(app),rootInfo=fs.lstatSync(researchRoot);
  assert.equal(path.dirname(researchRoot),'/private/tmp');assert(/^neantik-font-runtime\.[a-f0-9]{32}$/.test(path.basename(researchRoot)));
  assert(rootInfo.isDirectory()&&!rootInfo.isSymbolicLink()&&rootInfo.uid===process.getuid()&&(rootInfo.mode&0o077)===0,'Own private research runtime required');
  assert.equal(plist(app,'CFBundleShortVersionString'),binding.version);
  assert.equal(binding.sourceInputManifestSHA256,digest(path.join(here,'../../runtime/font-policy-v1/chromium-font-witness.json')));
  assert.deepEqual(Object.keys(binding.sourceInputContracts??{}).sort(),[...inputContracts].sort(),'Complete corrected source lineage required');
  for(const [index,name] of inputContracts.entries()) {
    const file=path.join(here,'../../runtime/font-policy-v1',name),contract=JSON.parse(fs.readFileSync(file));
    assert.equal(digest(file),binding.sourceInputContracts[name]);assert(/^[a-z0-9-]+\.patch$/.test(contract.patchFile));
    assert.equal(digest(path.join(path.dirname(file),contract.patchFile)),contract.patchSHA256);
    if(index>0){assert.equal(contract.parentManifest,inputContracts[index-1]);assert.equal(contract.parentManifestSHA256,binding.sourceInputContracts[inputContracts[index-1]]);}
  }
  const executable=path.join(app,'Contents/MacOS',plist(app,'CFBundleExecutable'));
  const framework=path.join(app,'Contents/Frameworks/NeAntik Browser Framework.framework/Versions',binding.version,'NeAntik Browser Framework');
  assert.equal(digest(executable),binding.executableSHA256);assert.equal(digest(framework),binding.frameworkSHA256);
  assert.equal(spawnSync('/usr/bin/codesign',['--verify','--deep','--strict',app],{stdio:'ignore'}).status,0,'Nested signature invalid');
  const requirement=`anchor apple generic and certificate leaf = H"${certificate}"`;
  assert.equal(spawnSync('/usr/bin/codesign',['--verify','--strict','-R='+requirement,app],{stdio:'ignore'}).status,0,'Existing approved Developer ID identity required');
  const measured=verifyMachOClosure(app,binding.codeClosure);
  assert.equal(digest(closureTool),binding.closureToolSHA256);
  // Reuse the independent full-tree transcript algorithm, without invoking its
  // published-runtime admission or changing its old installed production pins.
  const whole=spawnSync('python3',['-B','-c','import importlib.util,json,sys;from pathlib import Path;s=importlib.util.spec_from_file_location("owned_closure",sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);print(json.dumps(m.measure(Path(sys.argv[2]),"runtime")))',closureTool,app],{encoding:'utf8',timeout:30000});
  assert.equal(whole.status,0,'Independent runtime transcript failed');assert.deepEqual(JSON.parse(whole.stdout),binding.runtimeTranscript);
  for(const required of [executable,framework])assert(measured[path.relative(app,required)],'Main code missing from closure');
  for(const helper of ['Renderer','GPU'])assert(Object.keys(measured).some(file=>file.includes(`Helper (${helper}).app/Contents/MacOS/`)),'Required browser helper absent');
  for(const relative of Object.keys(measured))assert.equal(spawnSync('/usr/bin/codesign',['--verify','--strict','-R='+requirement,path.join(app,relative)],{stdio:'ignore'}).status,0,'Runtime code signed by unexpected identity');
  const manifest=JSON.parse(fs.readFileSync(path.join(here,'../../runtime/font-policy-v1/chromium-font-witness.json')));
  const resources=path.join(path.dirname(framework),'Resources');
  for(const asset of manifest.fixedAssets) {
    const resource=path.join(resources,path.basename(asset.path));assert.equal(fs.statSync(resource).size,asset.bytes);
    assert.equal(digest(resource),asset.sha256,'Bundled font witness differs');
  }
  return {app,executable,framework,closureSHA256:sha(JSON.stringify(Object.entries(measured).sort())),executableSHA256:binding.executableSHA256,frameworkSHA256:binding.frameworkSHA256};
}
function privateLog(file) {
  const fd=fs.openSync(file,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);
  try {const stat=fs.fstatSync(fd);assert(stat.isFile()&&stat.size<=4194304,'Owned stderr exceeds 4 MiB capture limit');return fs.readFileSync(fd);}
  finally {fs.closeSync(fd);}
}
async function until(predicate,timeout) {const end=Date.now()+timeout;while(Date.now()<end){if(await predicate())return true;await delay(50);}return false;}
function inventory(group,app) {
  const ps=spawnSync('/bin/ps',['-axo','pid=,pgid=,uid=,lstart=,comm='],{encoding:'utf8'});assert.equal(ps.status,0);
  const found=[];
  for(const line of ps.stdout.split('\n')) {
    const m=line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(.{24})\s+(.+)$/);
    if(!m)continue;
    if(Number(m[2])===group)assert(m[5].startsWith(app+'/Contents/'),'Unexpected process in owned browser group');
    if(!m[5].startsWith(app+'/Contents/'))continue;
    assert.equal(Number(m[3]),process.getuid());
    found.push({pid:Number(m[1]),sameProcessGroup:Number(m[2])===group,renderer:m[5].includes('Helper (Renderer)'),generationSHA256:sha(m[1]+':'+m[4]+':'+m[5])});
  }
  return found;
}
export async function main(app,bindingFile,out,warningApprovalFile=null) {
  assert([app,bindingFile,out].every(path.isAbsolute));
  const info=fs.lstatSync(out);assert(info.isDirectory()&&!info.isSymbolicLink()&&info.uid===process.getuid()&&(info.mode&0o077)===0&&fs.readdirSync(out).length===0);
  const binding=JSON.parse(fs.readFileSync(bindingFile)),runtime=inspectRuntime(app,binding);
  assert.equal(inventory(-1,app).length,0,'Research runtime already in use');
  const sources=[fileURLToPath(import.meta.url),path.join(here,'fixtures/font-policy-fixture.mjs'),path.join(here,'fixtures/font-policy-realm.js'),path.join(here,'fixtures/font-policy-semantics.mjs'),path.join(here,'fixtures/font-runtime-closure.mjs'),path.join(here,'fixtures/font-headed-admission.mjs'),path.join(here,'../native-qa-readiness.py'),path.join(here,'fixtures/qa-browser-environment.mjs'),path.join(here,'run-https-identity.mjs'),path.join(here,'../runtime-network/run-controlled-dns.mjs'),closureTool,...inputContracts.map(name=>path.join(here,'../../runtime/font-policy-v1',name))];
  const pins=Object.fromEntries(sources.map((file,index)=>[String(index),digest(file)]));
  const report={schemaVersion:1,status:'incomplete',actualBrowser:false,scope:'research headed page/worker font operations;not all-nine-context or manager/release qualification',bindingSHA256:digest(bindingFile),runtime:{version:binding.version,executableSHA256:runtime.executableSHA256,frameworkSHA256:runtime.frameworkSHA256,closureSHA256:runtime.closureSHA256},sources:pins,headed:true,sessions:[],admission:[],cleanup:null};
  fs.mkdirSync(path.join(out,'sources'),{mode:0o700});sources.forEach((file,index)=>fs.copyFileSync(file,path.join(out,'sources',index+'-'+path.basename(file))));
  let fixture=null,owner=null,failure=null,activeChild=null;const roots=new Map();
  const deadline=Date.now()+300000;
  const watchdog=setTimeout(()=>{report.deadlineExceeded=true;if(activeChild?.pid&&activeChild.exitCode===null&&activeChild.signalCode===null)activeChild.kill('SIGTERM');},300000);
  watchdog.unref();
  try {
    const phase=warningApprovalFile===null?null:consumeFontWarningPhase(warningApprovalFile,{bindingSHA256:report.bindingSHA256,controllerSHA256:pins['0']});
    if(phase)report.warningException={approvalSHA256:digest(warningApprovalFile),scope:phase.scope,expiresAt:phase.expiresAt};
    for(const mode of modes) {
      assert(Date.now()<deadline,'Finite headed stage deadline exceeded');
      const ready=spawnSync('python3',['-B',path.join(here,'../native-qa-readiness.py'),'--check'],{encoding:'utf8'});
      const gate=JSON.parse(ready.stdout),decision=assessFontAdmission(ready.status,gate,phase);report.admission.push({mode,exitCode:ready.status,readiness:gate,decision});
      if(!decision.allowed){report.status='resource-blocked';throw Error('ResourceAdmission');}
      if(!fixture)fixture=await createFontPolicyFixture({browserCustody:(client,port)=>browserSocketCustody(client,port,owner)});
      const previous=mode==='policy-a-repeat'?roots.get('policy-a'):null;
      const state=fixture.begin(previous?.nonce),root=previous?.root??('/private/tmp/neantik-font-policy-qa.'+state.nonce);
      const entry={mode,nonce:state.nonce,status:'incomplete',headed:true,rootSHA256:sha(root),profileAReopened:!!previous,cleanup:null};report.sessions.push(entry);
      const stderrFile=path.join(root,'witness.log');let identity=null,stderr=null,child=null,cdp=null,spawnFailed=false;
      try {
        if(!previous)fs.mkdirSync(root,{mode:0o700});identity=fs.lstatSync(root);
        if(previous)assert(identity.ino===previous.identity.ino&&identity.dev===previous.identity.dev,'Profile A root changed');
        else {
          roots.set(mode,{root,nonce:state.nonce,identity});
          fs.mkdirSync(path.join(root,'profile'),{mode:0o700});fs.mkdirSync(path.join(root,'crashes'),{mode:0o700});
          fs.writeFileSync(path.join(root,'marker'),'NeAntikFontPolicyQA-v1\n'+state.nonce+'\n',{mode:0o600,flag:'wx'});
          fs.writeFileSync(stderrFile,'',{mode:0o600,flag:'wx'});
        }
        stderr=fs.openSync(stderrFile,fs.constants.O_RDWR|fs.constants.O_NOFOLLOW);
        const logIdentity=fs.fstatSync(stderr);assert(logIdentity.isFile()&&logIdentity.uid===process.getuid()&&logIdentity.nlink===1&&(logIdentity.mode&0o077)===0);fs.ftruncateSync(stderr,0);
        const env=browserFixtureEnvironment();Object.assign(env,{NEANTIK_FONT_QA:'owned-v1',NEANTIK_FONT_QA_ROOT:root,NEANTIK_FONT_QA_NONCE:state.nonce});
        if(mode!=='native')env.NEANTIK_PROFILE_SEED=mode==='policy-b'?'42':'21';
        if(mode.startsWith('policy-'))env.NEANTIK_FONT_POLICY='system-v1';
        const flags=['--user-data-dir='+path.join(root,'profile'),'--use-mock-keychain','--remote-debugging-pipe','--enable-logging=stderr','--log-file='+stderrFile,'--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update','--disable-sync','--disable-extensions','--disable-quic','about:blank'];
        Object.assign(entry,{seed:env.NEANTIK_PROFILE_SEED??null,fontPolicy:env.NEANTIK_FONT_POLICY??'native',launchArguments:flags,configurationSHA256:sha(JSON.stringify({flags,seed:env.NEANTIK_PROFILE_SEED??null,policy:env.NEANTIK_FONT_POLICY??null}))});
        child=spawn(runtime.executable,flags,{env,stdio:['ignore','ignore',stderr,'pipe','pipe'],detached:true});child.once('error',()=>{spawnFailed=true;});
        activeChild=child;
        await new Promise((resolve,reject)=>{child.once('spawn',resolve);child.once('error',reject);});
        assert(Number.isSafeInteger(child.pid)&&child.pid>0);entry.browserPID=child.pid;entry.processGroup=child.pid;report.actualBrowser=true;
        owner={pid:child.pid,runtimeApp:app};cdp=new OwnedPipeCDP(child.stdio[3],child.stdio[4],20000);
        const version=await cdp.command('Browser.getVersion');assert.equal(version.product.split('/').at(-1),binding.version);
        const target=await cdp.command('Target.createTarget',{url:'about:blank'}),attached=await cdp.command('Target.attachToTarget',{targetId:target.targetId,flatten:true});
        await cdp.command('Page.enable',{},attached.sessionId);const navigation=await cdp.command('Page.navigate',{url:state.url},attached.sessionId);assert(!navigation.errorText);
        assert(await until(()=>fixture.observation().result!==null,35000),'Owned font operations missing');
        const tree=await cdp.command('Page.getFrameTree',{},attached.sessionId);assert.equal(tree.frameTree.frame.url,state.url);entry.documentConfirmed=true;
        entry.liveProcesses=inventory(child.pid,app);const acknowledgements=parseAcknowledgements(privateLog(stderrFile).toString('utf8'),state.nonce);
        assert(acknowledgements.some(row=>row.role==='browser'&&row.pid===child.pid),'Browser ACK missing');
        const renderers=entry.liveProcesses.filter(row=>row.renderer);assert(renderers.length>0,'No live owned renderer');
        for(const process of renderers)assert(acknowledgements.some(row=>row.role==='renderer'&&row.pid===process.pid),'Live renderer ACK missing');
        entry.acknowledgements=acknowledgements;
        // Retain custody/witness evidence before semantic analysis so a parser
        // correction can be evaluated offline without discarding that evidence.
        validateProbeEnvelope(fixture.observation().result,state.nonce,fixture.resourceHashes);
        entry.behavior=checkFontSession(fixture.observation().result,mode);entry.status='observed';
      }finally {
        if(cdp&&child?.exitCode===null)await cdp.command('Browser.close').catch(()=>{});
        const exited=()=>!child||spawnFailed||child.exitCode!==null||child.signalCode!==null;
        const graceful=await until(exited,7000);if(!graceful&&child)child.kill('SIGTERM');await until(exited,3000);cdp?.close();if(stderr!==null)fs.closeSync(stderr);
        if(child?.pid&&inventory(child.pid,app).length){try{process.kill(-child.pid,'SIGTERM');}catch(e){if(e.code!=='ESRCH')throw e;}await until(()=>inventory(child.pid,app).length===0,5000);}
        const remaining=child?.pid?inventory(child.pid,app).length:0;
        entry.cleanup={browserExited:exited(),gracefulBrowserClose:graceful,exitCode:child?.exitCode??null,ownedProcessesRemaining:remaining};
        Object.assign(entry,{fixture:fixture.finish()});owner=null;activeChild=null;
        if(stderr!==null)fs.writeFileSync(path.join(out,mode+'-stderr-private.log'),privateLog(stderrFile),{mode:0o600,flag:'wx'});
        assert.equal(remaining,0);
        if(child)assert(exited()&&graceful&&child.exitCode===0,'Browser close incomplete');
        if(identity) {
          const current=fs.lstatSync(root);assert(current.isDirectory()&&!current.isSymbolicLink()&&current.ino===identity.ino&&current.dev===identity.dev&&current.uid===process.getuid());
          if(mode==='policy-a'&&entry.status==='observed')entry.cleanup.ownedRootRetainedForARepeat=true;
          else {fs.rmSync(root,{recursive:true});roots.delete(previous?'policy-a':mode);entry.cleanup.ownedRootRemoved=true;}
        }
      }
    }
    report.aba=checkFontABA(report.sessions.find(row=>row.mode==='policy-a').fixture.result,report.sessions.find(row=>row.mode==='policy-a-repeat').fixture.result);
    report.status='observed';
  }catch(error){failure=error;if(report.status!=='resource-blocked')report.status='failed';report.failureClass=error.message==='ResourceAdmission'?'resource-admission':'owned-font-stage-incomplete';report.privateFailure={kind:error.name,message:String(error.message).slice(0,2000)};}
  finally {
    clearTimeout(watchdog);
    try {
      if(fixture)await fixture.close();
      const remaining=inventory(-1,app).length;
      if(remaining===0)for(const [key,value] of roots) {
        const info=fs.lstatSync(value.root);assert(info.isDirectory()&&!info.isSymbolicLink()&&info.uid===process.getuid()&&info.ino===value.identity.ino&&info.dev===value.identity.dev);
        fs.rmSync(value.root,{recursive:true});roots.delete(key);
      }
      report.cleanup={fixtureClosed:true,ownedProcessesRemaining:remaining,ownedRootsRemaining:roots.size};
      assert.equal(remaining,0);assert.equal(roots.size,0);
    }catch {report.cleanup??={fixtureClosed:false};report.status='failed';failure??=Error('FixtureCleanup');}
    try {inspectRuntime(app,binding);for(const [index,file] of sources.entries())assert.equal(digest(file),pins[String(index)]);assert.equal(digest(bindingFile),report.bindingSHA256);report.inputsRechecked=true;}catch(error) {report.inputsRechecked=false;report.status='failed';report.privateInputFailure={kind:error.name,message:String(error.message).slice(0,2000)};failure??=Error('InputsChanged');}
    report.resourceHashes=fixture?.resourceHashes??null;report.completedAt=new Date().toISOString();save(path.join(out,'observations.json'),report);
    console.log(JSON.stringify({status:report.status,sessions:report.sessions.length,actualBrowser:report.actualBrowser,releaseQualified:false}));
  }
  if(failure)process.exitCode=1;
  return report;
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  assert([5,6].includes(process.argv.length),'Usage: node run-font-policy.mjs OWN_SIGNED_RUNTIME RESEARCH_BINDING FRESH_PRIVATE_OUTPUT [EXPLICIT_ONE_SHOT_WARNING_APPROVAL]');
  main(...process.argv.slice(2)).catch(()=>{console.error('Owned font fixture setup failed; no identities or logs emitted');process.exitCode=1;});
}

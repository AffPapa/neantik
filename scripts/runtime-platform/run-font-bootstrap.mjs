// Actual early-refusal controls for the fixed font QA seam. No ordinary profile.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {spawn,spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';
import {inspectRuntime} from './run-font-policy.mjs';
import {browserFixtureEnvironment} from './fixtures/qa-browser-environment.mjs';
const here=path.dirname(fileURLToPath(import.meta.url));
const sha=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
const save=(file,value)=>fs.writeFileSync(file,JSON.stringify(value,null,2)+'\n',{mode:0o600,flag:'wx'});
export const bootstrapCases=Object.freeze(['marker-fifo','log-fifo','profile-symlink','permissive-root','invalid-marker','redirected-raw-profile','forged-approval','malformed-request','missing-pipe']);
export function validateBootstrapExit(value) {
  // content::RESULT_CODE_LAST_CODE=5; Chrome unsupported parameter is +8.
  // A crash, timeout, success or arbitrary failure is not a refusal PASS.
  assert.equal(value.exitCode,13,'Expected exact early unsupported-parameter exit');
  assert.equal(value.signal,null);assert.equal(value.timedOut,false);
  assert.equal(value.nativeACKs,0,'Malformed request reached font registration');
  assert.equal(value.profileEntries,0,'Malformed request created browser data');
  assert.equal(value.crashEntries,0,'Early refusal started Crashpad');
  assert.equal(value.ownedProcessesRemaining,0);
  assert.equal(value.stderrDrainComplete,true,'Child stderr capture incomplete');
}
function inventory(app) {
  const p=spawnSync('/bin/ps',['-axo','pid=,pgid=,uid=,comm='],{encoding:'utf8'});assert.equal(p.status,0);
  return p.stdout.split('\n').flatMap(line=>{
    const m=line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(.+)$/);
    if(!m||!m[4].startsWith(app+'/Contents/'))return [];
    assert.equal(Number(m[3]),process.getuid());return [{pid:Number(m[1]),group:Number(m[2])}];
  });
}
async function waitExit(child,ms) {
  const end=Date.now()+ms;
  while(child.exitCode===null&&child.signalCode===null&&Date.now()<end)await delay(20);
  return child.exitCode!==null||child.signalCode!==null;
}
export function monitorBootstrapChild(child) {
  // Install listeners synchronously after spawn. An exit notification alone
  // does not mean that the final stderr bytes have reached the parent.
  const chunks=[];let size=0,closed=false;
  child.stderr.on('data',bytes=>{size+=bytes.length;if(size<=65536)chunks.push(bytes);});
  child.once('close',()=>{closed=true;});
  return {async finish(timeout=5000) {
    const exited=await waitExit(child,timeout);
    if(!exited){child.kill('SIGTERM');await waitExit(child,3000);}
    const end=Date.now()+3000;
    while(!closed&&Date.now()<end)await delay(20);
    assert(closed&&child.stderr.readableEnded,'Child stderr did not finish');
    assert(size<=65536,'Early-refusal log overflow');
    return {log:Buffer.concat(chunks),stderrBytes:size,stderrDrainComplete:true,timedOut:!exited};
  }};
}
export async function main(app,bindingFile,out) {
  assert([app,bindingFile,out].every(path.isAbsolute));
  const info=fs.lstatSync(out);assert(info.isDirectory()&&!info.isSymbolicLink()&&info.uid===process.getuid()&&(info.mode&0o077)===0&&fs.readdirSync(out).length===0);
  const binding=JSON.parse(fs.readFileSync(bindingFile)),runtime=inspectRuntime(app,binding);
  assert.equal(inventory(app).length,0,'Owned research runtime in use');
  const source=fs.readFileSync(fileURLToPath(import.meta.url)),bindingBytes=fs.readFileSync(bindingFile);
  const inputs=[fileURLToPath(import.meta.url),path.join(here,'run-font-policy.mjs'),path.join(here,'fixtures/qa-browser-environment.mjs'),path.join(here,'fixtures/font-runtime-closure.mjs'),path.join(here,'../native-qa-readiness.py')];
  const pins=Object.fromEntries(inputs.map(file=>[path.relative(here,file),sha(fs.readFileSync(file))]));
  const report={schemaVersion:1,status:'incomplete',actualBrowser:false,scope:'nine early bootstrap refusal cases only; not font drawing or managed-policy qualification',runtime,bindingSHA256:sha(bindingBytes),controllerSHA256:sha(source),sources:pins,cases:[],cleanup:null};
  fs.mkdirSync(path.join(out,'sources'),{mode:0o700});inputs.forEach((file,index)=>fs.copyFileSync(file,path.join(out,'sources',index+'-'+path.basename(file))));
  const deadline=Date.now()+120000;let failure=null,active=null;
  try {
    for(const name of bootstrapCases) {
      assert(Date.now()<deadline,'Finite bootstrap stage deadline');
      const ready=spawnSync('python3',['-B',path.join(here,'../native-qa-readiness.py'),'--check'],{encoding:'utf8'});
      const readiness=JSON.parse(ready.stdout);
      if(ready.status!==0||!readiness.eligibleForAttempt){report.status='resource-blocked';report.readiness=readiness;throw Error('ResourceAdmission');}
      const nonce=crypto.randomBytes(16).toString('hex'),root='/private/tmp/neantik-font-policy-qa.'+nonce;
      fs.mkdirSync(root,{mode:0o700});const identity=fs.lstatSync(root);let child=null;
      const entry={name,status:'incomplete',readiness,rootSHA256:sha(root)};report.cases.push(entry);
      try {
        for(const dir of ['profile','crashes','otherprofile','target'])fs.mkdirSync(path.join(root,dir),{mode:0o700});
        fs.writeFileSync(path.join(root,'marker'),'NeAntikFontPolicyQA-v1\n'+nonce+'\n',{mode:0o600});
        fs.writeFileSync(path.join(root,'witness.log'),'',{mode:0o600});
        const env=browserFixtureEnvironment();Object.assign(env,{NEANTIK_FONT_QA:'owned-v1',NEANTIK_FONT_QA_ROOT:root,NEANTIK_FONT_QA_NONCE:nonce});
        let profile=path.join(root,'profile');
        if(name.endsWith('-fifo')) {
          const file=path.join(root,name==='marker-fifo'?'marker':'witness.log');fs.unlinkSync(file);
          assert.equal(spawnSync('/usr/bin/mkfifo',['-m','600',file],{stdio:'ignore'}).status,0);
        }else if(name==='profile-symlink') {fs.rmdirSync(profile);fs.symlinkSync(path.join(root,'target'),profile);}
        else if(name==='permissive-root')fs.chmodSync(root,0o755);
        else if(name==='invalid-marker'||name==='forged-approval') {
          fs.writeFileSync(path.join(root,'marker'),'owned-invalid-marker\n');
          if(name==='forged-approval')env.NEANTIK_FONT_QA_APPROVED=nonce;
        }else if(name==='redirected-raw-profile')profile=path.join(root,'redirect-target');
        else if(name==='malformed-request')env.NEANTIK_FONT_QA='invalid-v1';
        const args=['--user-data-dir='+profile,'--use-mock-keychain','--remote-debugging-pipe','--enable-logging=stderr','--log-file='+path.join(root,'witness.log'),'--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update','--disable-sync','--disable-extensions','about:blank'];
        const pipes=name==='missing-pipe'?[]:['pipe','pipe'];
        child=spawn(runtime.executable,args,{env,detached:true,stdio:['ignore','ignore','pipe',...pipes]});active=child;
        const capture=monitorBootstrapChild(child);
        await new Promise((resolve,reject)=>{child.once('spawn',resolve);child.once('error',reject);});report.actualBrowser=true;entry.pid=child.pid;
        const {log,...captureResult}=await capture.finish();Object.assign(entry,captureResult);
        fs.writeFileSync(path.join(out,name+'-stderr-private.log'),log,{mode:0o600,flag:'wx'});
        Object.assign(entry,{exitCode:child.exitCode,signal:child.signalCode,nativeACKs:log.toString('utf8').split('NEANTIK_FONT_QA_V1').length-1,
          profileEntries:fs.existsSync(profile)?fs.readdirSync(profile).length:0,crashEntries:fs.readdirSync(path.join(root,'crashes')).length,
          otherOwnedDataEntries:fs.readdirSync(path.join(root,'otherprofile')).length+fs.readdirSync(path.join(root,'target')).length,
          ownedProcessesRemaining:inventory(app).length});
        assert.equal(entry.otherOwnedDataEntries,0);
        if(name==='redirected-raw-profile'){entry.redirectTargetCreated=fs.existsSync(profile);assert.equal(entry.redirectTargetCreated,false);}
        validateBootstrapExit(entry);entry.status='observed-refusal';
      }finally {
        if(child&&child.exitCode===null&&child.signalCode===null){child.kill('SIGTERM');await waitExit(child,3000);}
        const remaining=inventory(app);
        if(remaining.length&&child?.pid&&remaining.every(p=>p.group===child.pid)) {
          process.kill(-child.pid,'SIGTERM');await delay(500);
        }
        assert.equal(inventory(app).length,0,'Owned child still active; retain root for diagnosis');active=null;
        const current=fs.lstatSync(root);assert(current.isDirectory()&&!current.isSymbolicLink()&&current.uid===process.getuid()&&current.ino===identity.ino&&current.dev===identity.dev);
        fs.chmodSync(root,0o700);fs.rmSync(root,{recursive:true});entry.ownedRootRemoved=true;
      }
    }
    report.status='observed';
  }catch(error){failure=error;if(report.status!=='resource-blocked')report.status='failed';report.privateFailure={kind:error.name,message:String(error.message).slice(0,1000)};}
  finally {
    if(active&&active.exitCode===null&&active.signalCode===null){active.kill('SIGTERM');await waitExit(active,3000);}
    report.cleanup={ownedProcessesRemaining:inventory(app).length,ownedRootsRemaining:report.cases.filter(c=>!c.ownedRootRemoved).length};
    try {
      assert.equal(report.cleanup.ownedProcessesRemaining,0);assert.equal(report.cleanup.ownedRootsRemaining,0);
      inspectRuntime(app,binding);assert.equal(sha(fs.readFileSync(bindingFile)),report.bindingSHA256);
      for(const file of inputs)assert.equal(sha(fs.readFileSync(file)),pins[path.relative(here,file)]);
      report.inputsRechecked=true;
    }catch{report.status='failed';report.inputsRechecked=false;failure??=Error('InputOrCleanupChanged');}
    report.completedAt=new Date().toISOString();save(path.join(out,'observations.json'),report);
    console.log(JSON.stringify({status:report.status,cases:report.cases.length,actualBrowser:report.actualBrowser,releaseQualified:false}));
  }
  if(failure)process.exitCode=1;return report;
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  assert.equal(process.argv.length,5,'Usage: node run-font-bootstrap.mjs OWN_SIGNED_RUNTIME RESEARCH_BINDING FRESH_PRIVATE_OUTPUT');
  main(...process.argv.slice(2)).catch(()=>{console.error('Owned font bootstrap setup failed; no logs emitted');process.exitCode=1;});
}

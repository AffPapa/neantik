// New font surface only. Existing Canvas/WebGL/Audio and font receipts retained.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {spawn,spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';
import {parseAcknowledgements} from './run-font-policy.mjs';
import {inspectFontContextRuntime as inspectRuntime} from './fixtures/font-context-runtime.mjs';
import {monitorBootstrapChild} from './run-font-bootstrap.mjs';
import {browserSocketCustody} from './run-https-identity.mjs';
import {browserFixtureEnvironment} from './fixtures/qa-browser-environment.mjs';
import {createFontContextFixture,fontContextNames,fontWorkletSource} from './fixtures/font-context-fixture.mjs';
import {FontLifecyclePipe,lifecycleSocketAdapter} from './fixtures/font-lifecycle-pipe.mjs';
import {OwnContextLifecycleRecorder} from './fixtures/vector-semantics/context-lifecycle-recorder.mjs';
import {checkFontContextCapture,checkFontContextLifecycle,checkFontContextABA,checkFontOOPIFBinding,checkFontWorkerBinding} from './fixtures/font-context-semantics.mjs';
const here=path.dirname(fileURLToPath(import.meta.url)),sha=value=>crypto.createHash('sha256').update(value).digest('hex');
const save=(file,value)=>fs.writeFileSync(file,JSON.stringify(value,null,2)+'\n',{mode:0o600,flag:'wx'});
const modes=['native','policy-a','policy-b','policy-a-repeat'];
async function until(test,ms){const end=Date.now()+ms;while(Date.now()<end){if(await test())return true;await delay(30);}return false;}
function inventory(app,group=-1) {
  const p=spawnSync('/bin/ps',['-axo','pid=,pgid=,uid=,lstart=,comm='],{encoding:'utf8'});assert.equal(p.status,0);
  return p.stdout.split('\n').flatMap(line=>{
    const m=line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(.{24})\s+(.+)$/);if(!m)return [];
    if(Number(m[2])===group)assert(m[5].startsWith(app+'/Contents/'),'Unexpected member of owned process group');
    if(!m[5].startsWith(app+'/Contents/'))return [];assert.equal(Number(m[3]),process.getuid());
    return [{pid:Number(m[1]),group:Number(m[2]),renderer:m[5].includes('Helper (Renderer)'),generationSHA256:sha(m[1]+':'+m[4]+':'+m[5])}];
  });
}
export async function main(app,bindingFile,out) {
  assert([app,bindingFile,out].every(path.isAbsolute));
  const info=fs.lstatSync(out);assert(info.isDirectory()&&!info.isSymbolicLink()&&info.uid===process.getuid()&&(info.mode&0o077)===0&&fs.readdirSync(out).length===0);
  const bindingBytes=fs.readFileSync(bindingFile),binding=JSON.parse(bindingBytes),runtime=inspectRuntime(app,binding);
  assert.equal(inventory(app).length,0,'Owned runtime already in use');
  const inputs=[fileURLToPath(import.meta.url),...['run-font-policy.mjs','run-font-bootstrap.mjs','run-https-identity.mjs','fixtures/font-context-page.js','fixtures/font-context-fixture.mjs','fixtures/font-context-semantics.mjs','fixtures/font-lifecycle-pipe.mjs','fixtures/font-policy-realm.js','fixtures/font-policy-semantics.mjs','fixtures/font-runtime-closure.mjs','fixtures/vector-semantics/context-lifecycle-recorder.mjs','fixtures/qa-browser-environment.mjs','../native-qa-readiness.py','../runtime-network/run-controlled-dns.mjs'].map(file=>path.join(here,file))];
  inputs.push(path.join(here,'fixtures/font-generic-realm.js'),path.join(here,'fixtures/font-context-runtime.mjs'));
  inputs.push(path.join(here,'../../runtime/font-policy-v1/witness/fonts/owned-canary.ttf'),path.join(here,'fixtures/vector-semantics/own-ahem.woff2'));
  const pins=Object.fromEntries(inputs.map(file=>[path.relative(here,file),sha(fs.readFileSync(file))]));
  fs.mkdirSync(path.join(out,'sources'),{mode:0o700});inputs.forEach((file,index)=>fs.copyFileSync(file,path.join(out,'sources',index+'-'+path.basename(file))));
  const report={schemaVersion:1,status:'incomplete',scope:'new font-only nine-context research, not release qualification',actualBrowser:false,headed:true,runtime:{version:binding.version,executableSHA256:runtime.executableSHA256,frameworkSHA256:runtime.frameworkSHA256,closureSHA256:runtime.closureSHA256},bindingSHA256:sha(bindingBytes),sources:pins,sessions:[],admission:[],cleanup:null};
  let fixture=null,owner=null,recorder=null,activeChild=null,failure=null;const roots=new Map();
  const watchdog=setTimeout(()=>{report.deadlineExceeded=true;if(activeChild?.exitCode===null&&activeChild.signalCode===null)activeChild.kill('SIGTERM');},300000);watchdog.unref();
  try {
    for(const mode of modes) {
      assert(!report.deadlineExceeded,'Finite stage deadline');
      const ready=spawnSync('python3',['-B',path.join(here,'../native-qa-readiness.py'),'--check'],{encoding:'utf8'}),readiness=JSON.parse(ready.stdout);report.admission.push({mode,exitCode:ready.status,readiness});
      if(ready.status!==0||!readiness.eligibleForAttempt){report.status='resource-blocked';throw Error('ResourceAdmission');}
      if(!fixture)fixture=await createFontContextFixture({browserCustody:(client,port)=>browserSocketCustody(client,port,owner),confirm:(name,nonce)=>recorder?recorder.confirm(name,nonce):{confirmed:false}});
      const witness=JSON.parse(fs.readFileSync(path.join(here,'../../runtime/font-policy-v1/chromium-font-witness.json')));
      assert.equal(fixture.resourceHashes.canarySHA256,witness.fixedAssets.find(row=>row.path.endsWith('/owned-canary.ttf')).sha256);
      assert.equal(fixture.resourceHashes.ahemSHA256,'d8a849ee88febbe343f153a61b105aa542b997b8cd5c4e0839d468477aa17fb0');
      const previous=mode==='policy-a-repeat'?roots.get('policy-a'):null,state=fixture.begin(previous?.nonce),root=previous?.root??('/private/tmp/neantik-font-policy-qa.'+state.nonce);
      const entry={mode,nonce:state.nonce,status:'incomplete',profileAReopened:!!previous,rootSHA256:sha(root),cleanup:null};report.sessions.push(entry);
      let identity=null,child=null,pipe=null,capture=null,pageId=null;
      try {
        if(!previous){
          fs.mkdirSync(root,{mode:0o700});identity=fs.lstatSync(root);roots.set(mode,{root,nonce:state.nonce,identity});
          fs.mkdirSync(path.join(root,'profile'),{mode:0o700});fs.mkdirSync(path.join(root,'crashes'),{mode:0o700});fs.writeFileSync(path.join(root,'marker'),'NeAntikFontPolicyQA-v1\n'+state.nonce+'\n',{mode:0o600});fs.writeFileSync(path.join(root,'witness.log'),'',{mode:0o600});
        }else{identity=fs.lstatSync(root);assert(identity.ino===previous.identity.ino&&identity.dev===previous.identity.dev,'A root changed');}
        const env=browserFixtureEnvironment();Object.assign(env,{NEANTIK_FONT_QA:'owned-v1',NEANTIK_FONT_QA_ROOT:root,NEANTIK_FONT_QA_NONCE:state.nonce});
        if(mode!=='native')Object.assign(env,{NEANTIK_PROFILE_SEED:mode==='policy-b'?'42':'21',NEANTIK_FONT_POLICY:'system-v1'});
        const args=['--user-data-dir='+path.join(root,'profile'),'--use-mock-keychain','--remote-debugging-pipe','--enable-logging=stderr','--log-file='+path.join(root,'witness.log'),'--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update','--disable-sync','--disable-extensions','--disable-quic','about:blank'];
        entry.configurationSHA256=sha(JSON.stringify({args,seed:env.NEANTIK_PROFILE_SEED??null,policy:env.NEANTIK_FONT_POLICY??null}));entry.arguments=args;
        child=spawn(runtime.executable,args,{env,detached:true,stdio:['ignore','ignore','pipe','pipe','pipe']});activeChild=child;capture=monitorBootstrapChild(child);
        await new Promise((resolve,reject)=>{child.once('spawn',resolve);child.once('error',reject);});report.actualBrowser=true;entry.pid=child.pid;owner={pid:child.pid,runtimeApp:app};
        pipe=new FontLifecyclePipe(child.stdio[3],child.stdio[4],fixture.origins);const socket=lifecycleSocketAdapter(pipe);
        recorder=new OwnContextLifecycleRecorder(socket,(bound,method,params,session)=>{assert.equal(bound,socket);return pipe.command(method,params,session);},fixture.origins);
        const version=await pipe.command('Browser.getVersion');assert.equal(version.product.split('/').at(-1),binding.version);
        pageId=(await pipe.command('Target.createTarget',{url:'about:blank'})).targetId;await recorder.start(pageId);
        const session=recorder.targets.get(pageId).sessionId,navigation=await pipe.command('Page.navigate',{url:state.url},session);assert(!navigation.errorText);
        assert(await until(()=>fixture.observation().result!==null,120000),'Font context result missing');
        entry.rawCapture=fixture.observation().result;
        entry.liveProcesses=inventory(app,child.pid);entry.rawCaptureComplete=true;
        const tree=await pipe.command('Page.getFrameTree',{},session);entry.frameTree=tree;assert.equal(tree.frameTree.frame.url,state.url);entry.documentConfirmed=true;
        entry.behavior=checkFontContextCapture(fixture.observation().result,mode,fixture.resourceHashes);
        const cross=recorder.receipts.get('cross-origin OOPIF'),crossValue=fixture.observation().result.results.find(row=>row.name==='cross-origin OOPIF');
        assert(cross,'Missing independent OOPIF receipt');
        const remoteTree=await pipe.command('Page.getFrameTree',{},cross.target.sessionId);entry.remoteFrameTree=remoteTree;
        entry.crossTarget={...cross.target};entry.crossContext={...cross.context};
        const frame=checkFontOOPIFBinding(tree,cross,remoteTree,crossValue,fixture.origins[1],state.nonce);
        const crossURL=new URL(frame.url);assert.equal(crossURL.origin,fixture.origins[1]);assert.equal(crossURL.searchParams.get('nonce'),state.nonce);assert.equal(crossURL.searchParams.get('contextNonce'),crossValue.contextNonce);
        const oopif={targetType:cross.target.type,separateTarget:cross.target.targetId!==pageId,frameLinked:true,foreignOrigin:true};
        const frameContexts=fontContextNames.slice(5).map(name=>{
          const record=recorder.receipts.get(name),child=name==='cross-origin OOPIF'?frame:tree.frameTree.childFrames?.find(row=>row.frame.id===record?.context.auxData?.frameId)?.frame;
          assert(child&&record.context.auxData.isDefault===true,'Missing own child-frame context');
          if(name==='about:blank iframe')assert.equal(child.url,'about:blank');
          else if(name==='srcdoc iframe')assert.equal(child.url,'about:srcdoc');
          else{const url=new URL(child.url);assert.equal(url.origin,fixture.origins[name==='cross-origin OOPIF'?1:0]);assert.equal(url.pathname,'/frame');assert.equal(url.searchParams.get('name'),name);assert.equal(url.searchParams.get('nonce'),state.nonce);}
          return {name,childFrameLinked:true,defaultContext:true,expectedURL:true};
        });
        entry.workerBindings=['DedicatedWorker','SharedWorker','ServiceWorker','AudioWorklet'].map(name=>checkFontWorkerBinding(name,recorder.receipts.get(name),state.url,state.nonce,fixture.observation().requests,entry.rawCapture.results.find(row=>row.name===name).contextNonce,pageId,sha(fontWorkletSource(entry.rawCapture.results.find(row=>row.name===name).contextNonce))));
        const identities=fontContextNames.map(name=>{const r=recorder.receipts.get(name);assert(r?.context.uniqueId);return sha(r.context.uniqueId);});
        const live={receipts:recorder.summary(),recorderErrors:[...recorder.failures],contextIdentitySHA256:identities,oopif,frameContexts};
        entry.liveBeforeTeardown=live;assert.equal(live.receipts.length,9);assert(live.receipts.every(row=>row.confirmed&&row.terminated===false),'Missing live negative boundary');assert.throws(()=>checkFontContextLifecycle(live),/Context still live/);entry.actualLiveNegativeRejected=true;
        fixture.requestTeardown();assert(await until(()=>fixture.observation().closed!==null,15000),'Font teardown result missing');
        const closed=fixture.observation().closed;assert.equal(closed.teardownAllowed,true);assert.deepEqual(closed.errors,[]);assert.equal(closed.completed,9);
        entry.lifecycle={...await recorder.finish(pageId),contextIdentitySHA256:identities,oopif,frameContexts};pageId=null;
        entry.lifecycleVerdict=checkFontContextLifecycle(entry.lifecycle);entry.operationsComplete=true;
      }catch(error){
        entry.operationFailure={kind:error.name,message:String(error.message).slice(0,2000)};throw error;
      }finally {
        if(fixture?.observation()){fixture.requestTeardown();if(recorder&&pageId)try{await until(()=>fixture.observation().closed!==null,3000);entry.failureLifecycle=await recorder.finish(pageId);}catch{}}
        recorder?.dispose();recorder=null;
        if(pipe&&child?.exitCode===null)await pipe.command('Browser.close').catch(()=>{});
        let captureFailure=null,log=null;
        if(capture)try{const result=await capture.finish(7000);log=result.log;const {log:unused,...closed}=result;entry.browserClosure={...closed,exitCode:child.exitCode,signal:child.signalCode};fs.writeFileSync(path.join(out,mode+'-stderr-private.log'),log,{mode:0o600,flag:'wx'});}catch(error){captureFailure=error;entry.captureFailure=error.name;}
        // The validated code-clone cleanup helper deliberately has its own group.
        // Give it a bounded natural-exit window; never signal an unrelated group.
        if(child?.pid)await until(()=>inventory(app).length===0,3000);
        if(child?.pid&&inventory(app).length){
          const processes=inventory(app);entry.cleanupCandidates=processes;assert(processes.every(row=>row.group===child.pid));
          if(processes.length)try{process.kill(-child.pid,'SIGTERM');}catch(error){if(error.code!=='ESRCH')throw error;}
          await until(()=>inventory(app).length===0,5000);
        }
        const remaining=inventory(app).length;entry.cleanup={ownedProcessesRemaining:remaining};assert.equal(remaining,0);
        pipe?.close();owner=null;activeChild=null;
        entry.fixture=fixture.finish();
        delete entry.rawCapture;
        if(identity){const current=fs.lstatSync(root);assert(current.isDirectory()&&!current.isSymbolicLink()&&current.uid===process.getuid()&&current.ino===identity.ino&&current.dev===identity.dev);if(mode==='policy-a'&&entry.operationsComplete&&!captureFailure)entry.cleanup.ownedRootRetainedForARepeat=true;else{fs.rmSync(root,{recursive:true});roots.delete(previous?'policy-a':mode);entry.cleanup.ownedRootRemoved=true;}}
        if(captureFailure)throw captureFailure;
        if(child){
          assert.equal(child.exitCode,0);assert.equal(child.signalCode,null);assert.equal(entry.browserClosure.timedOut,false);assert.equal(entry.browserClosure.stderrDrainComplete,true);
          entry.acknowledgements=parseAcknowledgements(log.toString('utf8'),state.nonce);assert(entry.acknowledgements.some(row=>row.pid===child.pid&&row.role==='browser'));
          assert(entry.liveProcesses?.some(row=>row.renderer),'Live renderer evidence missing');
          for(const process of entry.liveProcesses)if(process.renderer)assert(entry.acknowledgements.some(row=>row.pid===process.pid&&row.role==='renderer'),'Live renderer ACK missing');
        }
        if(entry.operationsComplete)entry.status=mode==='native'?'observed-native-gap-negative':'observed';
      }
    }
    report.aba=checkFontContextABA(report.sessions.find(x=>x.mode==='policy-a').fixture.result,report.sessions.find(x=>x.mode==='policy-a-repeat').fixture.result,fixture.resourceHashes);report.status='observed';
  }catch(error){failure=error;if(report.status!=='resource-blocked')report.status='failed';report.privateFailure={kind:error.name,message:String(error.message).slice(0,2000)};}
  finally {
    clearTimeout(watchdog);
    if(activeChild?.exitCode===null&&activeChild.signalCode===null){activeChild.kill('SIGTERM');await until(()=>activeChild.exitCode!==null||activeChild.signalCode!==null,3000);}
    recorder?.dispose();
    try{
      if(fixture)await fixture.close();const remaining=inventory(app).length;
      if(remaining===0)for(const [key,value] of roots){const stat=fs.lstatSync(value.root);assert(stat.isDirectory()&&!stat.isSymbolicLink()&&stat.ino===value.identity.ino&&stat.dev===value.identity.dev&&stat.uid===process.getuid());fs.rmSync(value.root,{recursive:true});roots.delete(key);}
      report.cleanup={ownedProcessesRemaining:remaining,ownedRootsRemaining:roots.size};assert.equal(remaining,0);assert.equal(roots.size,0);
      inspectRuntime(app,binding);for(const file of inputs)assert.equal(sha(fs.readFileSync(file)),pins[path.relative(here,file)]);assert.equal(sha(fs.readFileSync(bindingFile)),report.bindingSHA256);report.inputsRechecked=true;
    }catch{report.status='failed';report.inputsRechecked=false;failure??=Error('OwnedCleanupOrInputChange');}
    report.resourceHashes=fixture?.resourceHashes??null;report.completedAt=new Date().toISOString();save(path.join(out,'observations.json'),report);
    console.log(JSON.stringify({status:report.status,sessions:report.sessions.length,actualBrowser:report.actualBrowser,releaseQualified:false}));
  }
  if(failure)process.exitCode=1;return report;
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  assert.equal(process.argv.length,5,'Usage: node run-font-contexts.mjs OWN_SIGNED_RUNTIME RESEARCH_BINDING FRESH_PRIVATE_OUTPUT');
  main(...process.argv.slice(2)).catch(()=>{console.error('Own font-context setup failed; no logs emitted');process.exitCode=1;});
}

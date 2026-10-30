// Finite own-name Font Access successor; no earlier vector gate is replayed.
import assert from 'node:assert/strict';import crypto from 'node:crypto';import fs from 'node:fs';import path from 'node:path';
import {spawn,spawnSync} from 'node:child_process';import {fileURLToPath} from 'node:url';import {setTimeout as delay} from 'node:timers/promises';
import {inspectFontContextRuntime} from './fixtures/font-context-runtime.mjs';import {parseAcknowledgements} from './run-font-policy.mjs';
import {monitorBootstrapChild} from './run-font-bootstrap.mjs';import {browserSocketCustody} from './run-https-identity.mjs';
import {browserFixtureEnvironment} from './fixtures/qa-browser-environment.mjs';import {FontAccessPipe} from './fixtures/font-access-pipe.mjs';
import {createFontAccessFixture} from './fixtures/font-access-fixture.mjs';import {checkFontAccess,checkFontAccessABA} from './fixtures/font-access-semantics.mjs';
const here=path.dirname(fileURLToPath(import.meta.url)),sha=value=>crypto.createHash('sha256').update(value).digest('hex');
const until=async(test,ms)=>{const end=Date.now()+ms;while(Date.now()<end){if(await test())return true;await delay(30);}return false;};
function inventory(app,group=-1){
  const result=spawnSync('/bin/ps',['-axo','pid=,pgid=,uid=,lstart=,comm='],{encoding:'utf8'});assert.equal(result.status,0);
  return result.stdout.split('\n').flatMap(line=>{
    const m=line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(.{24})\s+(.+)$/);if(!m)return [];
    if(Number(m[2])===group)assert(m[5].startsWith(app+'/Contents/'),'Unexpected owned-group member');
    if(!m[5].startsWith(app+'/Contents/'))return [];assert.equal(Number(m[3]),process.getuid());
    return [{pid:Number(m[1]),group:Number(m[2]),renderer:m[5].includes('Helper (Renderer)'),generationSHA256:sha(m[1]+':'+m[4]+':'+m[5])}];
  });
}
export async function main(app,bindingFile,out){
  assert([app,bindingFile,out].every(path.isAbsolute));const info=fs.lstatSync(out);
  assert(info.isDirectory()&&!info.isSymbolicLink()&&info.uid===process.getuid()&&(info.mode&0o077)===0&&fs.readdirSync(out).length===0);
  const bindingBytes=fs.readFileSync(bindingFile),binding=JSON.parse(bindingBytes),runtime=inspectFontContextRuntime(app,binding);assert.equal(inventory(app).length,0);
  const sources=[fileURLToPath(import.meta.url),...['fixtures/font-access-pipe.mjs','fixtures/font-access-fixture.mjs','fixtures/font-access-page.js','fixtures/font-access-sfnt.js','fixtures/font-access-semantics.mjs','fixtures/font-lifecycle-pipe.mjs','fixtures/font-context-runtime.mjs','fixtures/font-runtime-closure.mjs','fixtures/qa-browser-environment.mjs','run-font-policy.mjs','run-font-bootstrap.mjs','run-https-identity.mjs','../runtime-network/run-controlled-dns.mjs','../native-qa-readiness.py','../verify-direct-update-runtime-pins.py'].map(name=>path.join(here,name))];
  for(const name of ['owned-canary.ttf','owned-family-collision.ttf'])sources.push(path.join(here,'../../runtime/font-policy-v1/witness/fonts',name));
  const pins=Object.fromEntries(sources.map(file=>[path.relative(here,file),sha(fs.readFileSync(file))]));fs.mkdirSync(path.join(out,'sources'),{mode:0o700});sources.forEach((file,i)=>fs.copyFileSync(file,path.join(out,'sources',i+'-'+path.basename(file))));
  const report={schemaVersion:1,status:'incomplete',scope:'fixed-name Font Access permission/blob operations;not release or native dialog UX',actualBrowser:false,headed:true,runtime:{version:binding.version,executableSHA256:runtime.executableSHA256,frameworkSHA256:runtime.frameworkSHA256,closureSHA256:runtime.closureSHA256},bindingSHA256:sha(bindingBytes),sourcePins:pins,sessions:[],admission:[],cleanup:null};
  let fixture=null,owner=null,activeChild=null,failure=null;const roots=new Map();
  const watchdog=setTimeout(()=>{report.deadlineExceeded=true;if(activeChild?.exitCode===null&&activeChild.signalCode===null)activeChild.kill('SIGTERM');},300000);watchdog.unref();
  try{
    for(const mode of ['native','seeded-native','policy-a','policy-b','policy-a-repeat']){
      assert(!report.deadlineExceeded,'Finite Font Access deadline');
      const readiness=spawnSync('python3',['-B',path.join(here,'../native-qa-readiness.py'),'--check'],{encoding:'utf8'}),gate=JSON.parse(readiness.stdout);report.admission.push({mode,exitCode:readiness.status,readiness:gate});
      if(readiness.status!==0||!gate.eligibleForAttempt){report.status='resource-blocked';throw Error('ResourceAdmission');}
      if(!fixture)fixture=await createFontAccessFixture({browserCustody:(client,port)=>browserSocketCustody(client,port,owner)});
      const previous=mode==='policy-a-repeat'?roots.get('policy-a'):null,state=fixture.begin(previous?.nonce),root=previous?.root??('/private/tmp/neantik-font-policy-qa.'+state.nonce);
      const entry={mode,nonce:state.nonce,status:'incomplete',profileAReopened:!!previous,rootSHA256:sha(root),cleanup:null};report.sessions.push(entry);
      let identity=null,child=null,pipe=null,capture=null,defaultContext=null;
      try{
        if(!previous){fs.mkdirSync(root,{mode:0o700});identity=fs.lstatSync(root);roots.set(mode,{root,nonce:state.nonce,identity});fs.mkdirSync(path.join(root,'profile'),{mode:0o700});fs.mkdirSync(path.join(root,'crashes'),{mode:0o700});fs.writeFileSync(path.join(root,'marker'),'NeAntikFontPolicyQA-v1\n'+state.nonce+'\n',{mode:0o600});fs.writeFileSync(path.join(root,'witness.log'),'',{mode:0o600});}
        else{identity=fs.lstatSync(root);assert(identity.ino===previous.identity.ino&&identity.dev===previous.identity.dev);}
        const env=browserFixtureEnvironment();Object.assign(env,{NEANTIK_FONT_QA:'owned-v1',NEANTIK_FONT_QA_ROOT:root,NEANTIK_FONT_QA_NONCE:state.nonce});
        if(mode!=='native')env.NEANTIK_PROFILE_SEED=mode==='policy-b'?'42':'21';if(mode.startsWith('policy'))env.NEANTIK_FONT_POLICY='system-v1';
        const args=['--user-data-dir='+path.join(root,'profile'),'--use-mock-keychain','--remote-debugging-pipe','--enable-logging=stderr','--log-file='+path.join(root,'witness.log'),'--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update','--disable-sync','--disable-extensions','--disable-quic','about:blank'];entry.arguments=args;
        entry.configurationSHA256=sha(JSON.stringify({args,seed:env.NEANTIK_PROFILE_SEED??null,policy:env.NEANTIK_FONT_POLICY??null}));
        child=spawn(runtime.executable,args,{env,detached:true,stdio:['ignore','ignore','pipe','pipe','pipe']});activeChild=child;capture=monitorBootstrapChild(child);
        await new Promise((resolve,reject)=>{child.once('spawn',resolve);child.once('error',reject);});owner={pid:child.pid,runtimeApp:app};report.actualBrowser=true;entry.pid=child.pid;
        pipe=new FontAccessPipe(child.stdio[3],child.stdio[4],fixture.origins,state.nonce);
        const version=await pipe.command('Browser.getVersion');assert.equal(version.product.split('/').at(-1),binding.version);
        const pageId=(await pipe.command('Target.createTarget',{url:'about:blank'})).targetId,session=(await pipe.command('Target.attachToTarget',{targetId:pageId,flatten:true})).sessionId;
        pipe.on('event',event=>{
          if(event.sessionId!==session)return;
          if(event.method==='Runtime.executionContextsCleared'||(event.method==='Runtime.executionContextDestroyed'&&event.params.executionContextId===defaultContext?.id))defaultContext=null;
          if(event.method==='Runtime.executionContextCreated'&&event.params.context.auxData?.isDefault===true&&event.params.context.auxData.frameId===pageId&&event.params.context.origin===fixture.origins[0])defaultContext=event.params.context;
        });
        await pipe.command('Runtime.enable',{},session);await pipe.command('Page.enable',{},session);
        const navigation=await pipe.command('Page.navigate',{url:state.url},session);assert(!navigation.errorText);
        assert(await until(()=>fixture.observation().ready!==null&&defaultContext?.uniqueId&&pipe.contexts.get(session)?.has(defaultContext.id),15000),'Font Access ready/default context missing');assert(defaultContext.auxData.frameId===pageId);
        const targetInfo=await pipe.command('Target.getTargetInfo',{targetId:pageId});entry.ownedContextBinding={targetType:targetInfo.targetInfo.type,contextIdPresent:!!targetInfo.targetInfo.browserContextId};
        const read=await pipe.command('Runtime.evaluate',{expression:'globalThis.__OWN_REALM_NONCE??null',contextId:defaultContext.id,returnByValue:true},session);assert.equal(read.result?.value,state.nonce);
        const frame=await pipe.command('Page.getFrameTree',{},session);assert.equal(frame.frameTree.frame.id,pageId);assert.equal(frame.frameTree.frame.url,state.url);entry.defaultContextSHA256=sha(defaultContext.uniqueId);entry.pageConfirmed=true;
        for(const [index,phase]of ['denied-initial','granted','denied-revoked'].entries()){
          await pipe.scopedPermission(phase==='granted'?'granted':'denied');fixture.phase(phase);
          assert(await until(()=>fixture.observation().steps.length===index+1||fixture.observation().result!==null,20000),'Font Access phase missing');
          if(fixture.observation().result?.error)throw Error('Font Access page operation failed');assert.equal(fixture.observation().steps.length,index+1);
          if(phase==='granted'){
            // A delegated iframe legitimately inherits A. A distinct visible
            // top-level B in this same BrowserContext must not inherit its grant.
            const foreignId=(await pipe.command('Target.createTarget',{url:'about:blank'})).targetId,foreignSession=(await pipe.command('Target.attachToTarget',{targetId:foreignId,flatten:true})).sessionId;let foreignContext=null;
            pipe.on('event',event=>{if(event.sessionId!==foreignSession)return;if(event.method==='Runtime.executionContextsCleared'||(event.method==='Runtime.executionContextDestroyed'&&event.params.executionContextId===foreignContext?.id))foreignContext=null;if(event.method==='Runtime.executionContextCreated'&&event.params.context.auxData?.isDefault===true&&event.params.context.auxData.frameId===foreignId&&event.params.context.origin===fixture.origins[1])foreignContext=event.params.context;});
            await pipe.command('Runtime.enable',{},foreignSession);await pipe.command('Page.enable',{},foreignSession);const navigation=await pipe.command('Page.navigate',{url:pipe.foreignPageURL},foreignSession);assert(!navigation.errorText);
            assert(await until(()=>fixture.observation().topForeign!==null&&foreignContext?.uniqueId&&pipe.contexts.get(foreignSession)?.has(foreignContext.id),15000),'Standalone Font Access result/default context missing');
            const foreignInfo=await pipe.command('Target.getTargetInfo',{targetId:foreignId}),tree=await pipe.command('Page.getFrameTree',{},foreignSession);
            assert.equal(foreignInfo.targetInfo.browserContextId,targetInfo.targetInfo.browserContextId);assert.equal(tree.frameTree.frame.id,foreignId);assert.equal(tree.frameTree.frame.url,pipe.foreignPageURL);assert(!tree.frameTree.frame.parentId);assert.equal(foreignContext.auxData.frameId,foreignId);
            entry.foreignTopBinding={sameBrowserContext:true,actualTopFrame:true,defaultContextObserved:true,contextSHA256:sha(foreignContext.uniqueId),ownOriginAndURL:true};
            await pipe.command('Target.activateTarget',{targetId:pageId});assert(await until(()=>fixture.observation().mainVisible===true,10000),'Primary Font Access page not restored visible');
          }
        }
        assert(await until(()=>fixture.observation().result!==null,10000),'Font Access final result missing');
        entry.rawCapture=fixture.observation().result;entry.behavior=checkFontAccess(entry.rawCapture,mode);entry.liveProcesses=inventory(app,child.pid);assert(entry.liveProcesses.some(row=>row.renderer));entry.operationsComplete=true;
      }catch(error){entry.operationFailure={kind:error.name,message:String(error.message).slice(0,2000)};throw error;}
      finally{
        if(pipe&&child?.exitCode===null){try{await pipe.scopedPermission('denied');entry.permissionCleanupDenied=true;}catch{entry.permissionCleanupDenied=false;}await pipe.command('Browser.close').catch(()=>{});}
        let captureFailure=null,log=null;
        if(capture)try{const result=await capture.finish(7000);log=result.log;const {log:unused,...closure}=result;entry.browserClosure={...closure,exitCode:child.exitCode,signal:child.signalCode};fs.writeFileSync(path.join(out,mode+'-stderr-private.log'),log,{mode:0o600,flag:'wx'});}catch(error){captureFailure=error;entry.captureFailure=error.name;}
        if(child?.pid)await until(()=>inventory(app).length===0,3000);
        if(child?.pid&&inventory(app).length){const processes=inventory(app);entry.cleanupCandidates=processes;assert(processes.every(row=>row.group===child.pid));try{process.kill(-child.pid,'SIGTERM');}catch(error){if(error.code!=='ESRCH')throw error;}await until(()=>inventory(app).length===0,5000);}
        const remaining=inventory(app).length;entry.cleanup={ownedProcessesRemaining:remaining};assert.equal(remaining,0);pipe?.close();owner=null;activeChild=null;
        entry.fixture=fixture.finish();delete entry.rawCapture;
        if(identity){const current=fs.lstatSync(root);assert(current.isDirectory()&&!current.isSymbolicLink()&&current.uid===process.getuid()&&current.ino===identity.ino&&current.dev===identity.dev);if(mode==='policy-a'&&entry.operationsComplete&&!captureFailure)entry.cleanup.ownedRootRetainedForARepeat=true;else{fs.rmSync(root,{recursive:true});roots.delete(previous?'policy-a':mode);entry.cleanup.ownedRootRemoved=true;}}
        if(captureFailure)throw captureFailure;
        if(child){assert.equal(child.exitCode,0);assert.equal(child.signalCode,null);assert.equal(entry.browserClosure.timedOut,false);assert.equal(entry.browserClosure.stderrDrainComplete,true);entry.acknowledgements=parseAcknowledgements(log.toString('utf8'),state.nonce);assert(entry.acknowledgements.some(row=>row.pid===child.pid&&row.role==='browser'));for(const process of entry.liveProcesses??[])if(process.renderer)assert(entry.acknowledgements.some(row=>row.pid===process.pid&&row.role==='renderer'),'Missing live renderer ACK');}
        if(entry.operationsComplete){assert.equal(entry.permissionCleanupDenied,true);entry.status='observed';}
      }
    }
    const a=report.sessions.find(s=>s.mode==='policy-a'),last=report.sessions.find(s=>s.mode==='policy-a-repeat');assert.notEqual(a.defaultContextSHA256,last.defaultContextSHA256);report.aba=checkFontAccessABA(a.fixture.result,last.fixture.result);report.status='observed';
  }catch(error){failure=error;if(report.status!=='resource-blocked')report.status='failed';report.privateFailure={kind:error.name,message:String(error.message).slice(0,2000)};}
  finally{
    clearTimeout(watchdog);if(activeChild?.exitCode===null&&activeChild.signalCode===null){activeChild.kill('SIGTERM');await until(()=>activeChild.exitCode!==null||activeChild.signalCode!==null,3000);}
    try{if(fixture)await fixture.close();const remaining=inventory(app).length;if(!remaining)for(const [key,value]of roots){const stat=fs.lstatSync(value.root);assert(stat.isDirectory()&&!stat.isSymbolicLink()&&stat.uid===process.getuid()&&stat.ino===value.identity.ino&&stat.dev===value.identity.dev);fs.rmSync(value.root,{recursive:true});roots.delete(key);}report.cleanup={ownedProcessesRemaining:remaining,ownedRootsRemaining:roots.size};assert.equal(remaining,0);assert.equal(roots.size,0);
      inspectFontContextRuntime(app,binding);for(const file of sources)assert.equal(sha(fs.readFileSync(file)),pins[path.relative(here,file)]);assert.equal(sha(fs.readFileSync(bindingFile)),report.bindingSHA256);report.inputsRechecked=true;
    }catch{report.status='failed';report.inputsRechecked=false;failure??=Error('OwnedCleanupOrInputChange');}
    report.completedAt=new Date().toISOString();fs.writeFileSync(path.join(out,'observations.json'),JSON.stringify(report,null,2)+'\n',{flag:'wx',mode:0o600});console.log(JSON.stringify({status:report.status,sessions:report.sessions.length,actualBrowser:report.actualBrowser,releaseQualified:false}));
  }
  if(failure)process.exitCode=1;return report;
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){assert.equal(process.argv.length,5);main(...process.argv.slice(2)).catch(()=>{console.error('Owned Font Access setup refused; no private data emitted');process.exitCode=1;});}

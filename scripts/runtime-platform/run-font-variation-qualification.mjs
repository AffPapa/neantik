// Reuse unchanged font protocols behind the explicit six-layer build/sign gate.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {inspectFontVariationRuntime,projectFontVariationBinding} from './fixtures/font-variation-runtime.mjs';
const here=path.dirname(fileURLToPath(import.meta.url)),sha=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
export async function main(kind,app,bindingFile,out){
 assert(['contexts','access'].includes(kind));assert([app,bindingFile,out].every(path.isAbsolute));
 const root=fs.lstatSync(out);assert(root.isDirectory()&&!root.isSymbolicLink()&&root.uid===process.getuid()&&(root.mode&0o077)===0&&fs.readdirSync(out).length===0);assert.equal(fs.realpathSync(out),out);
 const bytes=fs.readFileSync(bindingFile),binding=JSON.parse(bytes),runtime=inspectFontVariationRuntime(app,binding);
 const runner=kind==='contexts'?'run-font-contexts.mjs':'run-font-access.mjs';
 const sources=[fileURLToPath(import.meta.url),...['fixtures/font-variation-runtime.mjs','fixtures/font-context-runtime.mjs','fixtures/font-runtime-closure.mjs',runner].map(name=>path.join(here,name))];
 const pins=Object.fromEntries(sources.map(file=>[path.relative(here,file),sha(fs.readFileSync(file))]));
 const projected=projectFontVariationBinding(binding),projection=path.join(out,'validated-five-layer-projection.private.json'),nested=path.join(out,'capture');
 fs.writeFileSync(projection,JSON.stringify(projected,null,2)+'\n',{flag:'wx',mode:0o600});fs.mkdirSync(nested,{mode:0o700});
 const report={schemaVersion:1,status:'incomplete',kind,scope:'six-layer source/build/sign proof plus unchanged bounded font protocol;not release qualification',bindingSHA256:sha(bytes),fontVariationProof:binding.fontVariationProof,projectionSHA256:sha(fs.readFileSync(projection)),runtime,sources:pins,releaseQualified:false,startedAt:new Date().toISOString()};
 let failure=null;
 try{
  const selected=await import('./'+runner),capture=await selected.main(app,projection,nested);
  report.captureSHA256=sha(fs.readFileSync(path.join(nested,'observations.json')));report.captureStatus=capture.status;
  assert.equal(capture.status,'observed');assert.equal(capture.inputsRechecked,true);assert.deepEqual(capture.cleanup,{ownedProcessesRemaining:0,ownedRootsRemaining:0});
  report.status='observed';report.actualBrowser=capture.actualBrowser;report.sessions=capture.sessions.length;
 }catch(error){failure=error;report.status='failed';report.failure={kind:error.name,message:String(error.message).slice(0,300)};}
 finally{
  try{
   inspectFontVariationRuntime(app,binding);assert.equal(sha(fs.readFileSync(bindingFile)),report.bindingSHA256);assert.equal(sha(fs.readFileSync(projection)),report.projectionSHA256);
   for(const file of sources)assert.equal(sha(fs.readFileSync(file)),pins[path.relative(here,file)]);
   report.inputsRechecked=true;
  }catch(error){report.inputsRechecked=false;report.status='failed';failure??=error;}
  report.completedAt=new Date().toISOString();fs.writeFileSync(path.join(out,'qualification.json'),JSON.stringify(report,null,2)+'\n',{flag:'wx',mode:0o600});
 }
 console.log(JSON.stringify({status:report.status,kind,inputsRechecked:report.inputsRechecked,actualBrowser:report.actualBrowser??false,sessions:report.sessions??0,releaseQualified:false}));
 if(failure)process.exitCode=1;return report;
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 assert.equal(process.argv.length,6,'Usage: node run-font-variation-qualification.mjs contexts|access OWN_SIGNED_RUNTIME SIX_LAYER_BINDING FRESH_PRIVATE_OUTPUT');
 main(...process.argv.slice(2)).catch(()=>{console.error('Six-layer font qualification setup refused; no private data emitted');process.exitCode=1;});
}

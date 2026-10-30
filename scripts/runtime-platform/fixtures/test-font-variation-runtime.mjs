// Model controls for lineage only; no native runtime claim from these tests.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import {test} from 'node:test';
import {coreFontBinding} from './font-context-runtime.mjs';
import {variationContracts,projectFontVariationBinding} from './font-variation-runtime.mjs';
const sha=value=>crypto.createHash('sha256').update(value).digest('hex');
function fixture(){
 const files=new Map(),sourceInputContracts={},folded={};
 for(const name of variationContracts){const bytes=fs.readFileSync(new URL('../../../runtime/font-policy-v1/'+name,import.meta.url)),m=JSON.parse(bytes);files.set(name,bytes);sourceInputContracts[name]=sha(bytes);files.set(m.patchFile,fs.readFileSync(new URL('../../../runtime/font-policy-v1/'+m.patchFile,import.meta.url)));for(const f of m.files)folded[f.path]=f.postimageSHA256;}
 files.set('system_font_source_variations.cc',fs.readFileSync(new URL('../../../runtime/font-policy-v1/system_font_source_variations.cc',import.meta.url)));
 const version='156.0.8078.12',exe='Contents/MacOS/NeAntik Browser',framework=`Contents/Frameworks/NeAntik Browser Framework.framework/Versions/${version}/NeAntik Browser Framework`;
 const codeClosure={[exe]:'a'.repeat(64),[framework]:'b'.repeat(64)},runtimeTranscript={fixture:'model-only'};
 const build={status:'linked-browser;unqualified',exitCode:0,target:'chrome',jobs:2,argsSHA256:'c'.repeat(64),sourceContracts:sourceInputContracts,sourcePostimages:folded,sourcePostimagesUnchanged:true,contractsUnchanged:true,oldRuntimeObjectsArgsAndSignedClosureUnchanged:true,output:'/owned/out/QA',runtimeBefore:{[framework]:'d'.repeat(64)},runtimeSHA256:{[exe]:'e'.repeat(64),[framework]:'f'.repeat(64)}};
 const sign={status:'signed-research-only',exitCode:0,signerIdentity:'474F7C78F33EE324C24F6F5AE0443EB713E85E60',input:'/owned/out/QA/NeAntik Browser.app',rawInputUnchanged:true,inputRawRuntimeSHA256:build.runtimeSHA256,outputSignedCodeClosure:codeClosure,outputRuntimeTranscript:runtimeTranscript,version};
 const binding={version,sourceInputContracts,executableSHA256:codeClosure[exe],frameworkSHA256:codeClosure[framework],codeClosure,runtimeTranscript,fontVariationProof:{kind:'source-build-sign-variation-v1',build:{path:'/owned/proof/font-variation-browser-build1.json'},signing:{path:'/owned/proof/font-runtime-sign4.json'}}};
 function repin(){const buildBytes=Buffer.from(JSON.stringify(build));binding.fontVariationProof.build.sha256=sha(buildBytes);sign.buildReceiptSHA256=sha(buildBytes);const signBytes=Buffer.from(JSON.stringify(sign));binding.fontVariationProof.signing.sha256=sha(signBytes);return new Map([[binding.fontVariationProof.build.path,buildBytes],[binding.fontVariationProof.signing.path,signBytes]]);}
 const receipts=repin();const readers={contractReader:name=>files.get(name),receiptReader:reference=>receipts.get(reference.path)};
 return {files,binding,build,sign,receipts,readers,repin,framework,exe};
}
test('exact six-layer build/sign projection keeps all binary pins and old five API frozen',()=>{
 const f=fixture(),before=structuredClone(f.binding),result=projectFontVariationBinding(f.binding,f.readers);
 assert.equal(Object.keys(result.sourceInputContracts).length,5);assert.deepEqual(result.codeClosure,before.codeClosure);assert.deepEqual(result.runtimeTranscript,before.runtimeTranscript);assert.deepEqual(result.fontVariationProof,before.fontVariationProof);assert.deepEqual(f.binding,before);
 assert.equal(Object.keys(coreFontBinding(result).sourceInputContracts).length,4);assert.throws(()=>coreFontBinding(f.binding));
});
test('missing, extra, wrong parent, patch, preimage or source variant refuses',()=>{
 for(const change of [f=>delete f.binding.sourceInputContracts[variationContracts[5]],f=>f.binding.sourceInputContracts.extra='0'.repeat(64),f=>f.binding.sourceInputContracts[variationContracts[4]]='0'.repeat(64),f=>f.files.set('chromium-font-variations.patch',Buffer.from('wrong')),f=>f.files.set('system_font_source_variations.cc',Buffer.from('wrong'))]){const f=fixture();change(f);assert.throws(()=>projectFontVariationBinding(f.binding,f.readers));}
 for(const mutate of [m=>m.parentManifest='wrong.json',m=>m.parentManifestSHA256='0'.repeat(64),m=>m.files[0].preimageSHA256='0'.repeat(64),m=>m.files[0].path='wrong.cc']){
  const f=fixture(),name=variationContracts[5],m=JSON.parse(f.files.get(name));mutate(m);const bytes=Buffer.from(JSON.stringify(m));f.files.set(name,bytes);f.binding.sourceInputContracts[name]=sha(bytes);assert.throws(()=>projectFontVariationBinding(f.binding,f.readers));
 }
});
test('old binary relabel, cross-build sign, failed build and changed receipts refuse',()=>{
 for(const mutate of [f=>f.binding.frameworkSHA256='1'.repeat(64),f=>f.binding.codeClosure[f.framework]='1'.repeat(64),f=>f.binding.runtimeTranscript={old:'runtime'},f=>f.binding.fontVariationProof.build.sha256='0'.repeat(64)]){const f=fixture();mutate(f);assert.throws(()=>projectFontVariationBinding(f.binding,f.readers));}
 for(const mutate of [f=>f.build.runtimeBefore[f.framework]=f.build.runtimeSHA256[f.framework],f=>f.build.sourcePostimages['components/ungoogled/system_font_source.cc']='0'.repeat(64),f=>f.build.exitCode=1,f=>f.build.sourcePostimagesUnchanged=false,f=>f.sign.inputRawRuntimeSHA256={old:'runtime'},f=>f.sign.signerIdentity='0'.repeat(40),f=>f.sign.rawInputUnchanged=false]){
  const f=fixture();mutate(f);const refreshed=f.repin();f.readers.receiptReader=reference=>refreshed.get(reference.path);assert.throws(()=>projectFontVariationBinding(f.binding,f.readers));
 }
});

// Explicit six-layer successor. Historical five-layer fixtures stay frozen.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {coreFontBinding,inspectFontContextRuntime} from './font-context-runtime.mjs';
export const variationContracts=Object.freeze(['chromium-host-font-policy.json','chromium-font-witness.json','chromium-font-cleanup.json','chromium-font-cleanup-cstring.json','chromium-font-generic-defaults.json','chromium-font-variations.json']);
const directory=new URL('../../../runtime/font-policy-v1/',import.meta.url);
const sha=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
const hash=value=>typeof value==='string'&&/^[a-f0-9]{64}$/.test(value);
const signer='474F7C78F33EE324C24F6F5AE0443EB713E85E60';
function privateReceipt(reference,role) {
  assert(reference&&hash(reference.sha256)&&path.isAbsolute(reference.path),'Pinned private receipt required');
  const parent=path.dirname(reference.path),name=path.basename(reference.path);
  assert((role==='build'?/^font-variation-browser-build[1-9][0-9]*\.json$/:/^font-runtime-sign[1-9][0-9]*\.json$/).test(name),'Unexpected receipt role');
  assert.equal(fs.realpathSync(parent),parent);const root=fs.lstatSync(parent);
  assert(root.isDirectory()&&!root.isSymbolicLink()&&root.uid===process.getuid()&&(root.mode&0o077)===0,'Owned private receipt directory required');
  const before=fs.lstatSync(reference.path);assert(before.isFile()&&!before.isSymbolicLink()&&before.uid===process.getuid()&&before.nlink===1&&(before.mode&0o077)===0&&before.size<262144);
  const fd=fs.openSync(reference.path,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);
  try {
    const opened=fs.fstatSync(fd);assert(opened.ino===before.ino&&opened.dev===before.dev&&opened.size===before.size);
    const bytes=fs.readFileSync(fd);assert.equal(sha(bytes),reference.sha256,'Receipt content drift');return bytes;
  }finally{fs.closeSync(fd);}
}
// Pure lineage/receipt checks have explicit readers for deterministic controls.
// The actual inspector below always uses the real private-file reader.
export function projectFontVariationBinding(binding,{contractReader=name=>fs.readFileSync(new URL(name,directory)),receiptReader=privateReceipt}={}) {
  assert.deepEqual(Object.keys(binding.sourceInputContracts??{}).sort(),[...variationContracts].sort(),'Six explicit font source contracts required');
  const folded={};let layer=null;
  for(const [index,name]of variationContracts.entries()) {
    const bytes=contractReader(name),manifest=JSON.parse(bytes);assert.equal(sha(bytes),binding.sourceInputContracts[name],'Font contract drift');
    assert(/^[a-z0-9-]+\.patch$/.test(manifest.patchFile));assert.equal(sha(contractReader(manifest.patchFile)),manifest.patchSHA256,'Font patch drift');
    if(index){assert.equal(manifest.parentManifest,variationContracts[index-1]);assert.equal(manifest.parentManifestSHA256,binding.sourceInputContracts[variationContracts[index-1]]);}
    assert(Array.isArray(manifest.files));
    for(const file of manifest.files){assert(hash(file.postimageSHA256));if(index===5)assert.equal(file.preimageSHA256,folded[file.path],'Variation preimage gap');folded[file.path]=file.postimageSHA256;}
    if(index===5)layer=manifest;
  }
  assert.equal(layer.patchFile,'chromium-font-variations.patch');assert.equal(layer.files.length,1);assert.equal(layer.files[0].path,'components/ungoogled/system_font_source.cc');
  assert.deepEqual(Object.keys(layer.ownedInputs),['system_font_source_variations.cc']);assert.equal(sha(contractReader('system_font_source_variations.cc')),layer.ownedInputs['system_font_source_variations.cc']);
  assert.equal(layer.ownedInputs['system_font_source_variations.cc'],layer.files[0].postimageSHA256);
  const proof=binding.fontVariationProof;assert.equal(proof?.kind,'source-build-sign-variation-v1');
  assert.equal(path.dirname(proof.build.path),path.dirname(proof.signing.path),'Build/sign evidence must share its owned directory');
  const buildBytes=receiptReader(proof.build,'build'),signBytes=receiptReader(proof.signing,'signing');
  assert.equal(sha(buildBytes),proof.build.sha256);assert.equal(sha(signBytes),proof.signing.sha256);
  const build=JSON.parse(buildBytes),sign=JSON.parse(signBytes);
  assert.equal(build.status,'linked-browser;unqualified');assert.equal(build.exitCode,0);assert.equal(build.target,'chrome');assert.equal(build.jobs,2);assert(hash(build.argsSHA256));
  for(const key of ['sourcePostimagesUnchanged','contractsUnchanged','oldRuntimeObjectsArgsAndSignedClosureUnchanged'])assert.equal(build[key],true);
  assert.deepEqual(build.sourceContracts,binding.sourceInputContracts);assert.deepEqual(build.sourcePostimages,folded);
  const exe='Contents/MacOS/NeAntik Browser',framework=`Contents/Frameworks/NeAntik Browser Framework.framework/Versions/${binding.version}/NeAntik Browser Framework`;
  assert(hash(build.runtimeSHA256?.[exe])&&hash(build.runtimeSHA256?.[framework]));assert(hash(build.runtimeBefore?.[framework]));assert.notEqual(build.runtimeBefore[framework],build.runtimeSHA256[framework],'Unchanged old runtime cannot prove a new policy build');
  assert.equal(sign.status,'signed-research-only');assert.equal(sign.exitCode,0);assert.equal(sign.signerIdentity,signer);assert.equal(sign.buildReceiptSHA256,proof.build.sha256);assert.equal(sign.input,path.join(build.output,'NeAntik Browser.app'));
  assert.equal(sign.rawInputUnchanged,true);assert.deepEqual(sign.inputRawRuntimeSHA256,build.runtimeSHA256);assert.deepEqual(sign.outputSignedCodeClosure,binding.codeClosure);assert.deepEqual(sign.outputRuntimeTranscript,binding.runtimeTranscript);
  assert.equal(sign.outputSignedCodeClosure[exe],binding.executableSHA256);assert.equal(sign.outputSignedCodeClosure[framework],binding.frameworkSHA256);assert.equal(sign.version,binding.version);
  const projected={...binding,sourceInputContracts:Object.fromEntries(variationContracts.slice(0,-1).map(name=>[name,binding.sourceInputContracts[name]]))};
  // Preserve the existing exact-five-to-four validator and every binary pin.
  coreFontBinding(projected);return projected;
}
export function inspectFontVariationRuntime(app,binding) {
  const projected=projectFontVariationBinding(binding);
  const sign=JSON.parse(privateReceipt(binding.fontVariationProof.signing,'signing'));assert.equal(sign.app,app,'Signed receipt belongs to another bundle');
  return inspectFontContextRuntime(app,projected);
}

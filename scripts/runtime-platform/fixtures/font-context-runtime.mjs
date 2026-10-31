// Keep the old four-contract validator intact; explicitly layer its successor.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import {inspectRuntime} from '../run-font-policy.mjs';
const names=['chromium-host-font-policy.json','chromium-font-witness.json','chromium-font-cleanup.json','chromium-font-cleanup-cstring.json','chromium-font-generic-defaults.json'];
const sha=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
export function coreFontBinding(binding) {
  assert.deepEqual(Object.keys(binding.sourceInputContracts??{}).sort(),[...names].sort(),'Five explicit font source contracts required');
  const directory=new URL('../../../runtime/font-policy-v1/',import.meta.url),manifestURL=new URL(names.at(-1),directory),bytes=fs.readFileSync(manifestURL),manifest=JSON.parse(bytes);
  assert.equal(binding.sourceInputContracts[names.at(-1)],sha(bytes),'Generic-font source lineage drift');
  assert.equal(manifest.parentManifest,names.at(-2));assert.equal(manifest.parentManifestSHA256,binding.sourceInputContracts[names.at(-2)]);
  assert.equal(manifest.patchFile,'chromium-font-generic-defaults.patch');assert.equal(sha(fs.readFileSync(new URL(manifest.patchFile,directory))),manifest.patchSHA256);
  return {...binding,sourceInputContracts:Object.fromEntries(names.slice(0,-1).map(name=>[name,binding.sourceInputContracts[name]]))};
}
export function inspectFontContextRuntime(app,binding) {
  // Binary/resource/signature/whole-tree checks remain the existing algorithm.
  // The extra contract is validated above, never silently dropped or inferred.
  return inspectRuntime(app,coreFontBinding(binding));
}

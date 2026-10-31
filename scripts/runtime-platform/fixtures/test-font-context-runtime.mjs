import assert from 'node:assert/strict';
import {test} from 'node:test';
import fs from 'node:fs';
import crypto from 'node:crypto';
import {coreFontBinding} from './font-context-runtime.mjs';
test('explicit fifth lineage is required; core validator projection preserves every binary pin',()=>{
 const names=['chromium-host-font-policy.json','chromium-font-witness.json','chromium-font-cleanup.json','chromium-font-cleanup-cstring.json','chromium-font-generic-defaults.json'];
 const sourceInputContracts=Object.fromEntries(names.map(name=>[name,crypto.createHash('sha256').update(fs.readFileSync(new URL('../../../runtime/font-policy-v1/'+name,import.meta.url))).digest('hex')]));
 const binding={sourceInputContracts,executableSHA256:'a'.repeat(64),frameworkSHA256:'b'.repeat(64),codeClosure:{own:'c'.repeat(64)}};
 const core=coreFontBinding(binding);assert.equal(Object.keys(core.sourceInputContracts).length,4);assert.equal(core.frameworkSHA256,binding.frameworkSHA256);assert.deepEqual(core.codeClosure,binding.codeClosure);assert.equal(Object.keys(binding.sourceInputContracts).length,5);
 for(const mutate of [v=>delete v.sourceInputContracts[names[4]],v=>v.sourceInputContracts[names[4]]='0'.repeat(64),v=>v.sourceInputContracts[names[3]]='0'.repeat(64)]){const v=structuredClone(binding);mutate(v);assert.throws(()=>coreFontBinding(v));}
});

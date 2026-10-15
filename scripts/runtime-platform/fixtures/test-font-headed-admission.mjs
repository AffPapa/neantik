// Filesystem/model tests only; no resource observer or native process executes.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {test} from 'node:test';
import {assessFontAdmission,consumeFontWarningPhase} from './font-headed-admission.mjs';
const pins={bindingSHA256:'a'.repeat(64),controllerSHA256:'b'.repeat(64)},now=1000000;
const warning={eligibleForAttempt:false,memoryPressure:2,thermalState:0,reasons:['memory_pressure_warning']};
function owned(fn) {
 const root=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'neantik-font-admission.')));fs.chmodSync(root,0o700);const file=path.join(root,'approval.json');
 const record={schemaVersion:1,scope:'font-five-headed-v1',userConfirmed:true,...pins,replyReference:'synthetic model fixture, not actual user approval',expiresAt:now+600000};
 fs.writeFileSync(file,JSON.stringify(record),{mode:0o600});try {fn({file,record});}finally{fs.rmSync(root,{recursive:true});}
}
test('warning is refused by default; one exact phase can be consumed only once and expires',()=>owned(({file})=>{
 assert.equal(assessFontAdmission(75,warning).allowed,false);assert.equal(assessFontAdmission(75,warning,{expiresAt:now+1},now).allowed,false);
 const phase=consumeFontWarningPhase(file,pins,now);assert.equal(assessFontAdmission(75,warning,phase,now).basis,'explicit-one-shot-warning-exception');
 assert.throws(()=>consumeFontWarningPhase(file,pins,now));assert.equal(assessFontAdmission(75,warning,phase,now+300000).allowed,false);
}));
test('approval never admits critical, unknown, thermal problems or contradictory observations',()=>owned(({file})=>{
 const phase=consumeFontWarningPhase(file,pins,now);
 for(const gate of [null,{...warning,memoryPressure:4},{...warning,memoryPressure:null},{...warning,thermalState:2},{...warning,thermalState:null},{...warning,reasons:['memory_pressure_warning','thermal_serious']},{...warning,eligibleForAttempt:true}])assert.equal(assessFontAdmission(75,gate,phase,now).allowed,false);
 assert.equal(assessFontAdmission(78,warning,phase,now).allowed,false);
 const normal={eligibleForAttempt:true,memoryPressure:1,thermalState:0,reasons:[]};assert.equal(assessFontAdmission(0,normal).basis,'normal-resources');assert.equal(assessFontAdmission(75,normal).allowed,false);
}));
test('wrong runtime/controller, expiry, missing confirmation and unsafe permissions refuse',()=>{
 for(const change of [r=>r.bindingSHA256='c'.repeat(64),r=>r.controllerSHA256='d'.repeat(64),r=>r.expiresAt=now,r=>r.expiresAt=now+900001,r=>r.userConfirmed=false,r=>r.scope='other'])owned(({file,record})=>{change(record);fs.writeFileSync(file,JSON.stringify(record));assert.throws(()=>consumeFontWarningPhase(file,pins,now));assert.equal(fs.existsSync(file+'.consumed'),false);});
 owned(({file})=>{fs.chmodSync(file,0o644);assert.throws(()=>consumeFontWarningPhase(file,pins,now));});
});

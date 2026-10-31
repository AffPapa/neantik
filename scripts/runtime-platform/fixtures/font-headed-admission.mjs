// Explicit, one-shot research exception. Never used by manager admission.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
const phases=new WeakSet();
export function consumeFontWarningPhase(file,{bindingSHA256,controllerSHA256},now=Date.now()) {
  assert(path.isAbsolute(file)&&fs.realpathSync(file)===file);
  const parent=fs.lstatSync(path.dirname(file)),entry=fs.lstatSync(file);
  assert(parent.isDirectory()&&!parent.isSymbolicLink()&&parent.uid===process.getuid()&&(parent.mode&0o077)===0);
  assert(entry.isFile()&&!entry.isSymbolicLink()&&entry.uid===process.getuid()&&entry.nlink===1&&(entry.mode&0o777)===0o600&&entry.size<=4096);
  const fd=fs.openSync(file,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);let record;
  try {const actual=fs.fstatSync(fd);assert(actual.ino===entry.ino&&actual.dev===entry.dev&&actual.size===entry.size);record=JSON.parse(fs.readFileSync(fd,'utf8'));}
  finally {fs.closeSync(fd);}
  assert.equal(record.schemaVersion,1);assert.equal(record.scope,'font-five-headed-v1');assert.equal(record.userConfirmed,true);
  assert.equal(record.bindingSHA256,bindingSHA256);assert.equal(record.controllerSHA256,controllerSHA256);
  assert(typeof record.replyReference==='string'&&record.replyReference.length>0&&record.replyReference.length<=200);
  assert(Number.isSafeInteger(record.expiresAt)&&record.expiresAt>now&&record.expiresAt<=now+900000,'Expired or unbounded warning approval');
  // A second invocation with another output cannot reuse the same permission.
  fs.writeFileSync(file+'.consumed',JSON.stringify({scope:record.scope,bindingSHA256,controllerSHA256,processPID:process.pid,consumedAt:now})+'\n',{mode:0o600,flag:'wx'});
  const phase=Object.freeze({scope:record.scope,expiresAt:Math.min(record.expiresAt,now+300000)});phases.add(phase);return phase;
}
export function assessFontAdmission(exitCode,gate,phase=null,now=Date.now()) {
  const thermalOkay=gate?.thermalState===0||gate?.thermalState===1;
  const normal=exitCode===0&&gate?.eligibleForAttempt===true&&gate.memoryPressure===1&&thermalOkay&&Array.isArray(gate.reasons)&&gate.reasons.length===0;
  const warning=exitCode===75&&gate?.eligibleForAttempt===false&&gate.memoryPressure===2&&thermalOkay&&Array.isArray(gate.reasons)&&gate.reasons.length===1&&gate.reasons[0]==='memory_pressure_warning';
  const exception=warning&&phase!==null&&phases.has(phase)&&now<phase.expiresAt;
  return {allowed:normal||exception,basis:normal?'normal-resources':exception?'explicit-one-shot-warning-exception':'resource-refusal'};
}

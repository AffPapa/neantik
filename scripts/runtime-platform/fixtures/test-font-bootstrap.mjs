// Analyzer sensitivity only. No actual browser, registration or Keychain.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {spawn} from 'node:child_process';
import {bootstrapCases,validateBootstrapExit,monitorBootstrapChild} from '../run-font-bootstrap.mjs';
test('finite bootstrap declaration and exact early-refusal control',()=>{
 assert.equal(bootstrapCases.length,9);assert.equal(new Set(bootstrapCases).size,9);
 const positive={exitCode:13,signal:null,timedOut:false,nativeACKs:0,profileEntries:0,crashEntries:0,ownedProcessesRemaining:0,stderrDrainComplete:true};
 validateBootstrapExit(positive);
 for(const mutation of [{exitCode:0},{exitCode:78},{exitCode:null,signal:'SIGTRAP'},{timedOut:true},{nativeACKs:1},{profileEntries:1},{crashEntries:1},{ownedProcessesRemaining:1},{stderrDrainComplete:false}])assert.throws(()=>validateBootstrapExit({...positive,...mutation}));
});
test('final owned stderr bytes are drained before the refusal result is inspected',async()=>{
 const text='owned-control\n'.repeat(3000)+'NEANTIK_FONT_QA_V1 synthetic-tail\n';
 const child=spawn(process.execPath,['-e','process.stderr.write('+JSON.stringify(text)+',()=>{process.exitCode=13;});'],{stdio:['ignore','ignore','pipe'],env:{}});
 const result=await monitorBootstrapChild(child).finish();
 assert.equal(child.exitCode,13);assert.equal(result.stderrDrainComplete,true);
 assert.equal(result.log.toString('utf8'),text);assert.equal(result.stderrBytes,Buffer.byteLength(text));
 assert.throws(()=>validateBootstrapExit({exitCode:13,signal:null,timedOut:false,nativeACKs:1,profileEntries:0,crashEntries:0,ownedProcessesRemaining:0,stderrDrainComplete:true}));
});

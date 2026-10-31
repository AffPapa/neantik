import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {test} from 'node:test';
import {measureMachOClosure,verifyMachOClosure} from './font-runtime-closure.mjs';
test('closure inventory catches missing, additional, changed and aliased executable inputs',()=>{
 const root=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'neantik-font-closure.')));const contents=path.join(root,'Contents');fs.mkdirSync(contents);
 const code=path.join(contents,'own-code');fs.writeFileSync(code,Buffer.from('cffaedfe00000000','hex'));fs.writeFileSync(path.join(contents,'resource'),'owned fixture');
 try {
  const expected=measureMachOClosure(root);assert.deepEqual(Object.keys(expected),['Contents/own-code']);verifyMachOClosure(root,expected);
  assert.throws(()=>verifyMachOClosure(root,{}));
  fs.writeFileSync(path.join(contents,'extra-code'),Buffer.from('cafebabe00000000','hex'));assert.throws(()=>verifyMachOClosure(root,expected));fs.unlinkSync(path.join(contents,'extra-code'));
  fs.appendFileSync(code,'changed');assert.throws(()=>verifyMachOClosure(root,expected));
  fs.linkSync(code,path.join(contents,'hardlink'));assert.throws(()=>measureMachOClosure(root));fs.unlinkSync(path.join(contents,'hardlink'));
  fs.symlinkSync(root,path.join(contents,'escape'));assert.throws(()=>measureMachOClosure(root));fs.unlinkSync(path.join(contents,'escape'));
  fs.symlinkSync('own-code',path.join(contents,'owned-alias'));assert.equal(Object.keys(measureMachOClosure(root)).length,1);
 }finally{fs.rmSync(root,{recursive:true});}
});

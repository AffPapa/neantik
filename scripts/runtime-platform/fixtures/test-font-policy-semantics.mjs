// Deliberately synthetic behavior controls; these do not certify a runtime.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {checkFontSession,checkFontABA} from './font-policy-semantics.mjs';
function fixture(policy=false) {
 const nonce='a'.repeat(32),rows=[];
 function add(family,fallback,style,text) {
  const fallbackFace=family.startsWith('NeAntikMissing_')||(policy&&['NeAntikFontPolicyCanary','QALocalUnique'].includes(family));
  const width=family==='QARemoteAhem'?100:fallbackFace?(fallback==='serif'?61:60):family==='Helvetica'&&policy?55:73;
  const mask=(family==='QARemoteAhem'?'e':fallbackFace?(fallback==='serif'?'f':'a'):family==='Helvetica'&&policy?'b':'c').repeat(64);
  const capture={widths:[width,width,width],domWidths:[width,width,width],maskSHA256:mask,inkPixels:width,wordBoundary:text.includes(' ')?{canvasPieces:Array(7).fill(width/7),domPieces:Array(7).fill(width/7)}:null};
  rows.push({family,fallback,style,text,...capture,matched:{...structuredClone(capture),typography:{fontKerning:'none',textRendering:'optimizeSpeed',letterSpacing:'0px',wordSpacing:'0px'},domTypography:{fontKerning:'none',fontVariantLigatures:'none',textRendering:'optimizeSpeed',letterSpacing:'0px',wordSpacing:'0px'}}});
 }
 for(const family of ['NeAntikFontPolicyCanary','Helvetica',`NeAntikMissing_${nonce}`])for(const fallback of ['monospace','serif'])for(const style of ['normal 400','normal 700','italic 400'])for(const text of ['ABABA','A B A B'])add(family,fallback,style,text);
 for(const family of ['QALocalUnique','QARemoteCanary','QARemoteAhem'])for(const fallback of ['monospace','serif'])add(family,fallback,'normal 400','ABABA');
 const page={realm:'page',local:[{kind:'known-own-unique',loaded:!policy,error:policy?'NetworkError':null},{kind:'invented-missing',loaded:false,error:'NetworkError'}],measurements:rows};
 const worker=structuredClone(page);worker.realm='worker';worker.measurements.forEach(row=>{for(const value of [row,row.matched]){value.domWidths=null;delete value.domTypography;if(value.wordBoundary)value.wordBoundary.domPieces=null;}});
 return {nonce,realms:[page,worker]};
}
test('native positive controls and configured fallback controls satisfy behavior gates',()=>{
 for(const mode of ['native','seeded-native','policy-a','policy-b','policy-a-repeat'])assert.equal(checkFontSession(fixture(mode.startsWith('policy-')),mode).status,'passed');
 const a=fixture(true);assert.equal(checkFontABA(a,structuredClone(a)).status,'passed');
});
test('semantic negatives catch leakage, broken draw, instability, realm disagreement and false refusals',()=>{
 const mutations=[
  v=>v.realms[0].local[0].loaded=true,
  v=>v.realms[0].local[1].error='SyntaxError',
  v=>v.realms[0].measurements[0].widths[1]+=1,
  v=>v.realms[0].measurements[0].domWidths[1]+=1,
  v=>v.realms[0].measurements[0].domWidths=v.realms[0].measurements[0].domWidths.map(x=>x+1),
  v=>v.realms[0].measurements.find(x=>x.family==='QARemoteCanary').widths=[60,60,60],
  v=>v.realms[0].measurements.find(x=>x.family==='QARemoteAhem').widths=[73,73,73],
  v=>v.realms[0].measurements[0].maskSHA256='d'.repeat(64),
  v=>v.realms[0].measurements.find(x=>x.family==='Helvetica').maskSHA256='c'.repeat(64),
  v=>{const r=v.realms[0].measurements.find(x=>x.family==='Helvetica');r.widths=[73,73,73];r.domWidths=[73,73,73];r.maskSHA256='c'.repeat(64);r.inkPixels=73;},
  v=>{const r=v.realms[1].measurements.find(x=>x.family==='Helvetica');r.maskSHA256='d'.repeat(64);},
 ];
 // Changing only a mask to an unrelated non-canary mask remains valid locally,
 // but must be caught by the independent page/worker comparison.
 for(const mutate of mutations){const v=fixture(true);mutate(v);assert.throws(()=>checkFontSession(v,'policy-a'));}
 const native=fixture(false);native.realms[0].measurements[0].widths=[60,60,60];assert.throws(()=>checkFontSession(native,'native'));
});
test('A to B to A rejects changed identity, pixels or DOM metrics',()=>{
 const a=fixture(true);
 for(const mutate of [v=>v.nonce='b'.repeat(32),v=>v.realms[0].measurements[0].maskSHA256='d'.repeat(64),v=>v.realms[0].measurements[0].domWidths[0]+=1]) {
  const v=structuredClone(a);mutate(v);assert.throws(()=>checkFontABA(a,v));
 }
 for(const mutate of [v=>v.realms=[],v=>v.realms.pop(),v=>v.realms[1]=structuredClone(v.realms[0]),v=>v.realms[0].measurements.pop(),v=>v.realms[0].measurements[1]=structuredClone(v.realms[0].measurements[0])]) {
  const v=fixture(true);mutate(v);assert.throws(()=>checkFontABA(v,structuredClone(v)));assert.throws(()=>checkFontSession(v,'policy-a'));
 }
});
test('default multiword differences remain observations; matched typography mismatch still fails tightly',()=>{
 const v=fixture(true),row=v.realms[0].measurements.find(row=>row.text==='A B A B');
 row.matched.domTypography.letterSpacing='normal';row.matched.domTypography.textRendering='optimizespeed';
 row.domWidths=row.domWidths.map(x=>x-3);
 assert.equal(checkFontSession(v,'policy-a').defaultMultiwordDifferences,1);
 // No tolerance widening: less than a tenth of a pixel is still detected.
 row.matched.domWidths=row.matched.domWidths.map(x=>x+0.09);
 assert.throws(()=>checkFontSession(v,'policy-a'),/controlled typography/);
});
test('missing matched data, ignored settings and missing boundary observations cannot pass',()=>{
 for(const mutate of [
  v=>delete v.realms[0].measurements[0].matched,
  v=>v.realms[1].measurements[0].matched.typography.fontKerning='auto',
  v=>v.realms[0].measurements[0].matched.domTypography.fontVariantLigatures='normal',
  v=>v.realms[0].measurements[0].matched.domTypography.letterSpacing='1px',
  v=>v.realms[0].measurements[0].matched.domTypography.textRendering='auto',
  v=>v.realms[0].measurements.find(row=>row.text.includes(' ')).wordBoundary.domPieces=[],
  v=>v.realms[1].measurements[0].matched.widths[1]+=1,
  v=>v.realms[0].measurements[0].matched.maskSHA256='d'.repeat(64),
 ]){const v=fixture(true);mutate(v);assert.throws(()=>checkFontSession(v,'policy-a'));}
 const a=fixture(true),changed=structuredClone(a);changed.realms[1].measurements[0].matched.maskSHA256='d'.repeat(64);
 assert.throws(()=>checkFontABA(a,changed));
});
test('Helvetica collision leakage in either typography cannot hide behind the other',()=>{
 for(const variant of ['default','matched']) {
  const v=fixture(true);
  for(const realm of v.realms)for(const fallback of ['monospace','serif']) {
   const family=realm.measurements.find(row=>row.family==='Helvetica'&&row.fallback===fallback),downloaded=realm.measurements.find(row=>row.family==='QARemoteCanary'&&row.fallback===fallback);
   if(variant==='matched')family.matched=structuredClone(downloaded.matched);
   else for(const field of ['widths','domWidths','inkPixels','maskSHA256'])family[field]=structuredClone(downloaded[field]);
  }
  assert.throws(()=>checkFontSession(v,'policy-a'),/family-collision/);
  assert.throws(()=>checkFontABA(v,structuredClone(v)),/family-collision/);
 }
});

// Behavior gates for the owned font fixture. Metrics alone never prove origin.
import assert from 'node:assert/strict';
const close=(a,b)=>Math.abs(a-b)<=0.08;
const key=row=>JSON.stringify([row.family,row.fallback,row.style,row.text]);
const lookup=(realm,family,fallback,style='normal 400',text='ABABA')=>{
  const row=realm.measurements.find(row=>row.family===family&&row.fallback===fallback&&row.style===style&&row.text===text);
  assert(row,'Missing font operation');return row;
};
const drawEqual=(a,b)=>close(a.widths[0],b.widths[0])&&a.inkPixels===b.inkPixels&&a.maskSHA256===b.maskSHA256;
const sameDraw=(a,b)=>drawEqual(a,b)&&drawEqual(a.matched,b.matched);
export function validateFontMeasurement(row,realm) {
  for(const value of [row,row.matched]) {
    assert(value&&Array.isArray(value.widths)&&value.widths.length===3&&value.widths.every(x=>Number.isFinite(x)&&x>0));
    assert(/^[a-f0-9]{64}$/.test(value.maskSHA256)&&Number.isSafeInteger(value.inkPixels)&&value.inkPixels>0&&value.inkPixels<=17920);
    if(realm==='page')assert(Array.isArray(value.domWidths)&&value.domWidths.length===3&&value.domWidths.every(x=>Number.isFinite(x)&&x>0));
    else assert.equal(value.domWidths,null);
    if(row.text.includes(' ')) {
      assert(value.wordBoundary&&Array.isArray(value.wordBoundary.canvasPieces)&&value.wordBoundary.canvasPieces.length===7&&value.wordBoundary.canvasPieces.every(x=>Number.isFinite(x)&&x>0));
      if(realm==='page')assert(Array.isArray(value.wordBoundary.domPieces)&&value.wordBoundary.domPieces.length===7&&value.wordBoundary.domPieces.every(x=>Number.isFinite(x)&&x>0));
      else assert.equal(value.wordBoundary.domPieces,null);
    }else assert.equal(value.wordBoundary,null);
  }
  assert.deepEqual(row.matched.typography,{fontKerning:'none',textRendering:'optimizeSpeed',letterSpacing:'0px',wordSpacing:'0px'},'Canvas typography settings not applied');
  if(realm==='page') {
    const css=row.matched.domTypography;
    // CSS serializes optimizeSpeed in lowercase, and Blink serializes zero
    // computed letter-spacing as normal. Preserve the raw readback in evidence.
    assert(css&&['normal','0px'].includes(css.letterSpacing),'DOM letter spacing not zero');
    assert(['optimizespeed','optimizeSpeed'].includes(css.textRendering),'DOM text rendering not applied');
    assert.deepEqual({...css,letterSpacing:'0px',textRendering:'optimizeSpeed'},{fontKerning:'none',fontVariantLigatures:'none',textRendering:'optimizeSpeed',letterSpacing:'0px',wordSpacing:'0px'},'DOM typography settings not applied');
  }
}
function completeShape(value) {
  assert(/^[a-f0-9]{32}$/.test(value?.nonce));assert(Array.isArray(value.realms)&&value.realms.length===2);
  assert.deepEqual(value.realms.map(row=>row.realm).sort(),['page','worker']);
  for(const realm of value.realms) {
    const expected=new Set();
    for(const family of ['NeAntikFontPolicyCanary','Helvetica',`NeAntikMissing_${value.nonce}`])for(const fallback of ['monospace','serif'])for(const style of ['normal 400','normal 700','italic 400'])for(const text of ['ABABA','A B A B'])expected.add(JSON.stringify([family,fallback,style,text]));
    for(const family of ['QALocalUnique','QARemoteCanary','QARemoteAhem'])for(const fallback of ['monospace','serif'])expected.add(JSON.stringify([family,fallback,'normal 400','ABABA']));
    assert(Array.isArray(realm.measurements)&&realm.measurements.length===42);
    for(const row of realm.measurements) {
      assert(expected.delete(key(row)),'Unknown or duplicate font measurement');
      validateFontMeasurement(row,realm.realm);
    }
    assert.equal(expected.size,0);
    assert(Array.isArray(realm.local)&&realm.local.length===2);
    assert.deepEqual(realm.local.map(row=>row.kind).sort(),['invented-missing','known-own-unique']);
  }
}
export function checkFontSession(value,mode) {
  completeShape(value);
  assert(['native','seeded-native','policy-a','policy-b','policy-a-repeat'].includes(mode));
  const policy=mode.startsWith('policy-');let checks=0,defaultMultiwordDifferences=0;
  const check=(condition,message)=>{checks++;assert(condition,message);};
  for(const realm of value.realms) {
    const unique=realm.local.find(row=>row.kind==='known-own-unique'),missing=realm.local.find(row=>row.kind==='invented-missing');
    check(unique.loaded===!policy,'Own local font policy not enforced');
    check(missing.loaded===false&&missing.error==='NetworkError','Invented local font must fail explicitly');
    if(policy)check(unique.error==='NetworkError','Policy refusal must be an explicit local font load error');
    for(const row of realm.measurements) {
      for(const value of [row,row.matched]) {
        check(value.widths.every(width=>close(width,value.widths[0])),'Canvas metrics changed across repeated reads');
        if(value.domWidths) {
          check(value.domWidths.every(width=>close(width,value.domWidths[0])),'DOM metrics changed across repeated reads');
          if(value===row&&row.text.includes(' ')) {
            if(!close(value.widths[0],value.domWidths[0]))defaultMultiwordDifferences++;
          }else check(close(value.widths[0],value.domWidths[0]),'Canvas and DOM disagree under controlled typography');
        }
      }
    }
    for(const fallback of ['monospace','serif']) {
      const downloaded=lookup(realm,'QARemoteCanary',fallback),ahem=lookup(realm,'QARemoteAhem',fallback);
      // These are original fixed test fonts, both with known advance widths.
      for(const value of [downloaded,downloaded.matched])check(close(value.widths[0],73),'Downloaded own TTF did not render its known glyph advance');
      for(const value of [ahem,ahem.matched])check(close(value.widths[0],100),'Downloaded own WOFF2 did not render its known glyph advance');
      const uniqueRow=lookup(realm,'NeAntikFontPolicyCanary',fallback),alias=lookup(realm,'QALocalUnique',fallback);
      const absent=lookup(realm,`NeAntikMissing_${value.nonce}`,fallback);
      check(sameDraw(uniqueRow,policy?absent:downloaded),'Host canary did not use the expected real fallback');
      check(sameDraw(alias,policy?absent:downloaded),'Local FontFace did not draw the expected font');
      if(!policy)check(sameDraw(lookup(realm,'Helvetica',fallback),downloaded),'Native family-collision positive control did not draw own face');
      else {
        const family=lookup(realm,'Helvetica',fallback);
        check(!drawEqual(family,downloaded),'Default policy still draws the injected family-collision face');
        check(!drawEqual(family.matched,downloaded.matched),'Matched policy still draws the injected family-collision face');
      }
      if(policy)for(const style of ['normal 400','normal 700','italic 400'])for(const text of ['ABABA','A B A B']) {
        check(sameDraw(lookup(realm,'NeAntikFontPolicyCanary',fallback,style,text),lookup(realm,`NeAntikMissing_${value.nonce}`,fallback,style,text)),'Styled host font did not fall back consistently');
      }
    }
  }
  const [page,worker]=['page','worker'].map(name=>value.realms.find(row=>row.realm===name));
  const workerRows=new Map(worker.measurements.map(row=>[key(row),row]));
  for(const row of page.measurements)check(sameDraw(row,workerRows.get(key(row))),'Page and DedicatedWorker font drawing disagree');
  return {status:'passed',checks,defaultMultiwordDifferences,scope:'owned page/worker font behavior with explicit matched typography; default multiword widths retained as observations; native ACK separately proves own face selection'};
}
export function checkFontABA(first,last) {
  checkFontSession(first,'policy-a');checkFontSession(last,'policy-a-repeat');
  assert.equal(first.nonce,last.nonce,'A must reopen the same owned root');let checks=0;
  for(const realm of first.realms) {
    const again=last.realms.find(row=>row.realm===realm.realm),rows=new Map(again.measurements.map(row=>[key(row),row]));
    for(const row of realm.measurements) {
      const other=rows.get(key(row));assert(other&&sameDraw(row,other),'A font drawing changed after B');checks++;
      if(row.domWidths)for(const field of [null,'matched']){const a=field?row[field]:row,b=field?other[field]:other;assert(close(a.domWidths[0],b.domWidths[0]),'A DOM metrics changed after B');checks++;}
    }
  }
  return {status:'passed',checks,scope:'same A root and seed reopened after B; not manager identity qualification'};
}

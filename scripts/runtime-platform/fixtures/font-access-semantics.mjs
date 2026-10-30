import assert from 'node:assert/strict';
const keys=(value,list)=>assert.deepEqual(Object.keys(value).sort(),list.slice().sort());
export function checkFontAccess(value,mode){
  assert.equal(value?.schemaVersion,1);assert(/^[a-f0-9]{32}$/.test(value.nonce));assert.equal(value.error,null);assert.equal(value.foreignRemoved,true);
  keys(value,['schemaVersion','nonce','ready','stages','events','foreign','topForeign','error','foreignRemoved']);
  keys(value.ready,['secureContext','visible','initialPermission','activeGesture','filteredNames']);
  assert.equal(value.ready.secureContext,true);assert.equal(value.ready.visible,true);assert(['prompt','denied'].includes(value.ready.initialPermission));assert.equal(value.ready.activeGesture,false);assert.equal(value.ready.filteredNames,4);
  const policy=['policy-a','policy-b','policy-a-repeat'].includes(mode);assert(policy||['native','seeded-native'].includes(mode));
  const grantedIndices=policy?[2]:[0,1,2],grantedSelection=[!policy,!policy,true,false];
  assert.deepEqual(value.stages.map(stage=>stage.phase),['denied-initial','granted','denied-revoked']);
  let checks=0;
  for(const stage of value.stages){
    keys(stage,['phase','permission','eventExpected','eventSeen','count','selected','blobs']);
    const grant=stage.phase==='granted',revoke=stage.phase==='denied-revoked',eventExpected=stage.phase!=='denied-initial'||value.ready.initialPermission!=='denied';
    assert.equal(stage.permission,grant?'granted':'denied');assert.equal(stage.eventExpected,eventExpected);if(eventExpected)assert.equal(stage.eventSeen,true);else assert.equal(stage.eventSeen,false);
    assert.equal(stage.count,grant?grantedIndices.length:0);assert.deepEqual(stage.selected,grant?grantedSelection:[false,false,false,false]);
    assert.deepEqual(stage.blobs.map(blob=>blob.index).sort((a,b)=>a-b),grant||revoke?grantedIndices:[]);
    for(const blob of stage.blobs){
      keys(blob,['index','validSFNT','expectedPostscriptName','matchedOwnTables','drawingValid','removed','sameAsGranted']);
      assert.equal(blob.validSFNT,true);assert.equal(blob.expectedPostscriptName,true);assert.equal(blob.matchedOwnTables,blob.index<2?5:0);
      assert.equal(blob.drawingValid,true);assert.equal(blob.removed,true);assert.equal(blob.sameAsGranted,revoke?true:null);checks+=6;
    }
    checks+=7;
  }
  assert.deepEqual(value.events,[...(value.ready.initialPermission==='denied'?[]:['denied']),'granted','denied']);
  keys(value.foreign,['permission','policyAllowed','activeGesture','count','queryError']);
  assert.deepEqual(value.foreign,{permission:'granted',policyAllowed:true,activeGesture:false,count:grantedIndices.length,queryError:null});
  keys(value.topForeign,['topLevel','visible','permission','policyAllowed','activeGesture','count','queryError']);assert.deepEqual(value.topForeign,{topLevel:true,visible:true,permission:'prompt',policyAllowed:true,activeGesture:false,count:null,queryError:'SecurityError'});checks+=12;
  return {status:'passed',checks,policy,ownNamesGranted:policy?0:2,protectedControlGranted:1,permissionChanges:value.events.length,foreignTopLevelGrantBlocked:true,iframeDelegation:'explicitly-allowed-upstream',retainedBlobAfterRevoke:'allowed-upstream;fresh-query-empty',scope:'explicit four-name filter, top-level-scoped CDP overrides;not origin-pair isolation/native prompt UX/no-internal-enumeration claim'};
}
export function checkFontAccessABA(first,last){
  checkFontAccess(first,'policy-a');checkFontAccess(last,'policy-a-repeat');assert.equal(first.nonce,last.nonce);
  assert.deepEqual(first.ready,last.ready);assert.deepEqual(first.stages,last.stages);assert.deepEqual(first.events,last.events);assert.deepEqual(first.foreign,last.foreign);
  assert.deepEqual(first.topForeign,last.topForeign);
  return {status:'passed',scope:'same owned A profile reopened after B;permission/blob behavior categories;no system-font byte export'};
}

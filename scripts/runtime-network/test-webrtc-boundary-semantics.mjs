import assert from 'node:assert/strict';
import {WEBRTC_CASES, storedPreferences, expectedPreferences, verifyWebRTCCase, verifyWebRTCSuite} from './webrtc-boundary-semantics.mjs';

const binding = {runtimeExecutableSHA256:'a'.repeat(64),runtimeFrameworkSHA256:'b'.repeat(64),machOClosureSHA256:'c'.repeat(64),bindingSHA256:'d'.repeat(64)};
function fixture(spec) {
  const operation = value => ({set:{value,error:null},get:{value,error:null,levelOfControl:'controlled_by_this_extension'}});
  return {id:spec.id,...binding,actualBrowser:true,headed:true,
    document:{loaded:true,nonceMatched:true,defaultRealm:true},
    collector:{canaryAcknowledged:true,canaryCount:1,resetVerified:true,countAfterReset:0},
    preferences:expectedPreferences(spec),
    probe:{kind:'owned-webrtc-boundary',nonceMatched:true,gatheringComplete:true,iceGatheringState:'complete',timedOut:false,
      candidates:{host:1,srflx:spec.expectUDP?1:0,prflx:0,relay:0,other:0},errorCodes:[],rawICEExported:false},
    udp:{closedAfterBrowserExit:true,finalCounters:true,browserRequests:spec.expectUDP?1:0,invalidRequests:0,canaryCount:1},proxyRequests:spec.guarded?1:0,
    extension:spec.extension?{nonceMatched:true,runtimeIDMatched:true,policy:spec.policy,permissions:['privacy'],
      operations:spec.policy?[]:[operation('disable_non_proxied_udp'),operation('default')],
      final:{value:'default',error:null,levelOfControl:spec.policy?'not_controllable':'controlled_by_this_extension'}}:null,
    cleanup:{graceful:true,exitCode:0,signal:null,forcedTermination:false,ownedProcessesRemaining:0,ownedProfileRemoved:true}};
}
const rows = WEBRTC_CASES.map(fixture);
assert.equal(verifyWebRTCSuite(rows,binding).cases,11);
const mutations = [
  r=>r.id='unknown',r=>r.actualBrowser=false,r=>r.headed=false,
  r=>r.runtimeExecutableSHA256='e'.repeat(64),r=>r.runtimeFrameworkSHA256='e'.repeat(64),r=>r.bindingSHA256='e'.repeat(64),
  r=>r.machOClosureSHA256='e'.repeat(64),r=>r.document.loaded=false,r=>r.document.nonceMatched=false,
  r=>r.document.defaultRealm=false,r=>r.collector.canaryAcknowledged=false,r=>r.collector.canaryCount=0,
  r=>r.collector.resetVerified=false,r=>r.collector.countAfterReset=1,r=>delete r.preferences['webrtc.ip_handling_url'],
  r=>r.preferences['webrtc.ip_handling_policy']='disable_non_proxied_udp',r=>r.probe.gatheringComplete=false,
  r=>r.probe.iceGatheringState='gathering',r=>r.probe.timedOut=true,r=>r.probe.rawICEExported=true,
  r=>r.probe.nonceMatched=false,r=>r.udp.finalCounters=false,r=>r.udp.closedAfterBrowserExit=false,
  r=>r.udp.invalidRequests=1,r=>r.udp.canaryCount=2,
  r=>r.udp.browserRequests=0,r=>r.udp.browserRequests=true,r=>r.extension={},r=>r.proxyRequests=1,
  r=>r.cleanup.graceful=false,r=>r.cleanup.graceful='false',r=>r.cleanup.exitCode=1,
  r=>r.cleanup.signal='SIGTERM',r=>r.cleanup.forcedTermination=true,r=>r.cleanup.ownedProcessesRemaining=1,
  r=>r.cleanup.ownedProfileRemoved=false,
];
for (const mutate of mutations) {const row=structuredClone(rows[0]);mutate(row);assert.throws(()=>verifyWebRTCCase(row,binding));}
let negatives=mutations.length;
for(const spec of WEBRTC_CASES.filter(spec=>spec.guarded&&!spec.extension)){
  const row=fixture(spec);row.preferences=storedPreferences(spec);
  assert.throws(()=>verifyWebRTCCase(row,binding));negatives++;
}
for (const spec of WEBRTC_CASES) {
  const row=fixture(spec);row.udp.browserRequests=spec.expectUDP?0:1;
  assert.throws(()=>verifyWebRTCCase(row,binding));negatives++;
}
for (const id of ['extension-direct','policy-direct']) {
  for (const mutate of [r=>r.extension.nonceMatched=false,r=>r.extension.runtimeIDMatched=false,
    r=>r.extension.final.error='error',r=>r.extension.final.levelOfControl='controllable_by_this_extension',
    r=>r.extension.permissions.push('tabs')]) {
    const row=fixture(WEBRTC_CASES.find(s=>s.id===id));mutate(row);assert.throws(()=>verifyWebRTCCase(row,binding));negatives++;
  }
}
for (const bad of [rows.slice(1),[...rows,rows[0]],[...rows.slice(0,-1),rows[0]]]) {
  assert.throws(()=>verifyWebRTCSuite(bad,binding));negatives++;
}
console.log(JSON.stringify({status:'webrtc-model-controls-pass',positive:11,negative:negatives,actualBrowser:false}));

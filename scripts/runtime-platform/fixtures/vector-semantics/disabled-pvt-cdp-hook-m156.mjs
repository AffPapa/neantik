// M156: public PDL has no Storage.disable command. Fresh own-profile getCookies
// is the second real ordinary Storage positive; no user cookies are read.
// Owned regression hook for the disabled PVT DevTools surface.
// Caller must bind a signed headed runtime, actual owned page and transport.
// This hook alone never qualifies a runtime or release.
import assert from 'node:assert/strict';
export const unavailableMessage='Private Verification Tokens service is not available';
export const pvtCommands=Object.freeze([
 ['Storage.getPrivateVerificationTokens',{}],
 ['Storage.getPrivateVerificationTokensIssuerConfigs',{}],
 ['Storage.clearPrivateVerificationTokens',{issuerOrigin:'https://owned-issuer.invalid'}],
 ['Storage.deletePrivateVerificationToken',{tokenId:'1'}],
 ['Storage.setPrivateVerificationTokensTracking',{enable:true}],
 ['Storage.setPrivateVerificationTokensTracking',{enable:false}],
]);
export async function observeDisabledPVT(send,origin){
 const url=new URL(origin);assert(url.protocol==='http:'&&url.hostname==='127.0.0.1'&&url.port&&url.pathname==='/');
 // Ordinary Storage dispatch is a positive control on the same page/transport.
 const quota=await send('Storage.getUsageAndQuota',{origin});
 const cookies=await send('Storage.getCookies',{});
 const ordinaryStorage={quotaSucceeded:quota.error===undefined&&Number.isFinite(quota.result?.usage)&&Number.isFinite(quota.result?.quota)&&Array.isArray(quota.result?.usageBreakdown),cookiesSucceeded:cookies.error===undefined&&Array.isArray(cookies.result?.cookies)&&cookies.result.cookies.length===0};
 const observations=[];
 for(const [method,params] of pvtCommands){
  const response=await send(method,params);
  observations.push({method,trackingEnabled:method.endsWith('Tracking')?params.enable:null,
   responseReceived:true,hasResult:Object.hasOwn(response,'result'),errorCode:response.error?.code??null,
   unavailableMessageMatched:response.error?.message===unavailableMessage});
 }
 return {schemaVersion:1,ordinaryStorage,observations,runtimeQualified:false,releaseReady:false};
}
export function verifyDisabledPVT(report){
 assert.equal(report.schemaVersion,1);assert.equal(report.ordinaryStorage?.quotaSucceeded,true);
 assert.equal(report.ordinaryStorage?.cookiesSucceeded,true);assert(Array.isArray(report.observations));assert.equal(report.observations.length,pvtCommands.length);
 for(let i=0;i<pvtCommands.length;i++){
  const observation=report.observations[i],[method,params]=pvtCommands[i];
  assert.equal(observation.method,method);assert.equal(observation.trackingEnabled,method.endsWith('Tracking')?params.enable:null);
  assert.equal(observation.responseReceived,true);assert.equal(observation.hasResult,false);
  assert.equal(observation.errorCode,-32000);assert.equal(observation.unavailableMessageMatched,true);
 }
 assert.equal(report.runtimeQualified,false);assert.equal(report.releaseReady,false);
 return {commandsVerified:6,ordinaryStorageControls:2,scope:'CDP response semantics only; caller runtime binding required',runtimeQualified:false,releaseReady:false};
}

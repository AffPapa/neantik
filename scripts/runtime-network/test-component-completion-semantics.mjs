import assert from 'node:assert/strict';
import {verifyComponentCompletion} from './component-completion-semantics.mjs';
const after = {targetCount: 1, unknownAbsent: true, buttonReady: true,
  version: '0.0.0.0', status: 'Update error', domStatus: 'Update error', checkingLabel: 'Checking',
  events: [{event: 'Checking'}, {event: 'Update error'}]};
const base = {actualBrowser: true, unknownControlNoRequests: true,
  collectorControls: {originCounted: true, proxyCountedRejected: true, resetVerified: true},
  originRequestCount: 0, proxyRequestCount: 0,
  before: {targetCount: 1, unknownAbsent: true, buttonReady: true, version: '0.0.0.0', status: 'New'},
  attempts: [0, 1].map(() => ({buttonClicked: true, elapsedMs: 30, after: structuredClone(after)})),
  errorTuple: {updateclientlastupdatecheckerrorcategory: 5, updateclientlastupdatecheckerror: -10014, updateclientlastupdatecheckerrorextracode1: 0},
  requests: [], proxyRequests: [], blockedConnects: 0, blockedRequests: 0,
  cleanup: {graceful: true, exitCode: 0, ownedProcessesRemaining: 0, ownedProfileRemoved: true}};
assert.equal(verifyComponentCompletion(base).status, 'observed-local-policy-refusal-and-repeat-completion');
const controls = [
  row => {row.collectorControls.originCounted = false;},
  row => {row.collectorControls.proxyCountedRejected = false;},
  row => {row.collectorControls.resetVerified = false;},
  row => {row.originRequestCount = 1;}, row => {row.proxyRequestCount = 1;},
  row => {row.originFailure = {kind: 'observer error'};},
  row => {row.actualBrowser = false;}, row => {row.unknownControlNoRequests = false;},
  row => {row.attempts = [];}, row => {row.attempts.pop();},
  row => {row.attempts[0].buttonClicked = false;}, row => {row.attempts[0].elapsedMs = 9000;},
  row => {row.attempts[0].after.status = 'Checking';}, row => {row.attempts[0].after.domStatus = 'Checking';},
  row => {row.attempts[0].after.events = [];}, row => {row.attempts[0].after.events.pop();},
  row => {row.attempts[0].after.events = [{event: 'Update error'}, {event: 'Update error'}];},
  row => {row.attempts[0].after.version = '1.0';}, row => {row.attempts[1].after.status = 'New';},
  row => {row.errorTuple = null;}, row => {row.errorTuple.updateclientlastupdatecheckerror = 0;},
  row => {row.errorTuple.updateclientlastupdatecheckerror = -10000;},
  row => {row.requests.push({route: 'direct'});}, row => {row.proxyRequests.push({target: 'unexpected'});},
  row => {row.blockedConnects++;}, row => {row.blockedRequests++;},
  row => {row.cleanup.graceful = false;}, row => {row.cleanup.graceful = 'false';},
  row => {row.cleanup.graceful = 1;}, row => {row.cleanup.exitCode = 1;},
  row => {row.cleanup.ownedProcessesRemaining = 1;}, row => {row.cleanup.ownedProfileRemoved = false;},
];
for (const mutate of controls) {const broken = structuredClone(base); mutate(broken); assert.throws(() => verifyComponentCompletion(broken));}
console.log(JSON.stringify({status: 'component-completion-observation-controls-pass', positive: 1, negative: controls.length, actualBrowser: false}));

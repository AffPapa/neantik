// Research observation oracle. This does not grant release/runtime authority.
import assert from 'node:assert/strict';

export function verifyComponentCompletion(record) {
  assert.equal(record.actualBrowser, true);
  assert.equal(record.unknownControlNoRequests, true);
  assert.deepEqual(record.collectorControls, {originCounted: true, proxyCountedRejected: true, resetVerified: true});
  assert.equal(record.originRequestCount, 0, 'Unexpected request reached own origin');
  assert.equal(record.proxyRequestCount, 0, 'Unexpected request reached own proxy');
  assert(!record.originFailure, 'Origin observer failed');
  assert.equal(record.before?.targetCount, 1);
  assert.equal(record.before?.buttonReady, true);
  assert.equal(record.before?.unknownAbsent, true);
  assert.equal(record.attempts?.length, 2, 'Two real completed foreground operations required');
  let errorStatus;
  for (const [index, attempt] of record.attempts.entries()) {
    assert.equal(attempt.buttonClicked, true);
    assert(Number.isFinite(attempt.elapsedMs) && attempt.elapsedMs >= 0 && attempt.elapsedMs < 8000);
    const value = attempt.after;
    assert(value?.targetCount === 1 && value.unknownAbsent === true && value.buttonReady === true);
    assert.equal(value.version, record.before.version, 'Refused operation changed component version');
    assert(typeof value.status === 'string' && value.status.length > 0);
    assert.equal(value.domStatus, value.status, 'Visible status differs from native status');
    assert.notEqual(value.status, value.checkingLabel, 'Visible check still pending');
    assert(Array.isArray(value.events) && value.events.length >= 2 && value.events.length <= 16);
    assert.equal(value.events.at(-1).event, value.status, 'No terminal event for current operation');
    assert(value.events.some(event => event.event !== value.status), 'No observed state transition');
    if (index === 0) {
      assert.notEqual(value.status, record.before.status, 'Initial state was reused as completion');
      errorStatus = value.status;
    } else assert.equal(value.status, errorStatus, 'Repeated check did not reach the same refusal');
  }
  assert.deepEqual(record.errorTuple, {
    updateclientlastupdatecheckerrorcategory: 5,
    updateclientlastupdatecheckerror: -10014,
    updateclientlastupdatecheckerrorextracode1: 0,
  }, 'Persisted result is not the intentional unsupported-operation refusal');
  for (const name of ['requests', 'proxyRequests']) assert.deepEqual(record[name], [], 'Unexpected component request');
  for (const name of ['blockedConnects', 'blockedRequests']) assert.equal(record[name], 0, 'Unexpected background attempt');
  assert(record.cleanup?.graceful === true && record.cleanup.exitCode === 0
    && record.cleanup.ownedProcessesRemaining === 0 && record.cleanup.ownedProfileRemoved === true);
  return {status: 'observed-local-policy-refusal-and-repeat-completion', actualBrowser: true,
    routeProved: false, cupRefusalProved: false, releaseQualified: false};
}

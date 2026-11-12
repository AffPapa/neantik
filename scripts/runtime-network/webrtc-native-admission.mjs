// The Python observer emits macOS userspace pressure flags (1 normal, 2
// warning, 4 critical). Require a consistent success before opening Chromium.
export function hasNormalWebRTCAdmission(exitStatus, snapshot) {
  return exitStatus === 0 && snapshot?.schemaVersion === 1 &&
    snapshot.eligibleForAttempt === true && snapshot.memoryPressure === 1 &&
    [0, 1].includes(snapshot.thermalState) &&
    Array.isArray(snapshot.reasons) && snapshot.reasons.length === 0;
}

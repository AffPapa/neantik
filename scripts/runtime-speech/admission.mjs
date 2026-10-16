// Research-only exception. The operator must have a fresh, explicit approval
// for this bounded speech stage; this never changes manager/release admission.
export function speechAdmission(snapshot, exitStatus, approvedWarning = false) {
  const normal = exitStatus === 0 && snapshot?.eligibleForAttempt === true &&
    snapshot.memoryPressure === 1 && [0, 1].includes(snapshot.thermalState) &&
    Array.isArray(snapshot.reasons) && snapshot.reasons.length === 0;
  const exception = approvedWarning === true && exitStatus === 75 &&
    snapshot?.eligibleForAttempt === false && snapshot.memoryPressure === 2 &&
    [0, 1].includes(snapshot.thermalState) && Array.isArray(snapshot.reasons) &&
    snapshot.reasons.length === 1 && snapshot.reasons[0] === 'memory_pressure_warning';
  return {allowed: normal || exception, approvedWarningUsed: exception};
}

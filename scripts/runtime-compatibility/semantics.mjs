// Explicit acceptance; a timed out negative is not a successful negative.
const controlNames = ['missing-case', 'declaration-only', 'no-real-frames', 'wrong-frame', 'wrong-asset',
  'silent-audio', 'wrong-tone', 'ignored-decode-failure', 'ignored-invalid-config', 'timeout'];
export function mediaAccepted(verdict, exitCode) {
  const controls = verdict?.offlineNegativeControls;
  return exitCode === 0 && verdict?.status === 'passed-scoped-codec-operations'
    && Number.isInteger(verdict.checks) && verdict.checks > 0
    && Array.isArray(verdict.issues) && verdict.issues.length === 0
    && Array.isArray(controls) && controls.length === controlNames.length
    && controls.every(c => c.rejected === true)
    && JSON.stringify(controls.map(c => c.name).sort()) === JSON.stringify(controlNames.slice().sort());
}
export function pdfAccepted(page, pixels, pollCompleted) {
  if (pollCompleted !== true || !pixels) return false;
  if (page === 'colours') return pixels.blue > 500 && pixels.yellow > 500 && pixels.correctVerticalOrder === true;
  if (page === 'blank') return pixels.blue < 100 && pixels.yellow < 100 && pixels.white > 1000;
  return false;
}
export async function cleanupWithServer(primaryCleanup, serverCleanup) {
  let failure;
  try { await primaryCleanup(); } catch (error) { failure = error; }
  try { await serverCleanup(); } catch (error) { failure ??= error; }
  if (failure) throw failure;
}

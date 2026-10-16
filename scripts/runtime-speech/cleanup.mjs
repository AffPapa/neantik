// Wait for normal helper drain before deciding whether group custody permits
// a signal. A transient separate-PGID Crashpad is not permission to signal it.
import assert from 'node:assert/strict';

export async function settleOwnedProcesses({inspect, waitFor, mainPID, uid, signalGroup}) {
  assert(Number.isSafeInteger(mainPID) && mainPID > 1 && Number.isSafeInteger(uid) && uid >= 0);
  if (await waitFor(() => inspect().length === 0, 5000)) return {naturalDrain: true, groupSignalled: false};
  const remaining = inspect();
  if (!remaining.length) return {naturalDrain: true, groupSignalled: false};
  assert(remaining.every(p => p.pgid === mainPID && p.uid === uid), 'Unknown process custody; retain profile');
  try { signalGroup(-mainPID); } catch (error) { if (error.code !== 'ESRCH') throw error; }
  assert(await waitFor(() => inspect().length === 0, 5000), 'Owned process group did not drain');
  return {naturalDrain: false, groupSignalled: true};
}

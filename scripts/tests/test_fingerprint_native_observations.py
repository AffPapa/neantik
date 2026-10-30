"""Execute the shipped probe's native-observation block with controlled APIs.

These controls test collector failure handling; headed browser qualification
remains separate. Neither device labels nor raw exception text may escape.
"""
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class NativeObservationTests(unittest.TestCase):
    def test_success_failure_malformed_timeout_and_absence(self):
        source = (ROOT / "Sources/NeAntik/FingerprintAudit.swift").read_text()
        start = source.index("      const boundedNativeObservation") if "      const boundedNativeObservation" in source else source.index("      const permissionState =")
        block = source[start:source.index("      const observeSpeechVoices", start)]
        harness = r'''
const assert = require('node:assert/strict');
async function run(navigator) {
  // Accelerate timeouts, preserving the actual race/cleanup implementation.
  let active = new Set();
  const setTimeout = fn => { const id = global.setTimeout(fn, 10); active.add(id); return id; };
  const clearTimeout = id => { active.delete(id); global.clearTimeout(id); };
  const result = await (async () => {
BLOCK
    return { mediaDevices, mediaDeviceCount, mediaDeviceObservation,
      permissionCamera, permissionMicrophone, permissionCameraObservation,
      permissionMicrophoneObservation };
  })();
  assert.equal(active.size, 0, 'collector must clear timers');
  assert(!JSON.stringify(result).includes('secret'));
  return result;
}
const permissions = {query: async () => ({state:'prompt'})};
(async () => {
  let r = await run({permissions, mediaDevices:{enumerateDevices:async()=>[{label:'secret',deviceId:'secret'}]}});
  assert.equal(r.mediaDeviceObservation,'observed'); assert.equal(r.mediaDeviceCount,'1');
  assert.equal(r.permissionCameraObservation,'observed');
  r = await run({permissions, mediaDevices:{enumerateDevices:async()=>{throw Error('secret')}}});
  assert.equal(r.mediaDeviceObservation,'error'); assert.equal(r.mediaDeviceCount,'unavailable');
  r = await run({permissions, mediaDevices:{enumerateDevices:async()=>({length:-1})}});
  assert.equal(r.mediaDeviceObservation,'error'); assert.equal(r.mediaDeviceCount,'unavailable');
  r = await run({permissions:{query:()=>new Promise(()=>{})}, mediaDevices:{enumerateDevices:()=>new Promise(()=>{})}});
  assert.equal(r.mediaDeviceObservation,'timeout'); assert.equal(r.permissionCameraObservation,'timeout');
  assert.equal(r.permissionCamera,'unknown');
  r = await run({}); assert.equal(r.mediaDeviceObservation,'api-absent');
  assert.equal(r.permissionCameraObservation,'api-absent');
  r = await run({permissions:{query:async()=>({state:'invented'})}});
  assert.equal(r.permissionCameraObservation,'error');
  console.log('native observation controls PASS');
})().catch(e=>{console.error(e);process.exitCode=1});
'''.replace("BLOCK", block)
        result = subprocess.run([shutil.which("node") or "node", "-e", harness], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()

from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]

class Privacy20QualificationControlsTests(unittest.TestCase):
    def test_rtc_pair_differs_only_in_the_intended_policy(self):
        subprocess.run(["node", "--input-type=module", "-e", """
import assert from 'node:assert/strict';
import {applyRTCFixturePolicy} from './scripts/privacy20/qa-controls.mjs';
const args=['--use-mock-keychain','--webrtc-ip-handling-policy=disable_non_proxied_udp'];
const env={NEANTIK_PROFILE_PROXY_REQUIRED:'1',NEANTIK_PROFILE_RTC:'off',NEANTIK_PROFILE_LAN:'deny',NEANTIK_PROFILE_MEDIA:'deny'};
const a=[...args],b=[...args],ea={...env},eb={...env};
applyRTCFixturePolicy('rtc-proxy',a,ea);applyRTCFixturePolicy('rtc-control',b,eb);
assert.deepEqual(ea,eb);assert(!Object.hasOwn(ea,'NEANTIK_PROFILE_LAN'));assert(!Object.hasOwn(ea,'NEANTIK_PROFILE_RTC'));
assert.equal(ea.NEANTIK_PROFILE_PROXY_REQUIRED,'1');assert.equal(ea.NEANTIK_PROFILE_MEDIA,'deny');
assert.equal(a.filter((v,i)=>v!==b[i]).length,1);
assert.equal(a[1],'--webrtc-ip-handling-policy=disable_non_proxied_udp');assert.equal(b[1],'--webrtc-ip-handling-policy=default_public_interface_only');
assert.throws(()=>applyRTCFixturePolicy('rtc-proxy',[],{...env}));
assert.throws(()=>applyRTCFixturePolicy('rtc-proxy',[...args],{}));
"""], cwd=ROOT, check=True, capture_output=True, text=True)

    def test_media_array_inequality_does_not_hide_a_shared_identifier(self):
        subprocess.run(["node", "--input-type=module", "-e", """
import assert from 'node:assert/strict';
import {assertDisjointMediaIdentifiers as disjoint} from './scripts/privacy20/qa-controls.mjs';
const a=[{device:'a',group:'x'},{device:'b',group:'y'}];
const partlyShared=[{device:'a',group:'x'},{device:'c',group:'z'}];
assert.notDeepEqual(a,partlyShared);
assert.throws(()=>disjoint(a,partlyShared,'device'));
assert.throws(()=>disjoint(a,partlyShared,'group'));
assert.throws(()=>disjoint(a,[],'group'));
disjoint(a,[{device:'c',group:'z'},{device:'d',group:'w'}],'device');
disjoint(a,[{device:'c',group:'z'},{device:'d',group:'w'}],'group');
"""], cwd=ROOT, check=True, capture_output=True, text=True)

    def test_fixed_owned_pages_have_valid_module_syntax(self):
        result = subprocess.run(["node", "--input-type=module", "-e", """
import {page,rtcPage,workerIsolationPage,mediaIsolationPage,serviceWorkerSource,dedicatedWorkerStateSource} from './scripts/privacy20/probe.mjs';
import {spawnSync} from 'node:child_process';
for(const html of [page('owned','A1','a'.repeat(32)),rtcPage('owned',12345),workerIsolationPage('owned','A1','a'.repeat(32)),mediaIsolationPage('owned','A1','a'.repeat(32))]){
 const script=html.split('<script type=module>')[1].split('</script>')[0];
 const r=spawnSync(process.execPath,['--input-type=module','--check'],{input:script,encoding:'utf8'});if(r.status!==0)throw Error(r.stderr);
}
for(const source of [serviceWorkerSource,dedicatedWorkerStateSource]){const r=spawnSync(process.execPath,['--check'],{input:source,encoding:'utf8'});if(r.status!==0)throw Error(r.stderr);}
"""], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

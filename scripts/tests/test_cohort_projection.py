"""Finite fixture controls, separate from actual signed headed qualification."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE=Path(__file__).resolve().parents[1]/'runtime-platform/qualify-cohorts.py'
SPEC=importlib.util.spec_from_file_location('finite_cohort_test',SOURCE)
MOD=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(MOD)


class CohortProjectionTests(unittest.TestCase):
    def fixture(self,root):
        row=json.loads((MOD.ROOT/'runtime/apple-device-tuples.json').read_text())['tuples'][0]
        entries=[]
        for name in ('cohort-projection-probe.js','run-headed-m156.mjs'):
            target=root/'vector-semantics'/name;target.parent.mkdir(exist_ok=True)
            target.write_text('owned synthetic source: '+name)
            digest=MOD.BASE.digest(target)
            archive=root/'fixture-source-archive/blobs'/digest;archive.parent.mkdir(parents=True,exist_ok=True)
            archive.write_bytes(target.read_bytes())
            entries.append(dict(path='vector-semantics/'+name,bytes=target.stat().st_size,sha256=digest))
        proof_hash=hashlib.sha256(json.dumps(entries,separators=(',',':'),ensure_ascii=False).encode()).hexdigest()
        binding=dict(runtimeVersion='156.0.8078.12',runtimeExecutableSHA256='a'*64,runtimeFrameworkSHA256='b'*64)
        value=dict(cpu=row['hardwareConcurrency'],memory=row['webDeviceMemoryGB'],screen=row['screen'],
            hints=dict(architecture='arm',bitness='64',mobile=False,platform='macOS',platformVersion=row['platformVersion']),
            renderer=f"ANGLE (Apple, ANGLE Metal Renderer: Apple {row['gpuModel']}, Unspecified Version)")
        capture=dict(label='cohort-11',mode='neantik-configured',headed=True,cleanupVerified=True,documentEvidence=dict(loaded=True),
            runtimeVersion=binding['runtimeVersion'],executableSHA256='a'*64,runtimeFrameworkSHA256='b'*64,
            candidateBindingSHA256=hashlib.sha256((json.dumps(binding,sort_keys=True,indent=2)+'\n').encode()).hexdigest(),
            probeSHA256=MOD.BASE.digest(root/'vector-semantics/cohort-projection-probe.js'),
            runnerSHA256=MOD.BASE.digest(root/'vector-semantics/run-headed-m156.mjs'),
            fixtureProvenance=dict(manifestSHA256=proof_hash,files=entries),fixtureSourceArchive=dict(manifestSHA256=proof_hash),
            browserClosure=dict(gracefulParentExit=True,parentExitCode=0,parentSignal=None),
            syntheticConfiguration=dict(profileSeed=11,scope='synthetic-direct-manager-policy',launchReceiptSHA256='d'*64),
            data=dict(kind='finite-cohort-projection',errors=[],first=value,repeat=copy.deepcopy(value)))
        return capture,row,binding

    def test_complete_projection_and_eleven_distinct_controls(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);capture,row,binding=self.fixture(root)
            self.assertTrue(MOD.verify(capture,row,11,binding,'d'*64,root))
            self.assertEqual(len(set(MOD.sensitivity(capture,row,11,binding,'d'*64,root))),11)

    def test_equal_repeated_wrong_values_still_fail_specific_oracle(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);capture,row,binding=self.fixture(root)
            for field,value,reason in [('cpu',1,'cpu'),('memory',1,'memory'),('screen','wrong','screen'),
                                       ('renderer','Apple M1 Pro','gpu')]:
                bad=copy.deepcopy(capture)
                for phase in ('first','repeat'):bad['data'][phase][field]=value
                with self.subTest(field=field),self.assertRaisesRegex(ValueError,'cohort-'+reason):MOD.verify(bad,row,11,binding,'d'*64,root)
            for phase in ('first','repeat'):capture['data'][phase]['hints']['mobile']=0
            with self.assertRaisesRegex(ValueError,'platform-hints'):MOD.verify(capture,row,11,binding,'d'*64,root)

    def test_missing_provenance_wrong_label_and_non_graceful_exit_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);capture,row,binding=self.fixture(root)
            for field,value in [('candidateBindingSHA256','0'*64),('probeSHA256','0'*64),('runnerSHA256','0'*64),
                ('label','cohort-12'),('browserClosure',dict(gracefulParentExit=False,parentExitCode=0,parentSignal=None)),
                ('browserClosure',dict(gracefulParentExit=True,parentExitCode=False,parentSignal=None))]:
                bad=copy.deepcopy(capture);bad[field]=value
                with self.subTest(field=field),self.assertRaises(ValueError):MOD.verify(bad,row,11,binding,'d'*64,root)

    def test_actual_node_launch_receipt_default_and_finite_seed_scope(self):
        module=(SOURCE.parent/'fixtures/candidate-binding.mjs').as_uri()
        with tempfile.TemporaryDirectory() as directory:
            receipt=Path(directory)/'receipt.json'
            flags=['--no-first-run','--no-default-browser-check','--new-window','--no-proxy-server',
                   '--webrtc-ip-handling-policy=default_public_interface_only','--disable-features=WebGPUService']
            code='''import {applyManagerLaunch} from MODULE;import assert from 'node:assert/strict';
                process.env.NEANTIK_PLATFORM_LAUNCH_RECEIPT=process.argv[1];
                const seed=Number(process.argv[2]),expect=process.argv[3];
                const run=()=>{let env={};applyManagerLaunch([],env,...(expect==='default'?[]:[seed]));return env};
                if(expect==='reject')assert.throws(run);else assert.deepEqual(run(),{NEANTIK_PROFILE_SEED:String(seed)});'''.replace('MODULE',json.dumps(module))
            for requested,stored,expected in [(21,21,'default'),(11,11,'pass'),(21,21,'pass'),(11,12,'reject'),(10,10,'reject'),(22,22,'reject')]:
                receipt.write_text(json.dumps(dict(schemaVersion=1,scope='synthetic-direct-profile-manager-policy',
                    arguments=flags,environment={'NEANTIK_PROFILE_SEED':str(stored)})))
                result=subprocess.run(['node','--input-type=module','-e',code,str(receipt),str(requested),expected],capture_output=True,text=True,timeout=10)
                with self.subTest(requested=requested,stored=stored):self.assertEqual(result.returncode,0,result.stderr)


if __name__=='__main__':unittest.main()

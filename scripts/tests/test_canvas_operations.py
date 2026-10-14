"""Numerical/coverage refusal controls; actual browser runs are separate."""
import base64
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE=Path(__file__).resolve().parents[1]/'runtime-platform/fixtures/vector-semantics/verify-canvas-operations.py'
spec=importlib.util.spec_from_file_location('canvas_operations',SOURCE)
MOD=importlib.util.module_from_spec(spec);spec.loader.exec_module(MOD)

class CanvasOperationsTests(unittest.TestCase):
    def test_positive_and_independent_negative_contract(self):
        self.assertTrue(MOD.verify(MOD.positive_fixture())['passed'])
        controls=MOD.negative_controls()
        self.assertEqual({c['name'] for c in controls},set(MOD.CONTROL_NAMES))
        self.assertTrue(all(c['rejected'] for c in controls))
    def test_rounding_bound_is_not_permission_to_corrupt_alpha_or_opaque_pixels(self):
        for index in (3,31):
            data=MOD.positive_fixture();c=data['cases']['coloredPut'];raw=bytearray(base64.b64decode(c['pixels']))
            raw[index]^=1;c['pixels']=MOD.encoded(raw);c['repeat']=c['pixels']
            self.assertFalse(MOD.verify(data)['passed'])
    def test_each_fractional_premultiplied_channel_has_a_numeric_bound(self):
        data=MOD.positive_fixture();c=data['cases']['coloredPut'];raw=bytearray(base64.b64decode(c['pixels']))
        # Case3 has alpha64: shifting its unpremultiplied red by16 changes
        # stored premultiplied color by4, well beyond the quantization bound.
        raw[3*4]=(raw[3*4]+16)%256;c['pixels']=MOD.encoded(raw);c['repeat']=c['pixels']
        self.assertIn('premultiplied-color',MOD.verify(data)['issues'])
    def test_booleans_and_additional_default_fields_are_not_numeric_states(self):
        for mutate in (lambda s:s.update(alpha=True),lambda s:s['transform'].__setitem__(0,True),
                       lambda s:s.update(extra='unproven')):
            data=MOD.positive_fixture();mutate(data['cases']['reset']['state'])
            self.assertFalse(MOD.verify(data)['passed'])
    def test_missing_reset_and_capture_error_never_qualify(self):
        for mutate in (lambda d:d['cases'].__setitem__('reset',{'available':False}),
                       lambda d:d['errors'].append({'operation':'reset','error':'TypeError'})):
            d=MOD.positive_fixture();mutate(d);self.assertFalse(MOD.verify(d)['passed'])
    def test_partial_copy_clears_background_and_replaces_transparent_pixels(self):
        data=MOD.positive_fixture();case=data['cases']['copyComposite']
        raw=base64.b64decode(case['pixels'])
        self.assertEqual(raw[:4],bytes(4))
        self.assertEqual(raw[(3*16+2)*4:(3*16+2)*4+4],MOD.gradient(0,0))
        self.assertEqual(raw[(3*16+3)*4:(3*16+3)*4+4],bytes(4))
        case['pixels']=MOD.encoded(MOD.raster(16,12,lambda x,y:MOD.copy_pixel(x,y)
            if MOD.copy_pixel(x,y)[3] else bytes((255,0,255,255))))
        self.assertFalse(MOD.verify(data)['passed'])
    def test_reset_requires_nonzero_before_and_empty_after(self):
        for field,value in [('beforeReset',MOD.encoded(bytes(768))),
                            ('blank',MOD.encoded(MOD.raster(16,12,MOD.gradient)))]:
            data=MOD.positive_fixture();data['cases']['reset'][field]=value
            self.assertFalse(MOD.verify(data)['passed'])
    def test_short_invalid_or_noncanonical_pixel_data_is_rejected(self):
        for bad in ('AAAA','not-base64','A'*20000):
            d=MOD.positive_fixture();d['cases']['copyCanvas']['pixels']=bad
            self.assertFalse(MOD.verify(d)['passed'])
    def test_cli_rejects_duplicates_nonfinite_and_oversized_before_verification(self):
        with tempfile.TemporaryDirectory() as root:
            p=Path(root)/'observation.json'
            for raw in ('{"data":null,"data":null}','{"data":NaN}','x'*131073):
                p.write_text(raw)
                r=subprocess.run(['python3','-B',str(SOURCE),str(p)],capture_output=True,text=True)
                self.assertEqual(r.returncode,1);self.assertEqual(json.loads(r.stdout)['issues'],['invalid-observation-envelope'])

if __name__=='__main__':unittest.main()

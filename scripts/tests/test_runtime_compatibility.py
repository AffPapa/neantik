import base64
import binascii
import importlib.util
import json
from pathlib import Path
import struct
import unittest
from unittest import mock
import zlib


HERE = Path(__file__).resolve().parents[1] / "runtime-compatibility"
SPEC = importlib.util.spec_from_file_location("codec_oracle", HERE / "verify.py")
ORACLE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ORACLE)


def fixture():
    cases = [dict(id=name, kind="video" if i < 3 else "audio", file=name) for i, name in enumerate(("vp8", "vp9", "h264", "pcm", "opus", "aac"))]
    manifest = dict(cases=cases, files={c["file"]: {"sha256": "a" * 64} for c in cases})
    rows = []
    for c in cases:
        row = dict(id=c["id"], kind=c["kind"], assetSHA256="a" * 64, status="decoded-and-played", canPlayType="probably",
                   capabilities=dict(supported=True, smooth=False, powerEfficient=False), playback=dict(advanced=0.25))
        if c["kind"] == "video":
            row.update(dimensions=[64, 48], decodedFrames=5, pixel=[254, 0, 0, 255])
        else:
            row["decoded"] = dict(sampleRate=48000, channels=1, seconds=1, rms=0.177, hertz=440)
        rows.append(row)
    return dict(kind="actual-codec-playback", rows=rows, brokenMedia="decode-rejected", invalidConfiguration="TypeError"), manifest


def png(blank=False, swapped=False, transparent_profiled=False):
    def chunk(kind, raw):
        return struct.pack(">I", len(raw)) + kind + raw + struct.pack(">I", binascii.crc32(kind + raw) & 0xffffffff)
    width = height = 128
    raw = b""
    for y in range(height):
        colour = b"\xff\xff\xff" if blank else b"\xff\xff\x00" if (y < 64) != swapped else b"\x00\x00\xff"
        raw += b"\x00" + (colour + b"\x00" if transparent_profiled else colour) * width
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6 if transparent_profiled else 2, 0, 0, 0))
    if transparent_profiled:
        # Source opacity must be refused before interpreting any ICC payload.
        data += chunk(b"iCCP", b"own-profile\x00\x00" + zlib.compress(b"never-used"))
    data += chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    return base64.b64encode(data).decode()


class RuntimeCompatibilityTests(unittest.TestCase):
    def test_real_operation_model_and_all_negative_controls(self):
        observation, manifest = fixture()
        self.assertEqual(ORACLE.verify(observation, manifest)["issues"], [])
        controls = ORACLE.controls(observation, manifest)
        self.assertEqual(len(controls), 10)
        self.assertTrue(all(c["rejected"] for c in controls))

    def test_missing_observation_never_qualifies(self):
        _, manifest = fixture()
        self.assertEqual(ORACLE.verify({}, manifest)["status"], "failed")

    def test_capability_booleans_are_not_a_performance_requirement(self):
        observation, manifest = fixture()
        # smooth=false and powerEfficient=false do not mean decode is broken.
        self.assertEqual(ORACLE.verify(observation, manifest)["issues"], [])
        observation["rows"][0]["capabilities"]["supported"] = False
        self.assertEqual(ORACLE.verify(observation, manifest)["status"], "failed")

    def test_pcm_registry_declaration_is_separate_from_actual_decoding(self):
        observation, manifest = fixture()
        observation["rows"][3]["capabilities"]["supported"] = False
        self.assertEqual(ORACLE.verify(observation, manifest)["issues"], [])
        observation["rows"][3]["decoded"]["rms"] = 0
        self.assertEqual(ORACLE.verify(observation, manifest)["status"], "failed")

    def test_independent_pdf_pixels_and_vertical_order(self):
        actual = ORACLE.pdf_colours(png())
        self.assertGreater(actual["blue"], 500)
        self.assertGreater(actual["yellow"], 500)
        self.assertTrue(actual["correctVerticalOrder"])
        self.assertFalse(ORACLE.pdf_colours(png(swapped=True))["correctVerticalOrder"])
        self.assertEqual(ORACLE.pdf_colours(png(blank=True))["blue"], 0)

    def test_corrupt_screenshot_is_rejected(self):
        with self.assertRaises(ValueError):
            ORACLE.pdf_colours(base64.b64encode(b"not a PNG").decode())

    def test_profiled_transparent_colours_are_refused_before_conversion(self):
        import builtins
        original = builtins.__import__
        def guarded(name, *args, **kwargs):
            if name == "PIL":
                raise AssertionError("Opacity must be checked before ICC conversion")
            return original(name, *args, **kwargs)
        with mock.patch("builtins.__import__", side_effect=guarded), self.assertRaisesRegex(ValueError, "opaque native screenshot"):
            ORACLE.pdf_colours(png(transparent_profiled=True))


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Offline decoder/semantic oracle; no browser launch and no fingerprint list."""
import argparse
import copy
import importlib.util
from io import BytesIO
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("compatibility_png", HERE.parent / "runtime-platform/fixtures/vector-semantics/verify.py")
PNG = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PNG)


def pdf_colours(encoded):
    width, height, pixels = PNG.png_rgba(encoded)
    if width != height or width not in (128, 256):
        raise ValueError("Wrong screenshot crop")
    if any(alpha != 255 for alpha in pixels[3::4]):
        raise ValueError("Expected opaque native screenshot before ICC conversion")
    # Native screenshots may carry Display P3 (observed on the QA Mac). Raw
    # channel values are not sRGB: e.g. its yellow was (255,255,84). Normalize
    # the embedded profile, rather than widening colour thresholds to pass.
    raw = PNG.raw64(encoded)
    pos, profiled = 8, False
    while pos < len(raw):
        length = int.from_bytes(raw[pos:pos + 4], "big")
        profiled |= raw[pos + 4:pos + 8] == b"iCCP"
        pos += length + 12
    if profiled:
        from PIL import Image, ImageCms
        source = Image.open(BytesIO(raw))
        source.load()
        if source.convert("RGBA").tobytes() != pixels:
            raise ValueError("Independent PNG decoders disagree")
        embedded = source.info.get("icc_profile")
        if not embedded:
            raise ValueError("Invalid embedded ICC profile")
        normalized = ImageCms.profileToProfile(source.convert("RGB"),
            ImageCms.ImageCmsProfile(BytesIO(embedded)), ImageCms.createProfile("sRGB"), outputMode="RGB")
        pixels = normalized.convert("RGBA").tobytes()
    blue, yellow, white = [], [], 0
    for index in range(0, len(pixels), 4):
        r, g, b, a = pixels[index:index + 4]
        point = (index // 4 % width, index // 4 // width)
        if a == 255 and r < 30 and g < 30 and b > 225:
            blue.append(point)
        if a == 255 and r > 225 and g > 225 and b < 30:
            yellow.append(point)
        if a == 255 and r > 235 and g > 235 and b > 235:
            white += 1
    return dict(blue=len(blue), yellow=len(yellow),
                white=white, colourSpace="embedded-icc-to-srgb" if profiled else "unprofiled-test-png",
                correctVerticalOrder=bool(blue and yellow and
                    sum(y for x, y in blue) / len(blue) > sum(y for x, y in yellow) / len(yellow)))


def verify(observation, manifest):
    issues = []; checks = 0
    def check(value, name):
        nonlocal checks
        checks += 1
        if not value:
            issues.append(name)
    check(observation.get("kind") == "actual-codec-playback", "observation kind")
    rows = observation.get("rows", [])
    check([r.get("id") for r in rows] == [c["id"] for c in manifest["cases"]], "exact case coverage")
    for c, row in zip(manifest["cases"], rows):
        prefix = c["id"] + ": "
        check(row.get("assetSHA256") == manifest["files"][c["file"]]["sha256"], prefix + "asset")
        check(row.get("status") == "decoded-and-played", prefix + "actual playback")
        check(row.get("canPlayType") in ("maybe", "probably"), prefix + "canPlayType")
        caps = row.get("capabilities", {})
        check(all(type(caps.get(k)) is bool for k in ("supported", "smooth", "powerEfficient")), prefix + "capability result")
        # PCM/WAV is not part of every MediaCapabilities container registry;
        # observe its declaration without equating registry support to decoding.
        check(c["id"] == "pcm" or caps.get("supported") is True, prefix + "declared support")
        check(row.get("playback", {}).get("advanced", 0) >= 0.2, prefix + "time progression")
        if c["kind"] == "video":
            check(row.get("dimensions") == [64, 48], prefix + "dimensions")
            check(row.get("decodedFrames", 0) >= 2, prefix + "decoded frames")
            pixel = row.get("pixel", [])
            check(len(pixel) == 4 and pixel[0] > 225 and pixel[1] < 30 and pixel[2] < 30 and pixel[3] == 255, prefix + "decoded colour")
        else:
            d = row.get("decoded", {})
            check(d.get("sampleRate") == 48000 and d.get("channels") == 1, prefix + "audio configuration")
            check(0.9 <= d.get("seconds", 0) <= 1.1, prefix + "duration")
            check(0.15 <= d.get("rms", 0) <= 0.2, prefix + "audio energy")
            check(430 <= d.get("hertz", 0) <= 450, prefix + "tone frequency")
    check(observation.get("brokenMedia") == "decode-rejected", "corrupt actual media rejected")
    check(observation.get("invalidConfiguration") == "TypeError", "invalid MediaCapabilities configuration")
    return dict(status="passed-scoped-codec-operations" if not issues else "failed", checks=checks, issues=issues)


def controls(observation, manifest):
    """Real observation mutations must be detected; these are offline controls."""
    mutations = {
        "missing-case": lambda x: x["rows"].pop(),
        "declaration-only": lambda x: x["rows"][0].pop("playback", None),
        "no-real-frames": lambda x: x["rows"][0].update(decodedFrames=0),
        "wrong-frame": lambda x: x["rows"][0].update(pixel=[0, 0, 0, 255]),
        "wrong-asset": lambda x: x["rows"][0].update(assetSHA256="0" * 64),
        "silent-audio": lambda x: x["rows"][3]["decoded"].update(rms=0),
        "wrong-tone": lambda x: x["rows"][3]["decoded"].update(hertz=880),
        "ignored-decode-failure": lambda x: x.update(brokenMedia="incorrectly-decoded"),
        "ignored-invalid-config": lambda x: x.update(invalidConfiguration="incorrectly-accepted"),
        "timeout": lambda x: x["rows"][0].update(status="timeout"),
    }
    result = []
    for name, mutate in mutations.items():
        broken = copy.deepcopy(observation); mutate(broken)
        result.append(dict(name=name, rejected=verify(broken, manifest)["status"] == "failed"))
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("observation", type=Path)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--pdf-pixels", action="store_true")
    args = parser.parse_args()
    if args.pdf_pixels:
        print(json.dumps(pdf_colours(args.observation.read_text())))
    else:
        data = json.loads(args.observation.read_bytes()); manifest = json.loads(args.manifest.read_bytes())
        verdict = verify(data, manifest)
        verdict["offlineNegativeControls"] = controls(data, manifest) if verdict["status"] != "failed" else []
        print(json.dumps(verdict, indent=2))
        raise SystemExit(0 if verdict["status"] != "failed" and all(c["rejected"] for c in verdict["offlineNegativeControls"]) else 1)

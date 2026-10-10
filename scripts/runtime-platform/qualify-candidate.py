#!/usr/bin/env python3
"""Resumable headed platform qualification against independent candidate bytes.

Runs one owned browser at a time. Native reference and disabled feature tests
are distinct from manager-configured tests. Successful CLI exit alone is never
accepted as a semantic verdict. Physical display/power/network transitions are
explicitly outside this automated fixture's coverage.
"""
import argparse
import copy
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as file:
        for data in iter(lambda: file.read(1024 * 1024), b""):
            h.update(data)
    return h.hexdigest()


def write_once(path, data):
    encoded = (json.dumps(data, sort_keys=True, indent=2) + "\n").encode()
    path = Path(path)
    if path.exists():
        if path.read_bytes() != encoded:
            raise ValueError("Immutable qualification input changed")
    else:
        with path.open("xb") as file:
            file.write(encoded)
        path.chmod(0o600)


def binding_for(app, manifest):
    document = json.loads(Path(manifest).read_text())
    critical = document["criticalFiles"]
    for entry in critical.values():
        relative = Path(entry["bundlePath"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Invalid candidate path")
        file = app / relative
        if not file.is_file() or file.is_symlink() or digest(file) != entry["sha256"]:
            raise ValueError("Candidate critical bytes do not match manifest")
    runtime = app / "Contents/Resources/NeAntik Browser.app"
    info = plistlib.loads((runtime / "Contents/Info.plist").read_bytes())
    prefix = "Contents/Resources/NeAntik Browser.app/"
    framework = critical["runtimeFramework"]["bundlePath"]
    if not framework.startswith(prefix):
        raise ValueError("Framework outside runtime")
    return runtime, {
        "schemaVersion": 1, "runtimeVersion": info["CFBundleShortVersionString"],
        "runtimeExecutableSHA256": critical["runtimeExecutable"]["sha256"],
        "runtimeFrameworkSHA256": critical["runtimeFramework"]["sha256"],
        "runtimeFrameworkRelativePath": framework[len(prefix):],
        "candidateManifestSHA256": digest(manifest),
        "managerExecutableSHA256": critical["managerExecutable"]["sha256"],
    }


def verdict_passes(report):
    if not isinstance(report, dict):
        return False
    passed = report.get("passed") is True or (
        str(report.get("status", "")).startswith("verified-scoped-") and report.get("issues") == []
    )
    controls = report.get("negativeControls", [])
    return passed and all(item.get("rejected") is True for item in controls)


def capture_binding_matches(document, binding):
    return all(document.get(field) == binding[field] for field in (
        "runtimeVersion", "runtimeFrameworkSHA256"
    )) and document.get("executableSHA256") == binding["runtimeExecutableSHA256"] and \
        document.get("headed") is True and document.get("cleanupVerified") is True and \
        document.get("documentEvidence", {}).get("loaded") is True


def source_binding_matches(document, root):
    proof = document.get("fixtureProvenance", {})
    if proof.get("manifestSHA256") != document.get("fixtureSourceArchive", {}).get("manifestSHA256"):
        return False
    entries = proof.get("files", [])
    if not 1 <= len(entries) <= 32:
        return False
    for entry in entries:
        relative = Path(entry.get("path", ""))
        if relative.is_absolute() or ".." in relative.parts or not entry.get("sha256"):
            return False
        original = root / relative
        archive = root / "fixture-source-archive/blobs" / entry["sha256"]
        if not original.is_file() or not archive.is_file() or original.is_symlink() or archive.is_symlink():
            return False
        if original.stat().st_size != entry.get("bytes") or digest(original) != entry["sha256"] or digest(archive) != entry["sha256"]:
            return False
    encoded = json.dumps(entries, separators=(",", ":"), ensure_ascii=False).encode()
    return hashlib.sha256(encoded).hexdigest() == proof["manifestSHA256"]


def collector_probe(source):
    # Extract current shipped helpers; the archive binds these exact source bytes.
    text = source.read_text()
    hashing = text[text.index("      const fnv ="):text.index("      const localeCore =")]
    bounded = text[text.index("      const boundedNativeObservation ="):text.index("      const permissionState =")]
    fonts = text[text.index("      const fontCandidates ="):text.index("      let clientHints =")]
    rects = text[text.index("      const rectHost ="):text.index("      const fontCandidates =")]
    return """(async()=>{
    HASH BOUNDED
    const observeFonts=async()=>{FONTS return {evidence:fonts,cleaned:!fontHost.isConnected};};
    const observeRects=()=>{RECTS return {first:rectHash,repeat:rectRepeatHash,cleaned:!rectHost.isConnected};};
    const positive=await observeFonts(); const geometry=observeRects();
    const box=Element.prototype.getBoundingClientRect;
    let absent,unstable; let counter=0;
    try {
      Element.prototype.getBoundingClientRect=function(){const r=box.call(this);return this.style.fontFamily.includes('NeAntikAbsentFont')?{width:r.width+1,height:r.height}:r;};
      absent=await observeFonts();
      Element.prototype.getBoundingClientRect=function(){const r=box.call(this);return this.tagName==='SPAN'?{width:r.width+(counter++%2),height:r.height}:r;};
      unstable=await observeFonts();
    } finally {Element.prototype.getBoundingClientRect=box;}
    const load=document.fonts.load; let timeout;
    try {document.fonts.load=()=>new Promise(()=>{});timeout=await observeFonts();}
    finally {document.fonts.load=load;}
    const clients=Element.prototype.getClientRects;const invalidRects=[];
    try {
      for(const values of [[],[{x:NaN,y:0,width:1,height:1,top:0,left:0,right:1,bottom:1}],
        [{x:0,y:0,width:1,height:1,top:0,left:0,right:2,bottom:1}]]){
        Element.prototype.getClientRects=()=>values;invalidRects.push(observeRects());
      }
    } finally {Element.prototype.getClientRects=clients;}
    return {kind:'current-collector-controls',sourceSHA256:'SOURCE',positive,geometry,absent,unstable,timeout,invalidRects};
    })()""".replace("HASH", hashing).replace("BOUNDED", bounded).replace("FONTS", fonts).replace("RECTS", rects).replace("SOURCE", digest(source))


def collector_verdict(data, expected_source):
    import re
    positive = data.get("positive", {})
    geometry = data.get("geometry", {})
    checks = [data.get("sourceSHA256") == expected_source,
              bool(re.fullmatch(r"metrics-v1:[0-9a-f]{8}:fallback-control-pass", positive.get("evidence", ""))),
              positive.get("cleaned") is True,
              bool(re.fullmatch(r"[0-9a-f]{8}", geometry.get("first", ""))),
              geometry.get("first") == geometry.get("repeat"), geometry.get("cleaned") is True]
    controls = [{"name": name, "rejected": data.get(name, {}).get("evidence") == "unavailable" and data.get(name, {}).get("cleaned") is True}
                for name in ("absent", "unstable", "timeout")]
    controls += [{"name": "invalid-rect-" + str(index), "rejected": item.get("first") == "unavailable" and item.get("repeat") == "unavailable" and item.get("cleaned") is True}
                 for index, item in enumerate(data.get("invalidRects", []))]
    return {"passed": all(checks) and len(controls) == 6 and all(c["rejected"] for c in controls),
            "checks": len(checks), "negativeControls": controls}


def media_verdict(data):
    tracks = data.get("tracks", [])
    passed = data.get("kind") == "synthetic-media-capture" and data.get("errors") == [] and \
        data.get("before") == {"camera": "granted", "microphone": "granted"} and \
        sorted(item.get("kind", "") for item in tracks) == ["audio", "video"] and \
        all(item.get("state") == "live" for item in tracks) and \
        data.get("frame", {}).get("presented") is True and data["frame"].get("nonzeroColor") is True and \
        data["frame"].get("width", 0) > 0 and data["frame"].get("height", 0) > 0 and \
        data.get("audio", {}).get("finite") is True and data["audio"].get("frames", 0) > 0 and \
        data["audio"].get("channels") == 1 and data["audio"].get("callbacks", 0) > 0 and \
        data.get("revoked", {}).get("camera") == "denied" and data["revoked"].get("microphone") == "denied" and \
        data["revoked"].get("events", 0) >= 2 and data.get("denied") == {"rejected": True, "error": "NotAllowedError"} and \
        data.get("cleanupVerified") is True
    return {"passed": passed is True}


def checked_media_verdict(data):
    verdict = media_verdict(data)
    controls = []
    for name, mutate in [
        ("missing-frame", lambda x: x.pop("frame", None)),
        ("no-processing", lambda x: x.pop("audio", None)),
        ("wrong-denial", lambda x: x.__setitem__("denied", {"rejected": True, "error": "TypeError"})),
        ("no-revocation-event", lambda x: x.setdefault("revoked", {}).__setitem__("events", 0)),
        ("live-track", lambda x: x.__setitem__("cleanupVerified", False)),
    ]:
        bad = copy.deepcopy(data)
        mutate(bad)
        controls.append({"name": name, "rejected": not media_verdict(bad)["passed"]})
    verdict["negativeControls"] = controls
    return verdict


CASES = [
    ("collector", [1, 9], "current-collector-probe.js", None, "neantik-configured", "run-headed-m156.mjs"),
    ("font-load", [1], "geometry-font-probe.js", "verify-geometry-font.py", "neantik-configured", "run-headed-m156.mjs"),
    ("realms", [2], "context-operations-probe.js", "verify-realm-operations.py", "neantik-configured", "run-headed-m156.mjs"),
    ("drawing", [3, 4, 6], "page-probe.js", "verify.py", "neantik-configured", "run-headed-m156.mjs"),
    ("webgl-read", [5], "webgl-probe.js", "verify-webgl.py", "neantik-configured", "run-headed-m156.mjs"),
    ("webgl-behavior", [5], "webgl-capabilities-probe.js", "verify-webgl-capabilities.py", "neantik-configured", "run-headed-m156.mjs"),
    ("audio-worklet", [6], "audio-complete-probe.js", "verify-audio-complete.py", "neantik-configured", "run-headed-m156.mjs"),
    ("audio-events", [6], "audio-event-probe.js", "verify-audio-events.py", "neantik-configured", "run-headed-m156.mjs"),
    ("audio-lifetime", [6], "audio-lifetime-probe.js", "verify-audio-lifetime.py", "neantik-configured", "run-headed-m156.mjs"),
    ("identity", [7, 13], "identity-probe.js", "verify-identity-m156.py", "neantik-configured", "run-headed-m156.mjs"),
    ("service-worker", [7], "identity-sw-probe.js", "verify-identity-sw-m156.py", "neantik-configured", "run-headed-m156-sw-identity.mjs"),
    ("geometry", [8, 9], "window-geometry-probe.js", "verify-window-geometry-m156.py", "neantik-configured", "run-headed-m156-window.mjs"),
    ("geometry-zoom", [8, 9], "window-geometry-probe.js", "verify-window-geometry-m156.py", "neantik-configured", "run-headed-m156-window.mjs"),
    ("webgpu-policy", [10], "webgpu-observation-probe.js", None, "neantik-configured", "run-headed-m156.mjs"),
    ("webgpu-native", [10], "webgpu-operations-probe.js", "verify-webgpu-operations.mjs", "unconfigured", "run-headed-m156.mjs"),
    ("platform-state", [11, 12, 13], "platform-state-operations-probe.js", "verify-platform-state-operations.mjs", "neantik-configured", "run-headed-m156.mjs"),
    ("voices", [14], "speech-observation-probe.js", None, "neantik-configured", "run-headed-m156.mjs"),
    ("media", [15], "media-capture-probe.js", None, "neantik-configured", "run-headed-m156.mjs"),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--launch-receipt", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--only", choices=[c[0] for c in CASES])
    args = parser.parse_args()
    app = args.app.resolve()
    runtime, binding = binding_for(app, args.manifest)
    args.output.mkdir(mode=0o700, parents=True, exist_ok=True)
    working = args.output / "fixtures"
    if not working.exists():
        shutil.copytree(HERE / "fixtures", working)
    else:
        for source in (HERE / "fixtures").rglob("*"):
            if source.relative_to(HERE / "fixtures").as_posix() == "vector-semantics/speech-observation-probe.js":
                continue  # generated below from current shipped collector
            if source.is_file() and digest(source) != digest(working / source.relative_to(HERE / "fixtures")):
                raise ValueError("Fixture changed; use a new qualification output")
    binding_path = args.output / "binding.json"
    write_once(binding_path, binding)
    launch_path = args.output / "manager-launch-receipt.json"
    launch_receipt = json.loads(args.launch_receipt.read_text())
    if launch_receipt.get("managerPolicySourceSHA256") != digest(ROOT / "Sources/NeAntik/BrowserProcessManager.swift"):
        raise ValueError("Compiled manager launch receipt belongs to different source")
    write_once(launch_path, launch_receipt)
    source = ROOT / "Sources/NeAntik/FingerprintAudit.swift"
    probe_path = working / "vector-semantics/current-collector-probe.js"
    generated = collector_probe(source)
    if probe_path.exists() and probe_path.read_text() != generated:
        raise ValueError("Collector changed; use a new qualification output")
    probe_path.write_text(generated)
    # Other observers are extracted too: no historical helper/hash may stand
    # in for the current shipped Swift collector.
    current_source = source.read_text()
    speech = current_source[current_source.index("      const observeSpeechVoices ="):current_source.index("      const speechObservation =")]
    voice_probe = working / "vector-semantics/speech-observation-probe.js"
    voice_source = "(async()=>{" + speech + "return {kind:'bounded-native-speech-observation',result:await observeSpeechVoices(),sourceSHA256:'" + digest(source) + "'};})()"
    if (working / "vector-semantics/voices-observations.json").exists() and voice_probe.read_text() != voice_source:
        raise ValueError("Observed voice collector changed; use a new qualification output")
    voice_probe.write_text(voice_source)
    env = dict(os.environ, NEANTIK_PLATFORM_BINDING=str(binding_path.resolve()),
               NEANTIK_PLATFORM_LAUNCH_RECEIPT=str(launch_path.resolve()))
    cases = [c for c in CASES if not args.only or c[0] == args.only]
    summaries = []
    vector = working / "vector-semantics"

    def run(command, name, timeout=240):
        log = args.output / (name + ".log")
        with log.open("w") as output:
            result = subprocess.run(command, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
        return result.returncode, log

    # These two operation oracles expose independent fixtures via self-test,
    # rather than mutations of a browser capture. Record them separately.
    for case_name, verifier_name, positives, negatives in [
        ("platform-state", "verify-platform-state-operations.mjs", 2, 20),
        ("webgpu-native", "verify-webgpu-operations.mjs", 1, 11),
    ]:
        if any(c[0] == case_name for c in cases):
            code, log = run(["node", str(vector / verifier_name), "--self-test"], case_name + "-controls")
            control = json.loads(log.read_text().strip())
            if code or control != {"positiveControls": positives, "negativeControls": negatives, "actualBrowser": False}:
                raise ValueError("Independent operation controls failed")
            write_once(args.output / (case_name + "-controls.json"), control)

    # The separate ordinary Chrome control has its own binding; it does not
    # substitute for the configured candidate's identity or operation checks.
    if any(c[0] == "identity" for c in cases):
        reference = vector / "m156-control-fresh-chrome-identity-observations.json"
        if not reference.exists():
            chrome = Path("/Applications/Google Chrome.app")
            info = plistlib.loads((chrome / "Contents/Info.plist").read_bytes())
            version = info["CFBundleShortVersionString"]
            if version != "155.0.8059.39":
                raise ValueError("Ordinary Chrome reference version changed; review upstream hint policy")
            executable = chrome / "Contents/MacOS" / info["CFBundleExecutable"]
            framework = "Contents/Frameworks/Google Chrome Framework.framework/Versions/" + version + "/Google Chrome Framework"
            reference_binding = {"schemaVersion": 1, "runtimeVersion": version,
                "runtimeExecutableSHA256": digest(executable), "runtimeFrameworkSHA256": digest(chrome / framework),
                "runtimeFrameworkRelativePath": framework}
            reference_path = args.output / "chrome-reference-binding.json"
            write_once(reference_path, reference_binding)
            env["NEANTIK_PLATFORM_BINDING"] = str(reference_path.resolve())
            code, _ = run(["node", str(vector / "run-headed-m156.mjs"), str(chrome), "m156-control-fresh-chrome-identity", "unconfigured", digest(executable), "-", "identity-probe.js"], "ordinary-chrome")
            env["NEANTIK_PLATFORM_BINDING"] = str(binding_path.resolve())
            if code: raise ValueError("Ordinary Chrome control failed; inspect private log")
    for name, rows, probe, verifier, mode, runner in cases:
        observation = vector / (name + "-observations.json")
        if not observation.exists():
            extra = "-"
            if name in ("geometry", "geometry-zoom"):
                zoom = args.output / (name + "-zoom.json")
                write_once(zoom, {"zoomFactor": 1.25 if name == "geometry-zoom" else 1})
                extra = str(zoom.resolve())
            code, _ = run(["node", str(vector / runner), str(runtime), name, mode,
                binding["runtimeExecutableSHA256"], extra, probe], name + "-run")
            if code:
                summaries.append({"case": name, "rows": rows, "passed": False, "reason": "Browser fixture failed; inspect private log"})
                print(name + ": fixture FAIL", flush=True); continue
        document = json.loads(observation.read_text())
        if not capture_binding_matches(document, binding) or document.get("candidateBindingSHA256") != digest(binding_path) or document.get("mode") != mode or not source_binding_matches(document, working):
            raise ValueError("Observation belongs to different candidate or lacks lifecycle/document proof")
        if verifier:
            code, log = run(["node" if verifier.endswith(".mjs") else sys.executable,
                str(vector / verifier), str(observation), "--negative-controls"], name + "-verify")
            lines = log.read_text().splitlines()
            reports = []
            for line in lines:
                try: reports.append(json.loads(line))
                except ValueError: pass
            verdict = reports[-1] if reports else {"passed": False, "reason": "Verifier returned no JSON verdict"}
            passed = code == 0 and verdict_passes(verdict)
        else:
            data = document["data"]
            if name == "collector": verdict = collector_verdict(data, digest(source))
            elif name == "media": verdict = checked_media_verdict(data)
            elif name == "webgpu-policy":
                verdict = {"passed": data.get("observation") in ("api-absent", "adapter-null"), "scope": "disabled configured WebGPU policy"}
            else:
                observed = data.get("result", {})
                count = observed.get("count")
                good_count = isinstance(count, str) and count.isdigit() and 0 <= int(count) <= 256
                verdict = {"passed": data.get("sourceSHA256") == digest(source) and (
                    observed.get("observation") == "observed" and observed.get("availability") == "available" and good_count or
                    observed.get("observation") == "unavailable" and observed.get("availability") == "unavailable" and count == "unavailable" or
                    observed.get("observation") == "timeout" and observed.get("availability") == "available" and count == "unavailable"),
                    "scope": "bounded native voices; loading timeout is explicitly inconclusive; no names or IDs"}
            passed = verdict_passes(verdict)
        write_once(args.output / (name + "-verdict.json"), verdict)
        summaries.append({"case": name, "rows": rows, "passed": passed, "observationSHA256": digest(observation),
            "verdictSHA256": digest(args.output / (name + "-verdict.json"))})
        print(name + (": PASS" if passed else ": FAIL"), flush=True)
    binding_for(app, args.manifest)
    summary = {"schemaVersion": 1, "scope": "headed signed platform operations, first15 automated coverage",
        "candidateBindingSHA256": digest(binding_path), "cases": summaries,
        "passed": len(summaries) == len(cases) and all(c["passed"] for c in summaries),
        "limitations": ["No second physical display", "No physical power or network change events",
            "HTTP loopback identity; external HTTPS route is a separate gate", "Not complete production/1.0 qualification"]}
    write_once(args.output / ("summary-" + (args.only or "all") + ".json"), summary)
    return 0 if summary["passed"] else 2


if __name__ == "__main__":
    sys.exit(main())

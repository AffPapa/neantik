#!/usr/bin/env python3
"""Force one restart of the attested Networking child after fixture phase B2."""

import argparse
import json
from importlib import import_module
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import time

QA = import_module("prepare-webkit-ab-isolation-qa")
CORE = import_module("collect-manager-dns")
CRASH = import_module("collect-manager-crash")


def restart(plan_path: Path) -> dict:
    CORE.require(plan_path.name == "run-plan.json" and plan_path.parent.parent == QA.PRIVATE_TMP
                 and plan_path.parent.name.startswith("neantik-webkit-ab-stage-")
                 and plan_path.resolve(strict=True) == plan_path, "invalid-owned-webkit-run-plan")
    plan = CORE.load(plan_path)
    root = Path(plan["root"])
    CORE.require(re.fullmatch(r"/private/tmp/neantik-dev-fixture\.[A-Za-z0-9_-]+", str(root)) is not None
                 and plan["stage"] == str(plan_path.parent)
                 and root.resolve(strict=True) == root, "invalid-owned-webkit-fixture-root")
    entry = root.lstat()
    CORE.require(stat.S_ISDIR(entry.st_mode) and stat.S_IMODE(entry.st_mode) == 0o700
                 and entry.st_uid == os.getuid(), "unsafe-owned-webkit-fixture-root")
    binding = CORE.load(root / "candidate-binding.json")
    digest = binding["candidateSHA256"]
    CORE.require(isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest) is not None
                 and QA.successor_launch_consumed(root, digest), "exact-owned-webkit-launch-required")
    phase = CORE.load(root / "phase-results.json")
    rows = phase["phases"]
    CORE.require(phase["candidateSHA256"] == digest and len(rows) == 3
                 and [row["phase"] for row in rows] == ["A1", "B1", "B2"]
                 and all(row["classification"] == "pass" for row in rows)
                 and rows[2]["turnBoundary"] == "PASS", "restart-requires-passed-B2")
    app = Path(binding["candidateApp"])
    CORE.require(app.name == "NeAntik.app" and app.parent.parent == QA.PRIVATE_TMP
                 and app.parent.name.startswith("neantik-owned-webkit-successor-qa-")
                 and app.resolve(strict=True) == app, "invalid-owned-webkit-candidate-app")
    receipt = CORE.read_private(app.parent / "stage.json", limit=16384)
    candidate = json.loads(receipt)
    CORE.require(CORE.sha(receipt) == binding["candidateReceiptSHA256"]
                 and candidate["root"] == str(root) and candidate["app"] == str(app)
                 and candidate["sha256"] == digest and candidate["releaseQualified"] is False
                 and candidate["managerSignedSHA256"] == binding["managerSignedSHA256"],
                 "owned-webkit-candidate-receipt-mismatch")
    requirement = ('anchor apple generic and identifier "app.neantik.desktop.dev" '
                   'and certificate leaf[subject.OU] = "H6VGU2M6JD" '
                   'and certificate leaf[field.1.2.840.113635.100.6.1.13] exists')
    signature = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict",
                                "-R", "=" + requirement, str(app)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    CORE.require(signature.returncode == 0, "owned-webkit-candidate-signature-invalid")
    original = rows[2]["networkingOwner"]
    CORE.require(QA.attested_networking_owner(plan, binding) == original,
                 "owned-webkit-networking-generation-changed")
    intent = root / "networking-restart-intent.json"
    result = root / "networking-restart-result.json"
    CORE.require(not os.path.lexists(result), "owned-webkit-networking-restart-already-attempted")
    CORE.write_new(intent, {"candidateSHA256": digest, "networkingOwner": original,
                            "signal": "SIGKILL"})
    # Re-attest path, live signature and start time after writing the intent.
    CORE.require(QA.attested_networking_owner(plan, binding) == original,
                 "owned-webkit-networking-final-custody-changed")
    os.kill(original["pid"], signal.SIGKILL)
    deadline = time.monotonic() + 5
    while not CRASH.generation_absent(original) and time.monotonic() < deadline:
        time.sleep(0.05)
    exited = CRASH.generation_absent(original)
    value = {"candidateSHA256": digest, "previousGeneration": original["generation"],
             "signalIssued": True, "previousGenerationExited": exited}
    CORE.write_new(result, value)
    CORE.require(exited, "owned-webkit-networking-exit-unconfirmed")
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-plan", type=Path, required=True)
    args = parser.parse_args()
    try:
        value = restart(args.run_plan)
    except (KeyError, OSError, TypeError, ValueError) as error:
        parser.exit(1, f"Networking restart refused: {error}\n")
    print(CORE.canonical(value).decode())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

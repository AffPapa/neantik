#!/usr/bin/env python3
"""Seal one disposable, non-distributable owned-WebKit successor candidate."""

import argparse
import hashlib
from importlib import import_module
import json
import os
from pathlib import Path
import plistlib
import re
import tempfile


def seal(source: Path, manager_sha: str, root: Path, host: Path, frameworks: Path,
         manifest: Path, manifest_sha: str) -> Path:
    qa = import_module("prepare-owned-webkit-dev-qa")
    packager = import_module("package-webkit-host")
    pins = import_module("verify-webkit-host-pin")
    import webkit_network_sandbox_pin as sandbox_pin

    qa.require(re.fullmatch(r"/private/tmp/neantik-dev-fixture\.[A-Za-z0-9_-]+", str(root)) is not None,
               "successor-requires-disposable-dev-root")
    seed = qa.validate_fixture(root)
    anchor, origin = qa.fixture_tls_scope(root)
    info = packager.read_info(source, allow_development_qa=True)
    qa.require(info.get("CFBundleIdentifier") == qa.APP_ID
               and info.get("CFBundleExecutable") == "NeAntik"
               and info.get("NeAntikEngineScope") == "chromium-system-webkit-dev"
               and info.get("NeAntikBrowserDataBackupEnabled", False) is False
               and "NeAntikPrivateQARuntimeVariant" not in info
               and not os.path.lexists(source / "Contents/embedded.provisionprofile")
               and not os.path.lexists(source / qa.HOST_RELATIVE), "unexpected-source-dev-app")
    manager_relative = Path("Contents/MacOS/NeAntik")
    manager = source / manager_relative
    packager.verify_host_binary(manager)
    manager_bytes = manager.read_bytes()
    qa.require(hashlib.sha256(manager_bytes).hexdigest() == manager_sha
               and b"DevelopmentFixtureKeychain" in manager_bytes
               and b"webkit-broker-counts-" in manager_bytes, "unexpected-debug-manager-bytes")
    qa.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(source)])

    stage = Path(tempfile.mkdtemp(prefix="neantik-owned-webkit-successor-qa-", dir="/private/tmp"))
    app = stage / "NeAntik.app"
    qa.run(["/usr/bin/ditto", str(source), str(app)], timeout=600)
    qa.require(qa.sha256(app / manager_relative) == manager_sha, "copied-manager-bytes-changed")
    info["NeAntikDevelopmentFixtureRoot"] = str(root)
    info["NeAntikDeveloperTeamIdentifier"] = qa.TEAM
    packager.install_info_atomically(app, info)
    bundle = packager.package(app, host, frameworks, qa.IDENTITY, allow_development_qa=True,
                              qa_tls_anchor_der=anchor, qa_tls_origins=[origin],
                              private_successor=(manifest, manifest_sha))
    qa.run(["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp=none",
            "--sign", qa.IDENTITY, str(app)], timeout=300)
    qa.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], timeout=300)
    entitlements = qa.run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)]).stdout
    qa.require(qa.signing_team(app) == qa.TEAM and (not entitlements or plistlib.loads(entitlements.encode()) == {})
               and not os.path.lexists(app / "Contents/embedded.provisionprofile"), "dev-seal-identity-drift")
    pin = pins.verify(app, require_network_sandbox_pin=True)
    qa.require(pin.get("status") == "PASS" and qa.validate_fixture(root) == seed, "sealed-candidate-or-seed-drift")
    host_info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    binding = bundle / "Contents/Resources/NeAntikRuntimeEvidence/NeAntikRuntimeImageBinding.json"

    archive = stage / "NeAntik-private-owned-webkit-qa.zip"
    qa.run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
            str(app), str(archive)], timeout=900)
    receipt = stage / "stage.json"
    qa.write_private_json(receipt, {
        "stage": str(stage), "root": str(root), "app": str(app), "archive": str(archive),
        "sha256": qa.sha256(archive), "profileSeedSHA256": seed,
        "managerSignedSHA256": qa.sha256(app / manager_relative),
        "hostSHA256": qa.sha256(bundle / "Contents/MacOS/NeAntikWebKitHost"),
        "qaRuntimeVariant": packager.PRIVATE_SUCCESSOR_VARIANT,
        "qaSuccessorManifestSHA256": manifest_sha,
        "qaNetworkSandboxSHA256": host_info[sandbox_pin.PIN_KEY],
        "qaRuntimeBindingSHA256": qa.sha256(binding),
        "qaTrustAnchorSHA256": hashlib.sha256(anchor).hexdigest(), "qaTrustOrigin": origin,
        "disposableDebugFixture": True, "releaseQualified": False,
    })
    return receipt


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dev-app", type=Path, required=True)
    parser.add_argument("--manager-sha256", required=True)
    parser.add_argument("--fixture-root", type=Path, required=True)
    parser.add_argument("--host-binary", type=Path, required=True)
    parser.add_argument("--runtime-frameworks", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--manifest-sha256", required=True)
    args = parser.parse_args()
    try:
        receipt = seal(args.source_dev_app, args.manager_sha256, args.fixture_root, args.host_binary,
                       args.runtime_frameworks, args.manifest, args.manifest_sha256)
    except (ValueError, OSError) as error:
        parser.exit(1, f"Successor QA sealing refused: {error}\n")
    print(json.dumps({"receipt": str(receipt), "status": "sealed-private-qa; not launched"}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

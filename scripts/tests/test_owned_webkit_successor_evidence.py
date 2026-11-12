import copy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import owned_webkit_successor_evidence as evidence


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class SuccessorEvidenceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.source = self.root / "Source"
        self.source.mkdir()
        self.git("init", "-q", "--object-format=sha1")
        self.git("config", "user.name", "NeAntik fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        (self.source / "engine.txt").write_text("original\n")
        self.git("add", "engine.txt")
        self.git("commit", "-qm", "upstream")
        base, base_tree = self.git("rev-parse", "HEAD", "HEAD^{tree}").decode().splitlines()
        (self.source / "engine.txt").write_text("successor\n")
        self.git("commit", "-qam", "successor")
        head, tree = self.git("rev-parse", "HEAD", "HEAD^{tree}").decode().splitlines()
        patch = self.git("diff", "--binary", "--full-index", base, head, "--")
        self.frameworks = self.root / "Frameworks"
        self.image = self.frameworks / evidence.WEBKIT_IMAGE
        self.image.parent.mkdir(parents=True)
        self.sandbox_path = self.frameworks / evidence.sandbox_pin.RELATIVE_PATH
        self.sandbox_path.parent.mkdir()
        self.sandbox_path.write_bytes(b"patched sandbox")
        self.image.write_bytes(bytes.fromhex("cffaedfe") + b"signed content")
        self.base_policy = {
            "path": evidence.sandbox_pin.RELATIVE_PATH.as_posix(),
            "policyRevision": 13, "relayPort": 45100, "baseSHA256": sha(b"base sandbox"),
        }
        self.stage = {
            "status": "staged-pre-sign-only", "upstreamCommit": base,
            "signingRequired": True, "launchQualified": False,
            "machOCount": 1, "machOSHA256": {evidence.WEBKIT_IMAGE: sha(b"unsigned image")},
            "networkSandbox": self.base_policy | {
                "patchedSHA256": sha(self.sandbox_path.read_bytes()),
                "removedInheritedNetworkStarGrant": True,
                "removedDelegatedSystemNetworkInvocation": True,
                "removedNetworkServiceProxyTokenGrant": True,
            },
        }
        stage_ref = self.ref("stage.json", self.stage)
        self.notice = self.ref("notice.txt", b"Exact reviewed fixture notice\n")
        self.inventory = {
            "schemaVersion": 1, "scope": "local-corresponding-source-dev-qa",
            "patchedCommit": head, "patchedTree": tree, "stageReceiptSHA256": stage_ref["sha256"],
            "notices": {"Source/notice.txt": self.notice},
        }
        self.binding = {
            "schemaVersion": 1, "status": "recipient-signed-runtime-image-binding", "imageCount": 1,
            "images": [{"path": evidence.WEBKIT_IMAGE,
                        "sourceInputSHA256": self.stage["machOSHA256"][evidence.WEBKIT_IMAGE],
                        "relocatedSHA256": sha(b"relocated image"),
                        "recipientSignedSHA256": sha(self.image.read_bytes()),
                        "rpathChange": {"remove": [], "add": None}}],
        }
        self.manifest = {
            "schemaVersion": 1, "scope": "private-owned-webkit-dev-qa",
            "source": {"checkout": str(self.source), "upstreamCommit": base, "upstreamTree": base_tree,
                       "patchedCommit": head, "patchedTree": tree, "patch": self.ref("source.patch", patch)},
            "stagingManifest": self.ref("staging.json", {"upstream": {"commit": base, "repository": "WebKit/WebKit"},
                                                         "networkSandbox": self.base_policy}),
            "stageReceipt": stage_ref, "qaInventory": self.ref("inventory.json", self.inventory),
            "signedRuntimeImageBinding": self.ref("binding.json", self.binding),
        }

    def git(self, *args):
        return subprocess.check_output(["/usr/bin/git", "-C", str(self.source), *args], stderr=subprocess.DEVNULL)

    def ref(self, name, data):
        if not isinstance(data, bytes):
            data = json.dumps(data, sort_keys=True).encode()
        path = self.root / name
        path.write_bytes(data)
        return {"path": str(path), "sha256": sha(data)}

    def verify(self, runtime=None):
        pin = self.ref("manifest.json", self.manifest)
        return evidence.verify(Path(pin["path"]), pin["sha256"], runtime or self.frameworks)

    def test_verifies_frozen_inputs_and_independently_copied_runtime(self):
        copied_runtime = self.root / "copied" / "Frameworks"
        shutil.copytree(self.frameworks, copied_runtime)
        result = self.verify(copied_runtime)
        self.assertEqual(result["networkSandboxSHA256"], self.stage["networkSandbox"]["patchedSHA256"])
        self.assertEqual(result["signedRuntimeImageBindingSHA256"], self.manifest["signedRuntimeImageBinding"]["sha256"])
        self.assertEqual(result["noticeFiles"], {"Source/notice.txt": Path(self.notice["path"])})
        self.assertEqual(result["noticeSHA256"], {"Source/notice.txt": self.notice["sha256"]})
        self.assertFalse(result["releaseQualified"])

    def test_refuses_wrong_manifest_digest_and_duplicate_json_key(self):
        pin = self.ref("manifest.json", self.manifest)
        with self.assertRaisesRegex(evidence.EvidenceError, "pinned evidence bytes changed"):
            evidence.verify(Path(pin["path"]), "1" * 64, self.frameworks)
        pin = self.ref("duplicate.json", b'{"scope":"dev","scope":"release"}')
        with self.assertRaisesRegex(evidence.EvidenceError, "duplicate evidence JSON key"):
            evidence.verify(Path(pin["path"]), pin["sha256"], self.frameworks)

    def test_refuses_dirty_checkout(self):
        (self.source / "engine.txt").write_text("modified fixture\n")
        with self.assertRaisesRegex(evidence.EvidenceError, "source checkout has changes"):
            self.verify()

    def test_refuses_pinned_patch_that_does_not_match_frozen_git_tree(self):
        self.manifest["source"]["patch"] = self.ref("other.patch", b"valid hash for the wrong bytes")
        with self.assertRaisesRegex(evidence.EvidenceError, "patch differs from the Git tree delta"):
            self.verify()

    def test_refuses_notice_change_and_destination_alias(self):
        Path(self.notice["path"]).write_text("changed notice")
        with self.assertRaisesRegex(evidence.EvidenceError, "pinned evidence bytes changed"):
            self.verify()
        Path(self.notice["path"]).write_bytes(b"Exact reviewed fixture notice\n")
        self.inventory["notices"]["source/NOTICE.txt"] = self.notice
        self.manifest["qaInventory"] = self.ref("inventory.json", self.inventory)
        with self.assertRaisesRegex(evidence.EvidenceError, "colliding QA notice destinations"):
            self.verify()

    def test_refuses_evidence_through_symlink(self):
        alias = self.root / "alias.txt"
        alias.symlink_to(Path(self.notice["path"]))
        self.notice["path"] = str(alias)
        self.manifest["qaInventory"] = self.ref("inventory.json", self.inventory)
        with self.assertRaisesRegex(evidence.EvidenceError, "canonical and physical"):
            self.verify()

    def test_refuses_changed_sandbox_and_inconsistent_stage(self):
        self.sandbox_path.write_text("wrong sandbox")
        with self.assertRaises(evidence.EvidenceError):
            self.verify()
        stage = copy.deepcopy(self.stage)
        stage["networkSandbox"]["relayPort"] += 1
        self.manifest["stageReceipt"] = self.ref("stage.json", stage)
        with self.assertRaisesRegex(evidence.EvidenceError, "reviewed WebKit staging policy mismatch"):
            self.verify()

    def test_refuses_changed_signed_image_and_unbound_macho(self):
        original = self.image.read_bytes()
        self.image.write_bytes(original + b"changed")
        with self.assertRaisesRegex(evidence.EvidenceError, "signed WebKit image bytes changed"):
            self.verify()
        self.image.write_bytes(original)
        (self.frameworks / "Extra.dylib").write_bytes(original)
        with self.assertRaisesRegex(evidence.EvidenceError, "unbound Mach-O"):
            self.verify()

    def test_refuses_binding_with_other_stage_bytes(self):
        self.binding["images"][0]["sourceInputSHA256"] = sha(b"other staging run")
        self.manifest["signedRuntimeImageBinding"] = self.ref("binding.json", self.binding)
        with self.assertRaisesRegex(evidence.EvidenceError, "differs from staging receipt"):
            self.verify()


if __name__ == "__main__":
    unittest.main()

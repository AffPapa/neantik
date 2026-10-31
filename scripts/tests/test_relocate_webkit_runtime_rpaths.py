from __future__ import annotations

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "relocate-webkit-runtime-rpaths.py"
SPEC = importlib.util.spec_from_file_location("relocate_webkit_runtime_rpaths", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RelocateWebKitRPathTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "Frameworks"
        image = self.root / "WebKit.framework/Versions/A/WebKit"
        image.parent.mkdir(parents=True)
        image.write_bytes(bytes.fromhex("cffaedfe") + b"test")
        self.image = image
        local_target = self.root / "WebCore.framework/Versions/A/WebCore"
        local_target.parent.mkdir(parents=True)
        local_target.write_bytes(b"fixture")
        self.rpaths = [
            "/Applications/Xcode.app/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx",
            "/private/tmp/build/Release",
            "/usr/lib/swift",
        ]
        self.load_name = "@rpath/WebCore.framework/Versions/A/WebCore"
        self.commands = []
        self.signed = "Signature=adhoc\nTeamIdentifier=not set\n"

    def tearDown(self):
        self.temp.cleanup()

    def fake_run(self, args, **kwargs):
        self.commands.append(args)
        if args[1:3] == ["-l", str(self.image)]:
            text = "".join(
                f"Load command {i}\n cmd LC_RPATH\n path {r} (offset 12)\n"
                for i, r in enumerate(self.rpaths)
            )
            return subprocess.CompletedProcess(args, 0, text, "")
        if args[1:3] == ["-L", str(self.image)]:
            return subprocess.CompletedProcess(args, 0,
                f"{self.image}:\n\t{self.load_name} (compatibility version 1.0.0)\n", "")
        if args[1] == "-delete_rpath":
            self.rpaths.remove(args[2])
            return subprocess.CompletedProcess(args, 0, "", "")
        if args[1] == "-add_rpath":
            self.rpaths.append(args[2])
            return subprocess.CompletedProcess(args, 0, "", "")
        raise AssertionError(args)

    def test_dry_run_reports_relocations_without_mutating(self):
        with patch.object(MODULE, "run", side_effect=self.fake_run):
            root, plan = MODULE.inspect(self.root)
        self.assertEqual(root, self.root.resolve())
        self.assertEqual(len(plan), 1)
        self.assertEqual(len(plan[0]["remove"]), 2)
        self.assertEqual(plan[0]["add"], "@loader_path/../../..")
        self.assertEqual(len(self.rpaths), 3)
        self.assertFalse(any("install_name_tool" in str(x) for x in self.commands))

    def test_apply_removes_build_paths_and_adds_loader_relative_runtime_path(self):
        with patch.object(MODULE, "run", side_effect=self.fake_run), \
             patch.object(MODULE.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", self.signed)):
            root, plan = MODULE.inspect(self.root)
            MODULE.apply(self.root, plan, root)
        self.assertEqual(self.rpaths, ["/usr/lib/swift", "@loader_path/../../.."])

    def test_apply_refuses_developer_id_signature_before_any_mutation(self):
        developer_id = "Authority=Developer ID Application: Example\nTeamIdentifier=TEAM123\n"
        with patch.object(MODULE, "run", side_effect=self.fake_run), \
             patch.object(MODULE.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", developer_id)):
            root, plan = MODULE.inspect(self.root)
            with self.assertRaisesRegex(MODULE.ContractError, "Refusing to mutate a signed"):
                MODULE.apply(self.root, plan, root)
        self.assertEqual(len(self.rpaths), 3)

    def test_rejects_symlink_that_escapes_staging_root(self):
        outside = Path(self.temp.name) / "outside"
        outside.write_text("fixture")
        (self.root / "escape").symlink_to(outside)
        with self.assertRaisesRegex(MODULE.ContractError, "symlink escaping"):
            MODULE.require_frameworks_root(self.root)

    def test_rejects_loader_relative_rpath_that_escapes_staging_root(self):
        self.rpaths = ["@loader_path/../../../../outside"]
        with patch.object(MODULE, "run", side_effect=self.fake_run):
            with self.assertRaisesRegex(MODULE.ContractError, "RPATH escapes"):
                MODULE.inspect(self.root)

    def test_existing_loader_path_must_resolve_the_bundled_dependency(self):
        self.rpaths = ["@loader_path"]
        with patch.object(MODULE, "run", side_effect=self.fake_run):
            _, plan = MODULE.inspect(self.root)
        self.assertEqual(len(plan), 1)
        self.assertEqual(plan[0]["add"], "@loader_path/../../..")

    def test_nested_webkit_swift_image_gets_framework_root_search_path(self):
        self.image.unlink()
        nested = self.root / "WebKit.framework/Versions/A/Frameworks/libWebKitSwift.dylib"
        nested.parent.mkdir(parents=True)
        nested.write_bytes(bytes.fromhex("cffaedfe") + b"test")
        self.image = nested
        self.rpaths = ["/usr/lib/swift", "@loader_path"]
        with patch.object(MODULE, "run", side_effect=self.fake_run):
            _, plan = MODULE.inspect(self.root)
        nested_plan = next(item for item in plan if item["image"].endswith("libWebKitSwift.dylib"))
        self.assertEqual(nested_plan["add"], "@loader_path/../../../..")

    def test_unstaged_non_system_dependency_is_refused(self):
        self.rpaths = ["@loader_path"]
        self.load_name = "@rpath/Missing.framework/Versions/A/Missing"
        with patch.object(MODULE, "run", side_effect=self.fake_run):
            with self.assertRaisesRegex(MODULE.ContractError, "not present in staging"):
                MODULE.inspect(self.root)


if __name__ == "__main__":
    unittest.main()

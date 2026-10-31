#!/usr/bin/env python3
"""Embed the pinned production WebKit runtime into an owned release candidate.

The manager app must be a disposable, production-ID release candidate. This
helper signs it once so the runtime re-signer can authenticate its team, stages
and signs the pinned runtime, then packages the separately linked production
host and hash-checked notices. The caller signs the final manager again after
this helper updates the outer Info.plist and bundle contents.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
EXPECTED_COMMIT = "43d5b8d85e2e5eed41d7ff8a79da831bf405be6c"
EXPECTED_PATCH_SHA256 = "b33b9320bd8f3bae56eadebc738fe91d40f0cf77e89fd2885bf28679d2af0735"
SOURCE_CROSSWALK = ROOT / "docs/evidence/webkit-v20-source-license-crosswalk-20261024.json"
SOURCE_CROSSWALK_SHA256 = "a4855fed2d0f33b31c791440538dbc481b0176665268e9dd57dbdbc9c23d9191"
SOURCE_RECOVERY = ROOT / "docs/evidence/webkit-v20-source-recovery-20261025.json"
SOURCE_ARCHIVE = ROOT / "artifacts/neantik/webkit-v20-source-20261025/WebKit-43d5b8d85e2e5eed41d7ff8a79da831bf405be6c.tar.zst"
SOURCE_ARCHIVE_SHA256 = "658ca48ecfdaa341991bc9cd773a0aa394dabe90ccd1851021433fbd9e72df9f"
SOURCE_TREE = "86b6ee8faf130e81a149280914e4ea5718f60129"
BUILD_RECEIPT_SHA256 = "804a60911bf67912d8f17665958f88051b3085a175f145db0fd76fa7ea23bd9c"
V135_BUILD_RECEIPT_SHA256 = "a491a638ee081d08e330a7a100fb4c738361b066be5bcdb7226b1bc19132ecb4"
V36_PATCH_SHA256 = "0ade0fcd5dd315677d182a86c3d37ea7582dc63457e5c6870df2040f7f182b06"
V377_TEXT_EXTRACTION_PATCH_SHA256 = "a3a8e43188e6f0fcd3a603e0f3e6a814283da6f56a268f206b10f7fc97416ee2"
V381_CORE_PREDICTION_PATCH_SHA256 = "e2aea7ebc6fba39295e4f4cbdbef157afcae34db252c98d76ae60ffab2cb8d83"
V382_FILTERED_MODEL_SCOPE_PATCH_SHA256 = "5889129ffef355e29e4db9ca5d5ca47f2865e030523c6f4de9fdc5ef869cfdf6"
V468_BUILD_RECEIPT_PATH = Path("evidence/V466-STABILIZED-BUILD-RECEIPT.json")
V468_BUILD_RECEIPT_SHA256 = "93bb73b7d22905e8c46cab88b9f57a6e5804c2be7f259131bd4a48a66ad886df"
V468_LOCAL_BUILD_RECEIPT = ROOT / "docs/evidence/v468-build-bindings/V466-STABILIZED-BUILD-RECEIPT.json"
V434_WEBGPU_CORRECTION_PATH = Path("evidence/WEBGPU-V423-METADATA-CORRECTION.json")
V434_WEBGPU_CORRECTION_SHA256 = "cffb1d4177966bb957a581320191a8da99ddabece92833a2db9d7e8da8bf0fd4"
V438_JSC_REVIEW_PATH = Path("evidence/JSC-HEADERLESS-INPUTS-REVIEW-v438.json")
V438_JSC_REVIEW_SHA256 = "be108c5241f09319bfdfcb77bf3ac8c79189710037e2f037b22a3b63619486aa"
V438_JSC_REVIEW_SOURCE = ROOT / "docs/evidence/v438-runtime-notice-bindings/JSC-HEADERLESS-INPUTS-REVIEW-v438.json"
V423_WEBGPU_RECEIPT_SHA256 = "4b73031e706c2d8beedfc0c902470ae15d76b6af0055076576464a88fcafecd7"
V423_WEBGPU_OUTPUT_SHA256 = "d1c3b7c455a39dd6decac116b87616bd8e392407cb45b542a45b69c109577c84"
IDENTITY_SHA1 = "474F7C78F33EE324C24F6F5AE0443EB713E85E60"
PRODUCTION_BUNDLE_ID = "app.neantik.desktop"
STAGING_MANIFEST = ROOT / "runtime/webkit-production-staging-v4.json"
PATCH = ROOT / "docs/evidence/third-party/webkit-v16-relink-candidate-20261020/webkit-v20-source-modifications.patch"
V36_PATCH_RELATIVE = Path("patches/webkit-empty-webkit-infoplist-strings-exclusion-v36.patch")
BUILD_TARGETS = frozenset({
    "JavaScriptCore.framework/Versions/A/JavaScriptCore",
    "WebGPU.framework/Versions/A/WebGPU",
    "libANGLE-shared.dylib",
    "libwebrtc.dylib",
    "WebCore.framework/Versions/A/WebCore",
    "WebKitLegacy.framework/Versions/A/WebKitLegacy",
    "WebInspectorUI.framework/Versions/A/WebInspectorUI",
    "WebKit.framework/Versions/A/WebKit",
    "WebKit.framework/Versions/A/XPCServices/app.neantik.desktop.webkit.GPU.xpc/Contents/MacOS/app.neantik.desktop.webkit.GPU.Development",
    "WebKit.framework/Versions/A/XPCServices/app.neantik.desktop.webkit.WebContent.xpc/Contents/MacOS/app.neantik.desktop.webkit.WebContent.Development",
    "WebKit.framework/Versions/A/XPCServices/app.neantik.desktop.webkit.Networking.xpc/Contents/MacOS/app.neantik.desktop.webkit.Networking.Development",
    "WebKit.framework/Versions/A/XPCServices/app.neantik.desktop.webkit.WebContent.CaptivePortal.xpc/Contents/MacOS/app.neantik.desktop.webkit.WebContent.CaptivePortal.Development",
    "WebKit.framework/Versions/A/XPCServices/app.neantik.desktop.webkit.WebContent.EnhancedSecurity.xpc/Contents/MacOS/app.neantik.desktop.webkit.WebContent.EnhancedSecurity.Development",
    "libWebKitSwift.dylib",
})


class PackageError(RuntimeError):
    pass


def production_build_number() -> int:
    """Read the build currently declared by the production release source."""
    try:
        info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
        version = int(info.get("CFBundleVersion", ""))
    except (OSError, plistlib.InvalidFileException, AttributeError, TypeError, ValueError) as error:
        raise PackageError("production source build number is unavailable") from error
    if info.get("CFBundleShortVersionString") != "1.0.0" or version < 1:
        raise PackageError("production source version/build metadata is invalid")
    return version


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_v434_webgpu_correction(source_offer_root: Path, expected_manifest_sha256: str) -> None:
    """Require the immutable V434 correction when an offer selects the V423 output."""
    manifest_path = source_offer_root / "manifest.json"
    if (source_offer_root.is_symlink() or not source_offer_root.is_dir()
            or manifest_path.is_symlink() or not manifest_path.is_file()
            or not isinstance(expected_manifest_sha256, str)
            or not re.fullmatch(r"[0-9a-f]{64}", expected_manifest_sha256)
            or sha256(manifest_path) != expected_manifest_sha256):
        raise PackageError("WebGPU correction offer manifest is not bound")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        relink = manifest.get("currentWebGPUV423TargetRelink")
        if relink is None:
            return
        correction = manifest["currentWebGPUV434MetadataCorrection"]
        rows = [row for row in manifest["sourceOfferComponents"]
                if row.get("path") == V434_WEBGPU_CORRECTION_PATH.as_posix()]
        path = source_offer_root / V434_WEBGPU_CORRECTION_PATH
        for parent in (source_offer_root / "evidence", path):
            if parent.is_symlink():
                raise ValueError("symlink")
        if (not isinstance(relink, dict)
                or relink.get("receiptSHA256") != V423_WEBGPU_RECEIPT_SHA256
                or relink.get("outputSHA256") != V423_WEBGPU_OUTPUT_SHA256
                or not isinstance(correction, dict)
                or correction.get("path") != V434_WEBGPU_CORRECTION_PATH.as_posix()
                or correction.get("sha256") != V434_WEBGPU_CORRECTION_SHA256
                or len(rows) != 1 or rows[0].get("includedInOfferFolder") is not True
                or rows[0].get("sha256") != V434_WEBGPU_CORRECTION_SHA256
                or not path.is_file() or rows[0].get("bytes") != path.stat().st_size
                or sha256(path) != V434_WEBGPU_CORRECTION_SHA256):
            raise ValueError("correction component mismatch")
        document = json.loads(path.read_text(encoding="utf-8"))
        if (document.get("id") != "V434-portable"
                or document.get("subject") != "WebGPU.framework/Versions/A/WebGPU"
                or document.get("originalReceiptSHA256") != V423_WEBGPU_RECEIPT_SHA256
                or document.get("outputSHA256") != V423_WEBGPU_OUTPUT_SHA256
                or document.get("originalReportedBytes") != 4_007_776
                or document.get("observedBytes") != 4_031_032
                or document.get("signature") != "linker-signed ad-hoc; no Developer ID signature"):
            raise ValueError("correction fields mismatch")
    except (OSError, ValueError, TypeError, KeyError, AttributeError, json.JSONDecodeError) as error:
        raise PackageError("V423 WebGPU metadata correction is missing or invalid") from error


def verify_v438_jsc_review(source_offer_root: Path, expected_manifest_sha256: str) -> None:
    """Bind the portable notice review and the renderer input to the same offer."""
    manifest_path = source_offer_root / "manifest.json"
    try:
        if (source_offer_root.is_symlink() or not source_offer_root.is_dir()
                or manifest_path.is_symlink() or not manifest_path.is_file()
                or not isinstance(expected_manifest_sha256, str)
                or re.fullmatch(r"[0-9a-f]{64}", expected_manifest_sha256) is None
                or sha256(manifest_path) != expected_manifest_sha256):
            raise ValueError("unbound manifest")
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        binding = manifest["currentJavaScriptCoreV438PortableReview"]
        rows = [row for row in manifest["sourceOfferComponents"]
                if row.get("path") == V438_JSC_REVIEW_PATH.as_posix()]
        path = source_offer_root / V438_JSC_REVIEW_PATH
        if ((source_offer_root / "evidence").is_symlink() or path.is_symlink()
                or not path.is_file() or V438_JSC_REVIEW_SOURCE.is_symlink()
                or not V438_JSC_REVIEW_SOURCE.is_file()
                or binding.get("path") != V438_JSC_REVIEW_PATH.as_posix()
                or binding.get("sha256") != V438_JSC_REVIEW_SHA256
                or len(rows) != 1 or rows[0].get("includedInOfferFolder") is not True
                or rows[0].get("sha256") != V438_JSC_REVIEW_SHA256
                or rows[0].get("bytes") != path.stat().st_size
                or sha256(path) != V438_JSC_REVIEW_SHA256
                or sha256(V438_JSC_REVIEW_SOURCE) != V438_JSC_REVIEW_SHA256):
            raise ValueError("review binding mismatch")
    except (OSError, ValueError, TypeError, KeyError, AttributeError, json.JSONDecodeError) as error:
        raise PackageError("V438 JavaScriptCore portable review is missing or invalid") from error


def run(arguments: list[str], *, env: dict[str, str] | None = None,
        cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(arguments, check=True, capture_output=True, text=True,
                              env=env, cwd=cwd, timeout=3600)
    except (OSError, subprocess.SubprocessError) as error:
        # Keep actionable failure evidence private while avoiding noisy/raw
        # diagnostics in the release command's public-facing error.
        diagnostic = Path("/private/tmp/neantik-owned-webkit-package-failure.json")
        payload = {
            "command": [str(value) for value in arguments],
            "executable": Path(arguments[0]).name,
            "errorType": type(error).__name__,
            "returnCode": getattr(error, "returncode", None),
            "stdout": getattr(error, "stdout", None),
            "stderr": getattr(error, "stderr", None),
            "message": str(error)[:4096],
        }
        encoded = (json.dumps(payload, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(diagnostic, flags, 0o600)
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "wb", closefd=False) as stream:
                stream.write(encoded)
                stream.flush()
                os.fsync(stream.fileno())
        finally:
            os.close(descriptor)
        raise PackageError(
            f"owned WebKit packaging stage failed: {Path(arguments[0]).name}; "
            f"private diagnostic saved at {diagnostic}") from error


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise PackageError(f"required release verifier unavailable: {name}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def verify_source_offer_recipe_identity(source_offer_root: Path) -> None:
    """Reject inconsistent recipe identities; this does not qualify the offer."""
    checker = _load_module("source_offer_recipe_binding", ROOT / "scripts/check-source-offer-recipe-binding.py")
    try:
        checker.check(source_offer_root)
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise PackageError("source-offer recipe identity is invalid") from error


def validate_manager_info(info: object, identity: str) -> None:
    if (not isinstance(info, dict) or info.get("CFBundleIdentifier") != PRODUCTION_BUNDLE_ID
            or info.get("CFBundleShortVersionString") != "1.0.0"):
        raise PackageError("owned WebKit release packaging requires the 1.0.0 production manager")
    try:
        build = int(info.get("CFBundleVersion", ""))
    except (TypeError, ValueError) as error:
        raise PackageError("1.0.0 manager build number is malformed") from error
    expected_build = production_build_number()
    if build != expected_build:
        raise PackageError(f"1.0.0 manager build must match source build {expected_build}")
    forbidden = {"NeAntikBackupQualificationRunID", "NeAntikBackupQualificationRoot",
                 "NeAntikBrowserDataBackupDevelopmentEnabled", "NeAntikQATrustScope",
                 "NeAntikProductionDiagnosticEnabled", "NeAntikProductionDiagnosticDataRoot"}
    if forbidden.intersection(info):
        raise PackageError("development or QA manager metadata is not allowed")
    if identity.upper() != IDENTITY_SHA1:
        raise PackageError("release must use the existing pinned Developer ID identity")


def verify_source_archive_identity() -> None:
    """Bind a no-.git source extraction to the pinned upstream archive receipt."""
    try:
        recovery = json.loads(SOURCE_RECOVERY.read_text(encoding="utf-8"))
        archive_identity = (SOURCE_ARCHIVE.is_file() and not SOURCE_ARCHIVE.is_symlink()
                            and SOURCE_ARCHIVE.stat().st_size == recovery.get("sourceArchiveBytes")
                            and sha256(SOURCE_ARCHIVE) == SOURCE_ARCHIVE_SHA256)
    except (OSError, ValueError, UnicodeError) as error:
        raise PackageError("pinned WebKit source archive receipt is unavailable") from error
    if (recovery.get("status") != "exact-source-commit-recovered-and-patched;offer-incomplete"
            or recovery.get("repository") != "https://github.com/WebKit/WebKit"
            or recovery.get("commit") != EXPECTED_COMMIT
            or recovery.get("tree") != SOURCE_TREE
            or recovery.get("sourceArchiveSHA256") != SOURCE_ARCHIVE_SHA256
            or recovery.get("patchSHA256") != EXPECTED_PATCH_SHA256
            or not archive_identity):
        raise PackageError("pinned WebKit source archive does not match the release identity")


def source_offer_replacements(source_offer_root: Path,
                             expected_manifest_sha256: str) -> dict[str, str]:
    """Verify the pinned offer manifest and every first-party overlay input."""
    if source_offer_root.is_symlink() or not source_offer_root.is_dir():
        raise PackageError("pinned source-offer root must be a physical directory")
    source_offer_root = source_offer_root.resolve(strict=True)
    manifest_path = source_offer_root / "manifest.json"
    if (not isinstance(expected_manifest_sha256, str)
            or len(expected_manifest_sha256) != 64
            or any(character not in "0123456789abcdef" for character in expected_manifest_sha256)
            or manifest_path.is_symlink() or not manifest_path.is_file()
            or sha256(manifest_path) != expected_manifest_sha256):
        raise PackageError("pinned source-offer manifest hash mismatch")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        components = manifest["sourceOfferComponents"]
        if (type(manifest.get("sourceOfferComponentCount")) is not int
                or manifest["sourceOfferComponentCount"] != len(components)
                or len(components) < 498):
            raise ValueError("component count")
        component_hashes: dict[str, tuple[int, str]] = {}
        for row in components:
            rel = row["path"]
            relative = Path(rel)
            if (not isinstance(rel, str) or relative.is_absolute() or ".." in relative.parts
                    or rel in component_hashes or row.get("includedInOfferFolder") is not True
                    or type(row["bytes"]) is not int or row["bytes"] < 0):
                raise ValueError("unsafe or duplicate source-offer component")
            component_hashes[rel] = (row["bytes"], row["sha256"])
            component = source_offer_root / relative
            if (component.is_symlink() or not component.is_file()
                    or component.stat().st_size != row["bytes"]
                    or sha256(component) != row["sha256"]):
                raise ValueError(f"source-offer component mismatch: {rel}")
        source = manifest["source"]
        archive_path = source["sourceArchive"]
        if (not isinstance(archive_path, str)
                or archive_path not in component_hashes
                or component_hashes[archive_path] != (source["sourceArchiveBytes"], source["sourceArchiveSHA256"])):
            raise ValueError("manager source archive metadata differs from source-offer component")
        overlays_root = source_offer_root / "overlays"
        if overlays_root.is_symlink() or not overlays_root.is_dir():
            raise ValueError("overlay root")
        overlay_manifests = sorted((source_offer_root / "overlays").glob("*/ATTRIBUTION.json"))
        if len(overlay_manifests) != 8:
            raise ValueError("overlay manifest count")
        replacements: dict[str, str] = {}
        asset_count = 0
        for attribution_path in overlay_manifests:
            if attribution_path.parent.is_symlink():
                raise ValueError("overlay directory is a symlink")
            rel_manifest = attribution_path.relative_to(source_offer_root).as_posix()
            expected_manifest = component_hashes.get(rel_manifest)
            if (attribution_path.is_symlink() or not attribution_path.is_file()
                    or expected_manifest is None
                    or attribution_path.stat().st_size != expected_manifest[0]
                    or sha256(attribution_path) != expected_manifest[1]):
                raise ValueError(f"overlay manifest mismatch: {rel_manifest}")
            attribution = json.loads(attribution_path.read_text(encoding="utf-8"))
            for row in attribution["assets"]:
                rel = row["path"]
                if rel in replacements or rel.startswith("/") or ".." in Path(rel).parts:
                    raise ValueError(f"duplicate or unsafe overlay path: {rel}")
                replacements[rel] = row["sha256"]
                asset_count += 1
        if len(replacements) != 64 or asset_count != 64:
            raise ValueError("overlay asset count")
        for attribution_path in overlay_manifests:
            attribution = json.loads(attribution_path.read_text(encoding="utf-8"))
            overlay_name = attribution_path.parent.name
            for row in attribution["assets"]:
                rel = row["path"]
                expected_hash = row["sha256"]
                component_path = (Path("overlays") / overlay_name / Path(rel)).as_posix()
                staged = source_offer_root / component_path
                component = component_hashes.get(component_path)
                if (staged.is_symlink() or not staged.is_file()
                        or component is None or staged.stat().st_size != component[0]
                        or sha256(staged) != expected_hash or expected_hash != component[1]):
                    raise ValueError(f"first-party overlay asset mismatch: {rel}")
    except (KeyError, TypeError, ValueError, OSError, UnicodeError) as error:
        raise PackageError("pinned source-offer overlay inventory is invalid") from error
    return replacements


def _apply_runtime_overlay_file(runtime_frameworks: Path, overlay_asset: Path,
                                runtime_relative: Path, preimage_sha256: str,
                                replacement_sha256: str, expected_bytes: int) -> dict:
    """Apply one verified source-offer replacement to a disposable staged runtime."""
    if (runtime_frameworks.is_symlink() or not runtime_frameworks.is_dir()
            or runtime_relative.is_absolute() or ".." in runtime_relative.parts):
        raise PackageError("runtime overlay target is unsafe")
    root = runtime_frameworks.resolve(strict=True)
    target = runtime_frameworks / runtime_relative
    try:
        target.resolve(strict=True).relative_to(root)
    except (OSError, ValueError) as error:
        raise PackageError("runtime overlay target escapes Frameworks") from error
    if target.is_symlink() or not target.is_file():
        raise PackageError(f"runtime overlay target must be a regular file: {runtime_relative}")
    if (overlay_asset.is_symlink() or not overlay_asset.is_file()
            or overlay_asset.stat().st_size != expected_bytes
            or sha256(overlay_asset) != replacement_sha256):
        raise PackageError(f"source-offer runtime overlay bytes changed: {overlay_asset.name}")
    current_sha256 = sha256(target)
    if current_sha256 == replacement_sha256:
        return {"path": runtime_relative.as_posix(), "sha256": current_sha256,
                "bytes": target.stat().st_size, "alreadyApplied": True}
    if current_sha256 != preimage_sha256:
        raise PackageError(f"runtime overlay preimage mismatch: {runtime_relative}")
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{target.name}.neantik-overlay-", dir=target.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as output, overlay_asset.open("rb") as source:
            shutil.copyfileobj(source, output)
            output.flush()
            os.fsync(output.fileno())
        shutil.copystat(target, temporary, follow_symlinks=False)
        if sha256(temporary) != replacement_sha256:
            raise PackageError(f"staged runtime overlay hash mismatch: {runtime_relative}")
        os.replace(temporary, target)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
    return {"path": runtime_relative.as_posix(), "sha256": sha256(target),
            "bytes": target.stat().st_size, "alreadyApplied": False}


def apply_source_offer_runtime_overlays(
    runtime_frameworks: Path, source_root: Path, source_offer_root: Path,
    expected_manifest_sha256: str,
) -> dict:
    """Apply all hash-bound file overlays and bind the compiled warning-color catalog."""
    if (runtime_frameworks.is_symlink() or not runtime_frameworks.is_dir()
            or source_root.is_symlink() or not source_root.is_dir()
            or source_offer_root.is_symlink() or not source_offer_root.is_dir()):
        raise PackageError("runtime overlay inputs must be physical directories")
    offer = source_offer_root.resolve(strict=True)
    manifest_path = offer / "manifest.json"
    if manifest_path.is_symlink() or not manifest_path.is_file() or sha256(manifest_path) != expected_manifest_sha256:
        raise PackageError("runtime overlay source-offer manifest hash mismatch")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        binding = manifest.get("currentWebKitV382FilteredModelSource")
        components = {row["path"]: row for row in manifest["sourceOfferComponents"]}
        overlay_manifests = sorted((offer / "overlays").glob("*/ATTRIBUTION.json"))
    except (KeyError, TypeError, OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PackageError("runtime overlay source-offer metadata is invalid") from error
    if binding is None:
        raise PackageError("current source offer has no V382 overlay/build binding")

    # The full source-offer inventory was checked by validate_inputs. Recheck each
    # consumed file and its manifest component before modifying only this temp stage.
    applied = []
    expected_overlay_count = 0
    for attribution_path in overlay_manifests:
        overlay_name = attribution_path.parent.name
        try:
            attribution = json.loads(attribution_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise PackageError(f"runtime overlay attribution is invalid: {overlay_name}") from error
        for row in attribution.get("assets", []):
            source_path = Path(row.get("path", ""))
            if source_path.is_absolute() or ".." in source_path.parts:
                raise PackageError("runtime overlay source path is unsafe")
            source_asset = offer / "overlays" / overlay_name / source_path
            component_path = (Path("overlays") / overlay_name / source_path).as_posix()
            component = components.get(component_path)
            if (component is None or component.get("includedInOfferFolder") is not True
                    or source_asset.is_symlink() or not source_asset.is_file()
                    or component.get("bytes") != source_asset.stat().st_size
                    or component.get("sha256") != row.get("sha256")
                    or sha256(source_asset) != row.get("sha256")):
                raise PackageError(f"runtime overlay component binding mismatch: {component_path}")
            preimage = row.get("replacesRuntimeSHA256")
            if preimage is None:
                continue  # The warning colors are compiled into Assets.car below.
            if source_path.as_posix().startswith(
                    "Source/WebCore/Modules/modern-media-controls/images/macOS/"):
                runtime_relative = (Path("WebCore.framework/Versions/A/Resources/modern-media-controls/images")
                                    / source_path.name)
            elif source_path.as_posix().startswith("Source/WebCore/Resources/"):
                runtime_relative = (Path("WebCore.framework/Versions/A/Resources")
                                    / source_path.name)
            else:
                raise PackageError(f"unmapped runtime overlay source: {source_path}")
            applied.append(_apply_runtime_overlay_file(
                runtime_frameworks, source_asset, runtime_relative, preimage,
                row["sha256"], row["bytes"]))
            expected_overlay_count += 1
    if expected_overlay_count != 55:
        raise PackageError("V382 runtime overlay file count is not the pinned 55")

    try:
        receipt_relative = Path(binding["assetCatalogReceiptPath"])
        receipt_sha256 = binding["assetCatalogReceiptSHA256"]
        if receipt_relative.is_absolute() or ".." in receipt_relative.parts:
            raise ValueError("unsafe asset catalog receipt path")
        receipt_path = offer / receipt_relative
        component = components.get(receipt_relative.as_posix())
        if (component is None or component.get("includedInOfferFolder") is not True
                or receipt_path.is_symlink() or not receipt_path.is_file()
                or component.get("bytes") != receipt_path.stat().st_size
                or component.get("sha256") != receipt_sha256
                or sha256(receipt_path) != receipt_sha256):
            raise ValueError("asset catalog receipt component mismatch")
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        output = receipt["output"]
        attribution = json.loads((offer / "overlays/neantik-first-party-warning-colors-v1/ATTRIBUTION.json").read_text(encoding="utf-8"))
        input_rows = receipt["sourceOverlay"]["inputs"]
        expected_inputs = {row["path"]: row["sha256"] for row in attribution["assets"]}
        observed_inputs = {row["path"]: row["sha256"] for row in input_rows}
        if (receipt.get("schemaVersion") != 1
                or receipt.get("id") != "neantik-v394-webkit-warning-color-assets-car-build"
                or receipt.get("status") != "PASS_V382_WEBKIT_ASSETS_CATALOG_BUILD_ONE_ACTION"
                or receipt.get("sourceOverlay", {}).get("attributionSHA256") != sha256(
                    offer / "overlays/neantik-first-party-warning-colors-v1/ATTRIBUTION.json")
                or receipt.get("build", {}).get("target") != "WebKit_Assets"
                or receipt.get("build", {}).get("requestedActions") != 1
                or len(input_rows) != 9 or observed_inputs != expected_inputs
                or output.get("path") != "WebKit.framework/Versions/A/Resources/Assets.car"):
            raise ValueError("asset catalog receipt scope mismatch")
        for rel, digest in expected_inputs.items():
            source = source_root / rel
            if source.is_symlink() or not source.is_file() or sha256(source) != digest:
                raise ValueError(f"warning-color source overlay mismatch: {rel}")
        car_relative = Path(output["path"])
        staged_car = runtime_frameworks / car_relative
        try:
            staged_car.resolve(strict=True).relative_to(runtime_frameworks.resolve(strict=True))
        except (OSError, ValueError) as error:
            raise ValueError("staged Assets.car escapes runtime") from error
        expected_asset_sha = output.get("sha256")
        expected_asset_bytes = output.get("bytes")
        fresh_fields = ("currentWebKitV465BaselineRuntime", "currentWebKitV467StabilizedRuntime")
        if any(manifest.get(field) is not None for field in fresh_fields):
            # First validate the old build/notice lineage and the separately
            # pinned fresh-build identity. Never reinterpret the V394 receipt
            # as if it described the new catalog bytes.
            notices = _load_module("neantik_v465_overlay_notice_binding", ROOT / "scripts/webkit_runtime_notices.py")
            try:
                fresh = notices._v382_runtime_hashes(ROOT, offer, expected_manifest_sha256)
            except notices.NoticeError as error:
                raise ValueError("fresh runtime identity binding invalid") from error
            identity_path = offer / (notices.V467_RUNTIME_BINDING_PATH
                                     if manifest.get(fresh_fields[1]) is not None
                                     else notices.V465_RUNTIME_BINDING_PATH)
            identity = json.loads(identity_path.read_text(encoding="utf-8"))
            fresh_asset = identity["compiledAssets"]
            expected_asset_sha = fresh.get(car_relative.as_posix())
            expected_asset_bytes = fresh_asset.get("bytes")
            if (expected_asset_sha != fresh_asset.get("sha256")
                    or type(expected_asset_bytes) is not int or expected_asset_bytes < 1):
                raise ValueError("fresh asset catalog identity mismatch")
        if (staged_car.is_symlink() or not staged_car.is_file()
                or staged_car.stat().st_size != expected_asset_bytes
                or sha256(staged_car) != expected_asset_sha):
            raise ValueError("staged Assets.car does not match the bound asset catalog identity")
    except (KeyError, TypeError, ValueError, OSError, UnicodeError,
            json.JSONDecodeError) as error:
        raise PackageError("V382 warning-color asset catalog binding is invalid") from error
    return {"status": "PASS_V382_SOURCE_OFFER_RUNTIME_OVERLAYS_APPLIED",
            "manifestSHA256": expected_manifest_sha256,
            "assetCatalogReceiptSHA256": receipt_sha256,
            "assetCatalogSHA256": expected_asset_sha,
            "runtimeOverlayAssetCount": len(applied),
            "runtimeOverlayAlreadyPresent": sum(1 for row in applied if row["alreadyApplied"]),
            "runtimeOverlaySHA256": hashlib.sha256(
                json.dumps(applied, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
            "runtimeOverlays": applied}


def source_crosswalk_binding(source_offer_root: Path,
                             expected_manifest_sha256: str) -> tuple[Path, str, dict | None]:
    """Select the technical crosswalk bound to this exact source offer.

    Historical offers keep using the original V20 crosswalk. Filtered offers
    must carry a unique, hash-bound crosswalk and provenance record in their
    component manifest; no global switch can silently change old candidates.
    """
    manifest_path = source_offer_root / "manifest.json"
    if (manifest_path.is_symlink() or not manifest_path.is_file()
            or sha256(manifest_path) != expected_manifest_sha256):
        raise PackageError("pinned source-offer manifest hash mismatch")
    try:
        offer = json.loads(manifest_path.read_text(encoding="utf-8"))
        binding = offer.get("currentWebKitV382FilteredModelSource")
        if binding is None:
            return SOURCE_CROSSWALK, SOURCE_CROSSWALK_SHA256, None
        if not isinstance(binding, dict):
            raise ValueError("filtered crosswalk binding")
        components = offer["sourceOfferComponents"]
        component_by_path = {row["path"]: row for row in components}
        relative = Path(binding["crosswalkPath"])
        provenance_relative = Path(binding["provenancePath"])
        archive_relative = Path(offer["componentBoundaries"]["webkitSourceArchive"])
        if any(path.is_absolute() or ".." in path.parts
               for path in (relative, provenance_relative, archive_relative)):
            raise ValueError("unsafe filtered component path")
        expected_crosswalk = binding["crosswalkSHA256"]
        expected_provenance = binding["provenanceSHA256"]
        expected_archive = binding["derivedArchiveSHA256"]
        scope_patch_relative = Path(binding["scopePatchPath"])
        if scope_patch_relative.is_absolute() or ".." in scope_patch_relative.parts:
            raise ValueError("unsafe filtered scope patch path")
        expected_components = (
            (relative.as_posix(), expected_crosswalk),
            (provenance_relative.as_posix(), expected_provenance),
            (archive_relative.as_posix(), expected_archive),
            (scope_patch_relative.as_posix(), V382_FILTERED_MODEL_SCOPE_PATCH_SHA256),
            ("patches/webkit-text-extraction-filter-macos-deployment-gate-v377.patch",
             V377_TEXT_EXTRACTION_PATCH_SHA256),
            ("patches/webkit-coreprediction-model-macos-deployment-gate-v381.patch",
             V381_CORE_PREDICTION_PATCH_SHA256),
        )
        for rel, expected in expected_components:
            row = component_by_path.get(rel)
            path = source_offer_root / rel
            if (row is None or row.get("includedInOfferFolder") is not True
                    or path.is_symlink() or not path.is_file()
                    or row.get("bytes") != path.stat().st_size
                    or row.get("sha256") != expected or sha256(path) != expected):
                raise ValueError("filtered offer component does not match its binding")
        crosswalk = json.loads((source_offer_root / relative).read_text(encoding="utf-8"))
        provenance = json.loads((source_offer_root / provenance_relative).read_text(encoding="utf-8"))
        omitted = {
            "Source/WebKit/Resources/TextExtractionFilter.mlmodel":
                "87a4e82b476fb7e61482c243230fffa319b5108319167f340db5ff8e9d48693f",
            "Source/WebKit/Resources/ResourceLoadStatistics/corePrediction_model":
                "221555a2cdd2e957f18d478c4b9fd01f308c1613e6e10840cce924e5f543091a",
        }
        excluded_rows = crosswalk["excludedRuntimeRows"]
        excluded_sources = {
            source["path"]: source["sha256"]
            for row in excluded_rows["sourceRows"]
            for source in row["mappedSources"]
        }
        provenance_exclusions = {
            row.get("path", "").removeprefix("WebKit/"): row.get("sha256")
            for row in provenance.get("excludedSourceAssets", [])
            if isinstance(row, dict)
        }
        expected_patch_paths = [row[0] for row in expected_components[4:]] + [
            scope_patch_relative.as_posix()]
        if (crosswalk.get("filteredSourceOffer", {}).get("archiveSHA256") != expected_archive
                or crosswalk.get("filteredSourceOffer", {}).get("excludedSourcePaths") != sorted(omitted)
                or binding.get("scopePatchSHA256") != V382_FILTERED_MODEL_SCOPE_PATCH_SHA256
                or excluded_rows.get("count") != 4
                or excluded_rows.get("status") != "UNKNOWN until exact full-build and staged-candidate absence proof"
                or excluded_sources != omitted
                or provenance_exclusions != omitted
                or provenance.get("upstream", {}).get("archiveSHA256") != SOURCE_ARCHIVE_SHA256
                or provenance.get("patches") != expected_patch_paths
                or provenance.get("derivedArchive", {}).get("sha256") != expected_archive
                or provenance.get("status") != "DERIVED_FROM_PINNED_UPSTREAM_ARCHIVE; BUILD_AND_RUNTIME_ABSENCE_UNPROVEN"):
            raise ValueError("filtered crosswalk/provenance scope mismatch")
        crosswalk["crosswalkSHA256"] = expected_crosswalk
        return source_offer_root / relative, expected_crosswalk, binding
    except (KeyError, TypeError, ValueError, OSError, UnicodeError) as error:
        raise PackageError("filtered source-offer crosswalk binding is invalid") from error


def select_stabilized_build_binding(source_offer_root: Path, expected_manifest_sha256: str,
                                    historical_binding: dict | None) -> dict | None:
    """Select only the exact V468 receipt paired with the exact V467 runtime."""
    manifest_path = source_offer_root / "manifest.json"
    try:
        if (source_offer_root.is_symlink() or not source_offer_root.is_dir()
                or manifest_path.is_symlink() or not manifest_path.is_file()
                or sha256(manifest_path) != expected_manifest_sha256):
            raise ValueError("manifest mismatch")
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        selected = manifest.get("currentWebKitV468BuildReceipt")
        if selected is None:
            if manifest.get("currentWebKitV467StabilizedRuntime") is not None:
                raise ValueError("stabilized runtime has no exact build receipt")
            return historical_binding
        if not isinstance(historical_binding, dict) or not isinstance(selected, dict):
            raise ValueError("missing filtered build binding")
        notices = _load_module("neantik_v468_notice_binding", ROOT / "scripts/webkit_runtime_notices.py")
        if (manifest.get("currentWebKitV467StabilizedRuntime") is None
                or manifest.get("currentWebKitV465BaselineRuntime") is not None):
            raise ValueError("stabilized runtime is not uniquely selected")
        try:
            notices._v382_runtime_hashes(ROOT, source_offer_root, expected_manifest_sha256)
            component = notices._physical_path_beneath(source_offer_root, V468_BUILD_RECEIPT_PATH,
                                                        label="V468 build receipt")
        except notices.NoticeError as error:
            raise ValueError("stabilized runtime identity invalid") from error
        rows = [row for row in manifest["sourceOfferComponents"]
                if row.get("path") == V468_BUILD_RECEIPT_PATH.as_posix()]
        if (selected.get("path") != V468_BUILD_RECEIPT_PATH.as_posix()
                or selected.get("sha256") != V468_BUILD_RECEIPT_SHA256
                or len(rows) != 1 or rows[0].get("includedInOfferFolder") is not True
                or rows[0].get("sha256") != V468_BUILD_RECEIPT_SHA256
                or rows[0].get("bytes") != component.stat().st_size
                or sha256(component) != V468_BUILD_RECEIPT_SHA256
                or V468_LOCAL_BUILD_RECEIPT.is_symlink()
                or not V468_LOCAL_BUILD_RECEIPT.is_file()
                or sha256(V468_LOCAL_BUILD_RECEIPT) != V468_BUILD_RECEIPT_SHA256):
            raise ValueError("stabilized receipt component mismatch")
        result = dict(historical_binding)
        result["buildReceiptPath"] = V468_BUILD_RECEIPT_PATH.as_posix()
        result["buildReceiptSHA256"] = V468_BUILD_RECEIPT_SHA256
        return result
    except (KeyError, TypeError, ValueError, OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PackageError("stabilized WebKit build receipt binding is invalid") from error


def load_build_receipt(build_receipt_path: Path,
                       filtered_binding: dict | None = None) -> dict:
    if build_receipt_path.is_symlink() or not build_receipt_path.is_file():
        raise PackageError("exact owned-WebKit build receipt is unavailable")
    receipt_sha256 = sha256(build_receipt_path)
    historical_receipt = receipt_sha256 in {BUILD_RECEIPT_SHA256, V135_BUILD_RECEIPT_SHA256}
    if filtered_binding is None and not historical_receipt:
        raise PackageError("owned-WebKit build receipt hash mismatch")
    try:
        receipt = json.loads(build_receipt_path.read_text(encoding="utf-8"))
        if filtered_binding is not None:
            expected_receipt = filtered_binding.get("buildReceiptSHA256")
            if (not isinstance(expected_receipt, str)
                    or not re.fullmatch(r"[0-9a-f]{64}", expected_receipt)
                    or receipt_sha256 != expected_receipt):
                raise ValueError("filtered build receipt hash is not frozen in the source offer")
            if not isinstance(receipt, dict):
                raise ValueError("filtered build receipt root")
            inputs = receipt.get("inputs")
            environment = receipt.get("environment")
            build = receipt.get("build")
            checks = receipt.get("checks")
            outputs = receipt.get("outputs")
            if not all(isinstance(value, dict)
                       for value in (inputs, environment, build, checks)):
                raise ValueError("filtered build receipt sections")
            expected_patch_hashes = {
                "webkit-v20-source-modifications.patch": EXPECTED_PATCH_SHA256,
                "patches/webkit-empty-webkit-infoplist-strings-exclusion-v36.patch": V36_PATCH_SHA256,
                "patches/webkit-text-extraction-filter-macos-deployment-gate-v377.patch": V377_TEXT_EXTRACTION_PATCH_SHA256,
                "patches/webkit-coreprediction-model-macos-deployment-gate-v381.patch": V381_CORE_PREDICTION_PATCH_SHA256,
                "patches/webkit-filtered-model-assets-deployment-scope-v382.patch": V382_FILTERED_MODEL_SCOPE_PATCH_SHA256,
            }
            stabilized = receipt_sha256 == V468_BUILD_RECEIPT_SHA256
            expected_id = "V468-stabilized-filtered-webkit-build" if stabilized else "neantik-v382-filtered-model-webkit-build"
            expected_status = ("PASS_SAME_HOST_STABILIZED_14_ARM64_NOT_RELEASE_QUALIFIED"
                               if stabilized else "PASS_FILTERED_MODEL_WEBKIT_BUILD_14_OF_14_ARM64")
            if (receipt.get("schemaVersion") != 1
                    or receipt.get("id") != expected_id
                    or not isinstance(receipt.get("status"), str)
                    or not receipt["status"].startswith(expected_status)
                    or inputs.get("webkitCommit") != EXPECTED_COMMIT
                    or inputs.get("sourceArchiveSHA256") != filtered_binding.get("derivedArchiveSHA256")
                    or inputs.get("mainSourcePatchSHA256") != EXPECTED_PATCH_SHA256
                    or inputs.get("v36PatchSHA256") != V36_PATCH_SHA256
                    or inputs.get("patchSHA256s") != expected_patch_hashes
                    or environment.get("hostArchitecture") != "arm64"
                    or environment.get("deploymentTarget") != "15.4"
                    or type(build.get("requestedActions")) is not int
                    or build.get("requestedActions") < 1
                    or checks.get("outputCount") != 14
                    or checks.get("allPresent") is not True
                    or checks.get("allArm64") is not True
                    or checks.get("ninjaDryRunNoWork") is not True
                    or not isinstance(outputs, list)
                    or any(not isinstance(row, dict) for row in outputs)
                    or {row.get("path") for row in outputs} != BUILD_TARGETS
                    or len(outputs) != 14
                    or any(row.get("architecture") != "arm64"
                           or type(row.get("bytes")) is not int or row["bytes"] < 1
                           or not re.fullmatch(r"[0-9a-f]{64}", row.get("sha256", ""))
                           for row in outputs)):
                raise ValueError("filtered build receipt fields")
            if stabilized:
                notices = _load_module("neantik_v468_receipt_notice", ROOT / "scripts/webkit_runtime_notices.py")
                identity_path = ROOT / notices.V467_LOCAL_BINDING_PATH
                if (identity_path.is_symlink() or not identity_path.is_file()
                        or sha256(identity_path) != notices.V467_RUNTIME_BINDING_SHA256
                        or receipt.get("runtimeIdentitySHA256") != notices.V467_RUNTIME_BINDING_SHA256):
                    raise ValueError("stabilized runtime identity mismatch")
                identity = json.loads(identity_path.read_text(encoding="utf-8"))
                if (receipt["outputs"] != identity["buildOutputs"]
                        or receipt.get("assetsSHA256") != identity["compiledAssets"]["sha256"]):
                    raise ValueError("stabilized build outputs do not match runtime identity")
        elif receipt_sha256 == BUILD_RECEIPT_SHA256:
            targets = receipt["build"]["requestedTargets"]
            if (receipt.get("id") != "neantik-v122-fresh-owned-webkit-build-and-staging-20261026"
                    or not receipt.get("status", "").startswith("PASS_FRESH_PINNED_WEBKIT_BUILD_10902_OF_10902")
                    or receipt["inputs"]["sourceArchiveSHA256"] != SOURCE_ARCHIVE_SHA256
                    or receipt["inputs"]["sourcePatchSHA256"] != EXPECTED_PATCH_SHA256
                    or receipt["inputs"]["v36PatchSHA256"] != V36_PATCH_SHA256
                    or targets.get("targetCount") != 14
                    or targets.get("allPresent") is not True
                    or targets.get("allArm64") is not True
                    or {row["path"] for row in targets["targets"]} != BUILD_TARGETS
                    or receipt["staging"].get("status") != "staged-pre-sign-only"
                    or receipt["staging"].get("networkSandbox", {}).get("policyRevision") != 13
                    or len(targets["targets"]) != 14):
                raise ValueError("V122 build receipt fields")
        else:
            targets = receipt["outputs"]
            inputs = receipt["inputs"]
            if (receipt.get("id") != "neantik-v135-clean-relocated-v132-webkit-relink-20261026"
                    or not receipt.get("status", "").startswith("PASS_CLEAN_RELOCATED_V132_WEBKIT_BUILD_14_OF_14_ARM64")
                    or inputs.get("sourceArchiveSHA256") != SOURCE_ARCHIVE_SHA256
                    or inputs.get("mainSourcePatchSHA256") != EXPECTED_PATCH_SHA256
                    or inputs.get("v36PatchSHA256") != V36_PATCH_SHA256
                    or receipt.get("build", {}).get("requestedActions") != 10902
                    or {row["path"] for row in targets} != BUILD_TARGETS
                    or any(row.get("architecture") != "arm64" for row in targets)
                    or len(targets) != 14):
                raise ValueError("V135 build receipt fields")
    except (KeyError, TypeError, ValueError, OSError, UnicodeError) as error:
        raise PackageError("owned-WebKit build receipt does not match the pinned build") from error
    return receipt


def verify_build_outputs(build_root: Path, receipt: dict) -> None:
    # `build.requestedTargets.targets` records only the requested relative
    # paths in current filtered V382 receipts. The separate top-level outputs
    # rows bind their bytes, hashes, and architectures. Older receipts without
    # that section keep the measurements inline with requestedTargets.
    targets = receipt.get("outputs")
    if not isinstance(targets, list):
        targets = (receipt["build"]["requestedTargets"]["targets"]
                   if isinstance(receipt.get("build"), dict)
                   and "requestedTargets" in receipt["build"]
                   else targets)
    if not isinstance(targets, list):
        raise PackageError("owned-WebKit build receipt has no output measurements")
    for row in targets:
        image = build_root / row["path"]
        if (image.is_symlink() or not image.is_file()
                or image.stat().st_size != row["bytes"] or sha256(image) != row["sha256"]):
            raise PackageError(f"owned-WebKit output differs from the exact build receipt: {row['path']}")
        try:
            architectures = subprocess.check_output(["/usr/bin/lipo", "-archs", str(image)],
                                                    text=True, stderr=subprocess.STDOUT).strip().split()
        except (OSError, subprocess.SubprocessError) as error:
            raise PackageError("could not verify owned-WebKit output architecture") from error
        if architectures != ["arm64"]:
            raise PackageError(f"owned-WebKit output architecture differs from arm64: {row['path']}")


def verify_filtered_build_receipt_offer_binding(
    build_receipt_path: Path, source_offer_root: Path,
    expected_manifest_sha256: str, filtered_binding: dict | None,
) -> None:
    """Require the filtered build receipt to be an exact component of its offer."""
    if filtered_binding is None:
        return
    raw_relative = filtered_binding.get("buildReceiptPath")
    if not isinstance(raw_relative, str):
        raise PackageError("filtered source offer has no pinned build receipt path")
    relative = Path(raw_relative)
    if relative.is_absolute() or not relative.parts or ".." in relative.parts:
        raise PackageError("filtered source offer has no safe pinned build receipt path")
    manifest_path = source_offer_root / "manifest.json"
    if (manifest_path.is_symlink() or not manifest_path.is_file()
            or sha256(manifest_path) != expected_manifest_sha256):
        raise PackageError("pinned source-offer manifest hash mismatch")
    try:
        offer = json.loads(manifest_path.read_text(encoding="utf-8"))
        matches = [row for row in offer["sourceOfferComponents"]
                   if row.get("path") == relative.as_posix()]
        if len(matches) != 1:
            raise ValueError("build receipt component is not unique")
        row = matches[0]
        component = source_offer_root / relative
        supplied = build_receipt_path.resolve(strict=True)
        expected = component.resolve(strict=True)
        if (component.is_symlink() or supplied != expected
                or row.get("includedInOfferFolder") is not True
                or type(row.get("bytes")) is not int
                or component.stat().st_size != row["bytes"]
                or row.get("sha256") != filtered_binding.get("buildReceiptSHA256")
                or sha256(component) != row["sha256"]):
            raise ValueError("build receipt component differs from filtered offer binding")
    except (KeyError, TypeError, ValueError, OSError, UnicodeError) as error:
        raise PackageError("filtered build receipt is not bound inside the exact source offer") from error


def verify_v36_patch_postimage(source_root: Path, patch_path: Path) -> None:
    """Verify V36 on the final V382 source tree despite its later CMake context.

    V382 inserts a deployment guard between V36's deleted localized-resource
    block and the following framework-link commands. Git therefore cannot
    reverse-check that one combined hunk against the final tree. All other V36
    hunks must still reverse-check, and the exact V382 guard plus V36 removal
    postimage must be present.
    """
    patch_lines = patch_path.read_text(encoding="utf-8").splitlines(keepends=True)
    filtered: list[str] = []
    current_file = ""
    skipping = False
    removed_hunks = 0
    for line in patch_lines:
        if line.startswith("--- a/"):
            current_file = line[6:].strip()
            skipping = False
        if current_file == "Source/WebKit/PlatformCocoa.cmake" and line.startswith("@@ -2616,12 +2611,6 @@"):
            skipping = True
            removed_hunks += 1
            continue
        if skipping and (line.startswith("@@ ") or line.startswith("--- a/")):
            skipping = False
        if not skipping:
            filtered.append(line)
    if removed_hunks != 1:
        raise PackageError("pinned V36 patch has an unexpected filtered-source hunk layout")
    with tempfile.TemporaryDirectory(prefix="neantik-v36-postimage-") as temporary:
        partial_patch = Path(temporary) / "webkit-v36-postimage.patch"
        partial_patch.write_text("".join(filtered), encoding="utf-8")
        result = subprocess.run(
            ["/usr/bin/git", "-C", str(source_root), "apply", "--reverse",
             "--check", str(partial_patch)], capture_output=True, text=True)
    if result.returncode != 0:
        raise PackageError("pinned V36 patch postimage does not match the filtered source tree")
    cocoa = (source_root / "Source/WebKit/PlatformCocoa.cmake").read_text(encoding="utf-8")
    if (cocoa.count('This filtered NeAntik WebKit source offer supports deployment targets below macOS 26.0') != 1
            or "WEBKIT_COPY_FILES(WebKit_CopyLocalizedResources" in cocoa
            or "${WEBKIT_DIR}/en.lproj/InfoPlist.strings" in cocoa):
        raise PackageError("V382/V36 localized-resource postimage is invalid")


def validate_inputs(app: Path, build_root: Path, source_root: Path, identity: str,
                    build_receipt_path: Path, source_offer_root: Path,
                    source_offer_manifest_sha256: str) -> tuple[Path, Path, Path]:
    for path, label in ((app, "candidate app"), (build_root, "WebKit build root"),
                        (source_root, "pinned WebKit source root"),
                        (source_offer_root, "pinned corresponding-source offer")):
        if path.is_symlink() or not path.is_dir():
            raise PackageError(f"{label} must be an existing physical directory")
    app, build_root, source_root = (path.resolve(strict=True) for path in (app, build_root, source_root))
    source_offer_root = source_offer_root.resolve(strict=True)
    try:
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        raise PackageError("production manager metadata is unavailable") from error
    validate_manager_info(info, identity)
    host = app / "Contents/Helpers/webkit-v1/NeAntikWebKitHost.app"
    if host.exists() or host.is_symlink():
        raise PackageError("candidate already contains a WebKit host")
    verify_v434_webgpu_correction(source_offer_root, source_offer_manifest_sha256)
    verify_v438_jsc_review(source_offer_root, source_offer_manifest_sha256)
    try:
        home = None
        for line in (build_root / "CMakeCache.txt").read_text(encoding="utf-8").splitlines():
            if line.startswith("CMAKE_HOME_DIRECTORY:INTERNAL="):
                home = line.partition("=")[2]
                break
    except (OSError, UnicodeError) as error:
        raise PackageError("WebKit source/build binding is unavailable") from error
    build_source_root = Path(home or "")
    if build_source_root.is_symlink() or not build_source_root.is_dir():
        raise PackageError("configured WebKit source tree is unavailable")
    build_source_root = build_source_root.resolve(strict=True)
    # GitHub's source archive intentionally has no .git directory. Bind this
    # build to the verified upstream archive/commit receipt instead of making
    # a full local Git re-index a release prerequisite. The file-level
    # crosswalk below remains the check against both configured source roots.
    verify_source_archive_identity()
    if sha256(PATCH) != EXPECTED_PATCH_SHA256:
        raise PackageError("pinned WebKit patch hash mismatch")
    replacements = source_offer_replacements(source_offer_root,
                                               source_offer_manifest_sha256)
    verify_source_offer_recipe_identity(source_offer_root)
    crosswalk_path, crosswalk_sha256, filtered_binding = source_crosswalk_binding(
        source_offer_root, source_offer_manifest_sha256)
    filtered_binding = select_stabilized_build_binding(
        source_offer_root, source_offer_manifest_sha256, filtered_binding)
    if sha256(crosswalk_path) != crosswalk_sha256:
        raise PackageError("pinned WebKit source crosswalk hash mismatch")
    v36_patch = source_offer_root / V36_PATCH_RELATIVE
    if v36_patch.is_symlink() or not v36_patch.is_file() or sha256(v36_patch) != V36_PATCH_SHA256:
        raise PackageError("pinned V36 packaging-exclusion patch hash mismatch")
    verify_filtered_build_receipt_offer_binding(
        build_receipt_path, source_offer_root, source_offer_manifest_sha256,
        filtered_binding)
    build_receipt = load_build_receipt(build_receipt_path, filtered_binding)
    verify_build_outputs(build_root, build_receipt)
    try:
        crosswalk = json.loads(crosswalk_path.read_text(encoding="utf-8"))
        bound_sources: dict[str, str] = {}
        for section, key in (("directCompileInputs", "sourceRows"),
                             ("webCoreUnityInputs", "sourceRows")):
            for row in crosswalk[section][key]:
                if row["path"].startswith("Source/"):
                    bound_sources[row["path"]] = row["sha256"]
        for row in crosswalk["runtimeResources"]["sourceRows"]:
            for mapped in row["mappedSources"]:
                if mapped["path"].startswith("Source/"):
                    bound_sources[mapped["path"]] = mapped["sha256"]
    except (KeyError, TypeError, ValueError, OSError) as error:
        raise PackageError("pinned WebKit source crosswalk is malformed") from error
    if (crosswalk.get("upstream", {}).get("commit") != EXPECTED_COMMIT
            or crosswalk.get("upstream", {}).get("sourcePatchSHA256") != EXPECTED_PATCH_SHA256
            or crosswalk.get("status") != "technical-source-license-crosswalk;not-legal-applicability-or-release-approval"
            or len(bound_sources) != (3342 if filtered_binding is not None else 3344)):
        raise PackageError("pinned WebKit source crosswalk scope differs from the release input")
    if filtered_binding is not None:
        excluded_sources = {
            "Source/WebKit/Resources/TextExtractionFilter.mlmodel",
            "Source/WebKit/Resources/ResourceLoadStatistics/corePrediction_model",
        }
        for candidate_root in dict.fromkeys((source_root, build_source_root)):
            for relative in excluded_sources:
                omitted = candidate_root / relative
                if omitted.exists() or omitted.is_symlink():
                    raise PackageError("filtered WebKit source tree retained an excluded model asset")
    for candidate_root in dict.fromkeys((source_root, build_source_root)):
        for relative, expected in bound_sources.items():
            source_file = candidate_root / relative
            # Source trees may contain a reviewed first-party overlay already
            # applied, or retain the exact upstream preimage for runtime-stage
            # replacement. Accept only those two offer-bound byte identities.
            accepted_hashes = {expected}
            replacement_hash = replacements.get(relative)
            if replacement_hash is not None:
                accepted_hashes.add(replacement_hash)
            if (source_file.is_symlink() or not source_file.is_file()
                    or sha256(source_file) not in accepted_hashes):
                raise PackageError(f"pinned WebKit source file differs from crosswalk: {relative}")
    reverse = run(["/usr/bin/git", "-C", str(source_root), "apply", "--reverse",
                   "--check", str(PATCH)])
    if reverse.returncode != 0:
        raise PackageError("the pinned WebKit patch is not applied to the selected source tree")
    verify_v36_patch_postimage(source_root, v36_patch)
    if (filtered_binding is None and
            sha256(build_receipt_path) not in {BUILD_RECEIPT_SHA256, V135_BUILD_RECEIPT_SHA256}):
        raise PackageError("owned-WebKit build receipt changed during validation")
    return app, build_root, source_root


def _last_json(stdout: str, *, field: str) -> dict:
    for line in reversed(stdout.splitlines()):
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and field in value:
            return value
    raise PackageError("packaging helper did not return its stage receipt")


def production_host_binary(receipt: dict) -> Path:
    """Select the relocatable binary emitted for the bundled engine."""
    if (receipt.get("status") != "built-production-mode-unqualified"
            or receipt.get("qaProxy") is not False
            or receipt.get("productionProxy") is not True):
        raise PackageError("standalone production host was not built with the production-only feature gate")
    binary = Path(receipt.get("ownedBinary", ""))
    expected = receipt.get("ownedSHA256")
    if (binary.is_symlink() or not binary.is_file()
            or not isinstance(expected, str) or sha256(binary) != expected):
        raise PackageError("relocatable production host binary is unavailable or changed")
    return binary


def verify_chromium_compliance_prerequisite(app: Path) -> Path:
    """Require exact current Chromium compliance before staging owned WebKit."""
    embedded_lock = app / "Contents/Resources/NeAntikRuntimeEvidence/fingerprint-chromium.lock.json"
    compliance = app / "Contents/Resources/NeAntikRuntimeCompliance"
    if (embedded_lock.is_symlink() or not embedded_lock.is_file()
            or sha256(embedded_lock) != sha256(ROOT / "runtime/fingerprint-chromium.lock.json")):
        raise PackageError(
            "candidate is not integrated with the current Chromium runtime lock; "
            "package the exact Chromium candidate before owned WebKit"
        )
    if compliance.is_symlink() or not compliance.is_dir():
        raise PackageError(
            "current Chromium compliance artifacts are missing; generate and verify "
            "them from the exact integrated Chromium source before owned WebKit"
        )
    result = subprocess.run(
        [str(ROOT / "scripts/verify-runtime-compliance.sh"), str(compliance), str(embedded_lock)],
        capture_output=True, text=True)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()
        reason = detail[-1] if detail else "compliance verification failed"
        raise PackageError(f"current Chromium compliance preflight failed: {reason}")
    return embedded_lock


def package(app: Path, build_root: Path, source_root: Path, identity: str,
            build_receipt_path: Path, source_offer_root: Path,
            source_offer_manifest_sha256: str) -> dict:
    app, build_root, source_root = validate_inputs(
        app, build_root, source_root, identity, build_receipt_path, source_offer_root,
        source_offer_manifest_sha256)
    # This cheap dependency must be checked before profile signing, runtime
    # staging, and the standalone-host build. The WebKit notice installer
    # extends the integrated Chromium compliance artifact in place.
    verify_chromium_compliance_prerequisite(app)
    developer_dir = run([str(ROOT / "scripts/resolve-compatible-developer-dir.sh")]).stdout.strip()
    env = dict(os.environ)
    env["DEVELOPER_DIR"] = developer_dir
    env["NEANTIK_RELEASE_CHANNEL"] = "production"
    env["NEANTIK_SIGNING_IDENTITY"] = identity

    # Validate profile and manager signing before staging the large runtime or
    # compiling the production host. These inputs are cheaper failure points.
    run([sys.executable, str(ROOT / "scripts/direct_backup_signing.py"),
         "sign", str(app), identity], env=env)

    with tempfile.TemporaryDirectory(prefix="neantik-webkit-production-package-") as temporary:
        temp = Path(temporary)
        unsigned_frameworks = temp / "Frameworks"
        signed_frameworks = temp / "Frameworks-signed"
        staged = run([sys.executable, str(ROOT / "scripts/stage-webkit-runtime.py"),
                      str(build_root), str(unsigned_frameworks), "--upstream-source", str(source_root),
                      "--manifest", str(STAGING_MANIFEST)], cwd=ROOT)
        stage_receipt = _last_json(staged.stdout, field="machOSHA256")
        if stage_receipt.get("networkSandbox", {}).get("policyRevision") != 13:
            raise PackageError("runtime staging did not apply the pinned broker-only sandbox policy")
        overlay_receipt = apply_source_offer_runtime_overlays(
            unsigned_frameworks, source_root, source_offer_root,
            source_offer_manifest_sha256)

        run([sys.executable, str(ROOT / "scripts/resign-webkit-recipient-runtime.py"),
             "--manager-app", str(app), "--source-frameworks", str(unsigned_frameworks),
             "--output-frameworks", str(signed_frameworks), "--identity", identity])
        run([sys.executable, str(ROOT / "scripts/webkit_runtime_notices.py"),
             "--install", "--app", str(app), "--runtime-frameworks", str(signed_frameworks),
             "--source-offer-root", str(source_offer_root),
             "--source-offer-manifest-sha256", source_offer_manifest_sha256], env=env)

        host_result = run([sys.executable, str(ROOT / "scripts/build-webkit-standalone-host.py"),
                           "--configuration", "release", "--production-proxy"], cwd=ROOT, env=env)
        host_receipt = _last_json(host_result.stdout, field="binarySHA256")
        host_binary = production_host_binary(host_receipt)

        run([sys.executable, str(ROOT / "scripts/package-webkit-host.py"),
             "--app", str(app), "--host-binary", str(host_binary),
             "--runtime-frameworks", str(signed_frameworks), "--identity", identity,
             "--source-offer-root", str(source_offer_root),
             "--source-offer-manifest-sha256", source_offer_manifest_sha256])

    packager = _load_module("neantik_webkit_host_packager", ROOT / "scripts/package-webkit-host.py")
    notice_installer = _load_module("neantik_webkit_runtime_notices", ROOT / "scripts/webkit_runtime_notices.py")
    frameworks = app / packager.HOST_BUNDLE_RELATIVE_PATH / "Contents/Frameworks"
    try:
        notices = notice_installer.verify_owned_webkit_notices(
            app, frameworks, source_offer_root=source_offer_root,
            source_offer_manifest_sha256=source_offer_manifest_sha256)
    except Exception as error:
        raise PackageError("staged WebKit notice byte verification failed") from error
    host_hash = sha256(app / packager.HOST_EXECUTABLE_RELATIVE_PATH)
    return {
        "status": "owned_webkit_host_and_runtime_embedded; outer_manager_resign_required",
        "managerBundleID": PRODUCTION_BUNDLE_ID,
        "managerVersion": f"1.0.0 ({production_build_number()})",
        "upstreamCommit": EXPECTED_COMMIT,
        "sourcePatchSHA256": EXPECTED_PATCH_SHA256,
        "sourceCrosswalkSHA256": SOURCE_CROSSWALK_SHA256,
        "buildReceiptSHA256": sha256(build_receipt_path),
        "sourceOfferManifestSHA256": source_offer_manifest_sha256,
        "stagingManifestSHA256": sha256(STAGING_MANIFEST),
        "runtimeImageCount": len(stage_receipt.get("machOSHA256", {})),
        "networkSandboxPolicyRevision": 13,
        "sourceOfferOverlayPreparation": overlay_receipt,
        "hostSHA256": host_hash,
        "noticeVerification": notices,
        "releaseQualified": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--build-root", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--build-receipt", type=Path, required=True)
    parser.add_argument("--source-offer-root", type=Path, required=True)
    parser.add_argument("--source-offer-manifest-sha256", required=True,
                        help="expected SHA-256 from the frozen source-offer receipt")
    parser.add_argument("--check-only", action="store_true",
                        help="validate exact source/build bindings without signing or mutating the app")
    args = parser.parse_args()
    try:
        if args.check_only:
            app, build_root, source_root = validate_inputs(
                args.app, args.build_root, args.source_root, args.identity,
                args.build_receipt, args.source_offer_root,
                args.source_offer_manifest_sha256)
            result = {
                "status": "PASS_OWNED_WEBKIT_EXACT_BUILD_SOURCE_AND_OVERLAY_CHECK_ONLY",
                "app": str(app),
                "buildRoot": str(build_root),
                "sourceRoot": str(source_root),
                "buildReceiptSHA256": sha256(args.build_receipt),
                "sourceOfferManifestSHA256": args.source_offer_manifest_sha256,
            }
        else:
            result = package(args.app, args.build_root, args.source_root, args.identity,
                             args.build_receipt, args.source_offer_root,
                             args.source_offer_manifest_sha256)
    except (PackageError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Owned WebKit release packaging refused: {error}\n")
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

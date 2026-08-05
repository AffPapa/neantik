#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = PROJECT_ROOT / "docs" / "RUNTIME_INTEGRATION_NOTICES.md"


class RuntimeNoticesError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeNoticesError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise RuntimeNoticesError(f"{path} must contain a JSON object")
    return value


def required_text(value: object, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise RuntimeNoticesError(f"missing non-empty {field}")
    return value.strip()


def verified_license(
    *,
    project_root: Path,
    relative_path: str,
    expected_sha256: str | None = None,
) -> str:
    path = project_root / relative_path
    if not path.is_file() or path.is_symlink():
        raise RuntimeNoticesError(
            f"license must be a regular non-symlinked file: {relative_path}"
        )
    actual = sha256_file(path)
    if expected_sha256 is not None and actual != expected_sha256:
        raise RuntimeNoticesError(
            f"license SHA-256 mismatch for {relative_path}: "
            f"lock={expected_sha256} actual={actual}"
        )
    return actual


def render_notices(*, project_root: Path = PROJECT_ROOT) -> str:
    project_root = project_root.resolve()
    lock = load_json(project_root / "runtime" / "fingerprint-chromium.lock.json")
    source_contract = load_json(
        project_root / "runtime" / "chromium-151-source-contract.json"
    )
    patchset = load_json(
        project_root / "runtime" / "nevision-patches" / "series.json"
    )

    chromium = lock.get("fingerprintChromium")
    packaging = lock.get("macPackaging")
    if not isinstance(chromium, dict) or not isinstance(packaging, dict):
        raise RuntimeNoticesError(
            "runtime lock must declare fingerprintChromium and macPackaging"
        )

    chromium_version = required_text(
        chromium.get("chromiumVersion"),
        "fingerprintChromium.chromiumVersion",
    )
    target_version = required_text(
        patchset.get("targetChromiumVersion"),
        "patchset.targetChromiumVersion",
    )
    if target_version != chromium_version:
        raise RuntimeNoticesError(
            "runtime lock and owned patchset target different Chromium versions: "
            f"{chromium_version} != {target_version}"
        )
    if source_contract.get("targetChromiumVersion") != chromium_version:
        raise RuntimeNoticesError(
            "source contract and runtime lock target different Chromium versions"
        )
    binary_binding_status = required_text(
        source_contract.get("binaryBindingStatus"),
        "source contract binaryBindingStatus",
    )
    official_chromium = source_contract.get("officialChromiumBase")
    source_packaging = source_contract.get("macPackaging")
    common_chromium = source_contract.get("commonChromium")
    if not all(
        isinstance(value, dict)
        for value in (official_chromium, source_packaging, common_chromium)
    ):
        raise RuntimeNoticesError(
            "source contract must declare officialChromiumBase, macPackaging, and commonChromium"
        )

    patch_status = required_text(patchset.get("status"), "patchset.status")
    patch_groups = patchset.get("patchGroups")
    if not isinstance(patch_groups, list) or not patch_groups:
        raise RuntimeNoticesError("patchset.patchGroups must be a non-empty list")
    non_ported = [
        str(group.get("id", "<unknown>"))
        for group in patch_groups
        if not isinstance(group, dict) or group.get("status") != "ported"
    ]
    if non_ported:
        raise RuntimeNoticesError(
            "runtime notices require ported patch groups: " + ", ".join(non_ported)
        )

    chromium_license = verified_license(
        project_root=project_root,
        relative_path="runtime/licenses/Chromium-LICENSE",
        expected_sha256=required_text(
            chromium.get("licenseSHA256"),
            "fingerprintChromium.licenseSHA256",
        ),
    )
    packaging_license = verified_license(
        project_root=project_root,
        relative_path="runtime/licenses/ungoogled-chromium-macos-LICENSE",
        expected_sha256=required_text(
            packaging.get("licenseSHA256"),
            "macPackaging.licenseSHA256",
        ),
    )
    fingerprint_license = verified_license(
        project_root=project_root,
        relative_path="runtime/licenses/fingerprint-chromium-LICENSE",
    )

    runtime_status = required_text(lock.get("status"), "runtime lock status")
    chromium_repository = required_text(
        official_chromium.get("repository"), "officialChromiumBase.repository"
    )
    chromium_tag = required_text(official_chromium.get("tag"), "officialChromiumBase.tag")
    chromium_commit = required_text(official_chromium.get("commit"), "officialChromiumBase.commit")
    packaging_repository = required_text(source_packaging.get("repository"), "macPackaging.repository")
    packaging_commit = required_text(source_packaging.get("commit"), "macPackaging.commit")
    common_repository = required_text(common_chromium.get("repository"), "commonChromium.repository")
    common_tag = required_text(common_chromium.get("tag"), "commonChromium.tag")
    common_commit = required_text(common_chromium.get("commit"), "commonChromium.commit")

    return f"""# NeAntik Chromium runtime notices

This file is generated from the checked-in source contract, runtime lock, owned
patch manifest, and license files. Run:

```bash
python3 scripts/generate-runtime-integration-notices.py --check
```

Do not edit generated values by hand.

## Runtime contract

- Product: `NeAntik Browser`
- Chromium: `{chromium_version}`
- Architecture: `arm64`
- Historical published runtime lock status: `{runtime_status}`
- Next candidate source binary binding: `{binary_binding_status}`
- Owned patchset status: `{patch_status}`
- Ported patch groups: `{len(patch_groups)}`

The distributed application must also contain Chromium-generated third-party
notices and its generated SPDX SBOM. This summary does not replace either
artifact or a final legal review.

## Chromium

- Source: `{chromium_repository}`
- Tag: `{chromium_tag}`
- Commit: `{chromium_commit}`
- License: `{required_text(chromium.get("license"), "fingerprintChromium.license")}`
- Packaged license: `NeAntikRuntimeLicenses/Chromium-LICENSE`
- License SHA-256: `{chromium_license}`

## ungoogled-chromium-macos packaging source

- Source: `{packaging_repository}`
- Commit: `{packaging_commit}`
- License: `{required_text(packaging.get("license"), "macPackaging.license")}`
- Packaged license: `NeAntikRuntimeLicenses/ungoogled-chromium-macos-LICENSE`
- License SHA-256: `{packaging_license}`

## Common Chromium packaging source

- Source: `{common_repository}`
- Tag: `{common_tag}`
- Commit: `{common_commit}`

## Retained fingerprint-chromium attribution

NeAntik now applies the checked-in owned Chromium patchset from
`runtime/nevision-patches/series.json`. The BSD-3-Clause
fingerprint-chromium license remains bundled to preserve attribution for the
historical upstream implementation used to develop and validate this work.

- Packaged license: `NeAntikRuntimeLicenses/fingerprint-chromium-LICENSE`
- License SHA-256: `{fingerprint_license}`

## NeAntik owned patchset

The release-required Chromium changes are the {len(patch_groups)} ported groups
declared in `runtime/nevision-patches/series.json`. The release verifier binds
the packaged manifest and license files to the checked-in copies and separately
verifies the final source-built runtime, generated notices, and SPDX SBOM.

## Distribution boundary

This notice records source and license provenance only. `{binary_binding_status}`
means it does not attest an existing binary; only a new build that records the
emitted source-provenance hash may change that boundary. Developer ID signing,
Hardened Runtime, Apple notarization, stapling, Gatekeeper, hosted-download
verification, and a qualified GUI A -> B -> A report remain separate release
gates.
"""


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate or verify NeAntik Chromium runtime notices.",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--check",
        action="store_true",
        help="Fail unless the output already equals freshly generated notices.",
    )
    mode.add_argument(
        "--stdout",
        action="store_true",
        help="Print freshly generated notices without writing a file.",
    )
    parser.add_argument("--project-root", type=Path, default=PROJECT_ROOT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    project_root = args.project_root.resolve()
    output = args.output
    if not output.is_absolute():
        output = project_root / output
    try:
        rendered = render_notices(project_root=project_root)
        if args.stdout:
            print(rendered, end="")
            return 0
        if args.check:
            if not output.is_file() or output.is_symlink():
                raise RuntimeNoticesError(
                    f"generated notices are missing or not a regular file: {output}"
                )
            if output.read_text(encoding="utf-8") != rendered:
                raise RuntimeNoticesError(
                    "generated notices are stale; run "
                    "scripts/generate-runtime-integration-notices.py"
                )
            print("PASS: Chromium runtime notices match public lock and licenses.")
            return 0
        if output.is_symlink():
            raise RuntimeNoticesError(
                f"refusing to replace symlinked notices output: {output}"
            )
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(rendered, encoding="utf-8")
        print(output)
        return 0
    except (OSError, RuntimeNoticesError) as error:
        print(f"Runtime notices verification failed: {error}", file=sys.stderr)
        return 65


if __name__ == "__main__":
    raise SystemExit(main())

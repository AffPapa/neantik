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


def required_mapping(value: object, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise RuntimeNoticesError(f"missing object {field}")
    return value


def bound_license_sha256(
    *,
    lock_component: dict[str, Any],
    source_component: dict[str, Any],
    lock_field: str,
    source_field: str,
) -> str:
    lock_value = lock_component.get("licenseSHA256")
    if lock_value is None:
        lock_value = required_mapping(
            lock_component.get("criticalFiles"),
            f"{lock_field}.criticalFiles",
        ).get("LICENSE")
    source_value = source_component.get("licenseSHA256")
    if source_value is None:
        source_value = required_mapping(
            source_component.get("criticalFiles"),
            f"{source_field}.criticalFiles",
        ).get("LICENSE")
    lock_sha256 = required_text(lock_value, f"{lock_field}.licenseSHA256")
    source_sha256 = required_text(
        source_value,
        f"{source_field}.licenseSHA256",
    )
    if lock_sha256 != source_sha256:
        raise RuntimeNoticesError(
            f"{lock_field} and {source_field} license SHA-256 differ"
        )
    return lock_sha256


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


def render_m154_notices(*, project_root: Path, runtime_lock: Path) -> str:
    """Render candidate metadata without promoting the published runtime lock."""
    lock = load_json(runtime_lock)
    chromium = required_mapping(lock.get("fingerprintChromium"), "fingerprintChromium")
    version = chromium.get("chromiumVersion")
    contract_names = {
        "154.0.8037.93": "chromium-154-source-contract.json",
        "154.0.8037.98": "chromium-15498-source-contract.json",
    }
    if version not in contract_names:
        raise RuntimeNoticesError("explicit candidate notices require a reviewed M154 version")
    contract_name = contract_names[version]
    contract_path = project_root / "runtime" / contract_name
    if lock.get("sourceContract") != f"runtime/{contract_name}":
        raise RuntimeNoticesError("candidate must reference the exact M154 source contract")
    if lock.get("sourceContractSHA256") != sha256_file(contract_path):
        raise RuntimeNoticesError("candidate source contract SHA-256 mismatch")
    contract = load_json(contract_path)
    if contract.get("targetChromiumVersion") != version or contract.get("schemaVersion") != 2:
        raise RuntimeNoticesError("candidate source contract version/schema mismatch")
    base = required_mapping(contract.get("officialChromiumBase"), "officialChromiumBase")
    if base.get("commit") != chromium.get("commit"):
        raise RuntimeNoticesError("candidate Chromium source commit mismatch")
    groups = contract.get("ownedPatchGroupCount")
    if not isinstance(groups, int) or groups <= 0:
        raise RuntimeNoticesError("source contract must declare owned patch groups")
    lines = ["# NeAntik Chromium runtime notices", "", "## Source references", "",
             f"- Chromium: `{version}`", f"- Owned patch groups: `{groups}`",
             f"- Candidate lock SHA-256: `{sha256_file(runtime_lock)}`",
             f"- Source contract SHA-256: `{sha256_file(contract_path)}`"]
    for label, component in (("Chromium", chromium),
                             ("Common Chromium packaging", lock.get("commonChromium")),
                             ("macOS packaging", lock.get("macPackaging"))):
        component = required_mapping(component, label)
        repository = required_text(component.get("repository"), label + ".repository")
        commit = required_text(component.get("commit"), label + ".commit")
        lines.append(f"- {label}: `{repository}` at `{commit}`")
    lines.extend(["", "## Bundled licenses", "",
                  "The hashes below identify the license files included with the application.",
                  "Chromium-generated third-party notices and the SPDX SBOM are also required.", ""])
    for filename in ("Chromium-LICENSE", "ungoogled-chromium-macos-LICENSE",
                     "fingerprint-chromium-LICENSE"):
        expected = None
        if filename == "Chromium-LICENSE":
            expected = required_text(chromium.get("licenseSHA256"), "Chromium licenseSHA256")
        digest = verified_license(project_root=project_root,
                                  relative_path="runtime/licenses/" + filename,
                                  expected_sha256=expected)
        lines.append(f"- `NeAntikRuntimeLicenses/{filename}` — SHA-256 `{digest}`")
    lines.extend(["", "The fingerprint-chromium license is retained for historical attribution.",
                  "The owned M154 port is recorded under",
                  f"`runtime/nevision-patches/ports/chromium-{version}/`.", "",
                  "## Distribution boundary", "",
                  "These notices identify source references and bundled license bytes only.",
                  "They do not attest runtime behavior, security checks, signing, notarization,",
                  "Gatekeeper acceptance or publication. Those are separate release gates.", ""])
    return "\n".join(lines)


def render_notices(*, project_root: Path = PROJECT_ROOT) -> str:
    project_root = project_root.resolve()
    lock = load_json(project_root / "runtime" / "fingerprint-chromium.lock.json")
    if lock.get("fingerprintChromium", {}).get("chromiumVersion") in {"154.0.8037.93", "154.0.8037.98"}:
        return render_m154_notices(
            project_root=project_root,
            runtime_lock=project_root / "runtime/fingerprint-chromium.lock.json",
        )
    source_contract = load_json(
        project_root / "runtime" / "chromium-152-source-contract.json"
    )
    patchset = load_json(
        project_root / "runtime" / "nevision-patches" / "series.json"
    )

    chromium = lock.get("fingerprintChromium")
    packaging = lock.get("macPackaging")
    common_chromium = lock.get("commonChromium")
    if not all(
        isinstance(value, dict)
        for value in (chromium, packaging, common_chromium)
    ):
        raise RuntimeNoticesError(
            "runtime lock must declare fingerprintChromium, macPackaging, and commonChromium"
        )

    chromium_version = required_text(
        chromium.get("chromiumVersion"),
        "fingerprintChromium.chromiumVersion",
    )
    target_version = required_text(
        patchset.get("targetChromiumVersion"),
        "patchset.targetChromiumVersion",
    )
    source_target_version = required_text(
        source_contract.get("targetChromiumVersion"),
        "source contract targetChromiumVersion",
    )
    binary_binding_status = required_text(
        source_contract.get("binaryBindingStatus"),
        "source contract binaryBindingStatus",
    )
    if target_version != source_target_version:
        raise RuntimeNoticesError(
            "source contract and owned patchset target different Chromium versions: "
            f"{source_target_version} != {target_version}"
        )
    source_candidate_pending = source_target_version != chromium_version
    if source_candidate_pending and binary_binding_status != "pending-new-build":
        raise RuntimeNoticesError(
            "a source candidate may differ from the runtime lock only while its "
            "binary binding is pending-new-build"
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
            required_mapping(
                packaging.get("criticalFiles"),
                "macPackaging.criticalFiles",
            ).get("LICENSE"),
            "macPackaging.licenseSHA256",
        ),
    )
    fingerprint_license = verified_license(
        project_root=project_root,
        relative_path="runtime/licenses/fingerprint-chromium-LICENSE",
    )

    runtime_status = required_text(lock.get("status"), "runtime lock status")
    chromium_repository = required_text(
        chromium.get("repository"), "fingerprintChromium.repository"
    )
    chromium_tag = required_text(chromium.get("tag"), "fingerprintChromium.tag")
    chromium_commit = required_text(chromium.get("commit"), "fingerprintChromium.commit")
    packaging_repository = required_text(packaging.get("repository"), "macPackaging.repository")
    packaging_commit = required_text(packaging.get("commit"), "macPackaging.commit")
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
- Runtime source lock status: `{runtime_status}`
- Source contract binary binding: `{binary_binding_status}`
- Source contract candidate: `{source_target_version}`
- Owned patchset status: `{patch_status}`
- Ported patch groups: `{len(patch_groups)}`

The distributed application must also contain Chromium-generated third-party
notices and its generated SPDX SBOM. This summary does not replace either
artifact or a final legal review.

## Chromium

- Source: `{chromium_repository}`
- Tag: `{chromium_tag}`
- Commit: `{chromium_commit}`
- License: `BSD-3-Clause`
- Packaged license: `NeAntikRuntimeLicenses/Chromium-LICENSE`
- License SHA-256: `{chromium_license}`

## ungoogled-chromium-macos packaging source

- Source: `{packaging_repository}`
- Commit: `{packaging_commit}`
- License: `BSD-3-Clause`
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
    parser.add_argument("--output", type=Path)
    parser.add_argument("--runtime-lock", type=Path, help="Explicit M154 candidate lock; does not change published metadata.")
    args = parser.parse_args()

    project_root = args.project_root.resolve()
    if args.runtime_lock and not args.stdout and args.output is None:
        parser.error("--runtime-lock requires --output or --stdout to preserve published notices")
    output = args.output or DEFAULT_OUTPUT
    if args.output is None and not args.runtime_lock:
        current_lock = load_json(project_root / "runtime/fingerprint-chromium.lock.json")
        if current_lock.get("fingerprintChromium", {}).get("chromiumVersion") in {"154.0.8037.93", "154.0.8037.98"}:
            output = project_root / "docs/RUNTIME_INTEGRATION_NOTICES_154.md"
    if not output.is_absolute():
        output = project_root / output
    try:
        rendered = (render_m154_notices(project_root=project_root, runtime_lock=args.runtime_lock)
                    if args.runtime_lock else render_notices(project_root=project_root))
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
            print("PASS: Chromium runtime notices match selected metadata and licenses.")
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

#!/usr/bin/env python3
"""Copy the pinned WebKit runtime payload into a clean pre-sign Frameworks tree.

This stages runtime files only. It does not build, sign, install, or launch.
Developer headers/modules and build-time code signatures are omitted; resource
files, XPC bundles, and safe in-tree symlinks are retained for later review.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

MACHO_MAGICS = {bytes.fromhex(value) for value in (
    "cffaedfe", "cefaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"
)}


class ContractError(ValueError):
    pass


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def load_manifest(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ContractError("Runtime staging manifest is unreadable") from error
    common = {"schemaVersion", "upstream", "runtimeItems", "excludedPathComponents",
              "networkSandbox", "stagingOnly", "signingRequiredAfterStaging"}
    if not isinstance(value, dict) or value.get("schemaVersion") not in (2, 3, 4):
        raise ContractError("Runtime staging manifest has an unexpected schema")
    required = common if value["schemaVersion"] == 2 else common | {"webInspectorLicenseFiles"}
    if value["schemaVersion"] == 4:
        required = required | {"swiftCompatibilitySpan"}
    if set(value) != required:
        raise ContractError("Runtime staging manifest has an unexpected schema")
    upstream = value["upstream"]
    if (value["schemaVersion"] not in (2, 3, 4) or not isinstance(upstream, dict)
            or set(upstream) != {"repository", "commit"}
            or upstream["repository"] != "WebKit/WebKit"
            or not isinstance(upstream["commit"], str)
            or len(upstream["commit"]) != 40
            or any(c not in "0123456789abcdef" for c in upstream["commit"])
            or value["stagingOnly"] is not True
            or value["signingRequiredAfterStaging"] is not True):
        raise ContractError("Runtime staging manifest is not a pinned pre-sign manifest")
    sandbox = value["networkSandbox"]
    if (not isinstance(sandbox, dict)
            or set(sandbox) != {"path", "baseSHA256", "relayPort", "policyRevision"}
            or sandbox["policyRevision"] != 13
            or sandbox["path"] != "WebKit.framework/Versions/A/Resources/com.apple.WebKit.NetworkProcess.sb"
            or not isinstance(sandbox["baseSHA256"], str)
            or len(sandbox["baseSHA256"]) != 64
            or any(c not in "0123456789abcdef" for c in sandbox["baseSHA256"])
            or type(sandbox["relayPort"]) is not int
            or not 1 <= sandbox["relayPort"] <= 65535):
        raise ContractError("Runtime network sandbox pin is malformed")
    items = value["runtimeItems"]
    if (not isinstance(items, list) or not items or len(items) != len(set(items))
            or any(not isinstance(item, str) or not item or Path(item).is_absolute()
                   or ".." in Path(item).parts or len(Path(item).parts) != 1 for item in items)):
        raise ContractError("Runtime staging manifest contains an unsafe item")
    exclusions = value["excludedPathComponents"]
    if (not isinstance(exclusions, list) or len(exclusions) != len(set(exclusions))
            or any(not isinstance(item, str) or not item for item in exclusions)):
        raise ContractError("Runtime staging exclusions are malformed")
    if value["schemaVersion"] in (3, 4):
        licenses = value["webInspectorLicenseFiles"]
        expected_components = {"CSSDocumentation", "CodeMirror", "Esprima", "three.js"}
        if (not isinstance(licenses, list) or len(licenses) != len(expected_components)
                or not all(isinstance(item, dict) and set(item) == {
                    "component", "sourcePath", "destinationPath", "gitBlob", "sha256"
                } for item in licenses)
                or {item.get("component") for item in licenses} != expected_components):
            raise ContractError("Web Inspector license manifest is incomplete")
        for item in licenses:
            if (not isinstance(item["sourcePath"], str)
                    or not isinstance(item["destinationPath"], str)):
                raise ContractError("Web Inspector license paths must be strings")
            source_path = Path(item["sourcePath"])
            destination_path = Path(item["destinationPath"])
            if (source_path.is_absolute() or ".." in source_path.parts
                    or source_path.parts[:4] != ("Source", "WebInspectorUI", "UserInterface", "External")
                    or source_path.name != "LICENSE"
                    or destination_path.is_absolute() or ".." in destination_path.parts
                    or destination_path.parts[:5] != (
                        "WebInspectorUI.framework", "Versions", "A", "Resources", "External"
                    )
                    or destination_path.name != "LICENSE"
                    or item["component"] not in source_path.parts
                    or item["component"] not in destination_path.parts
                    or not isinstance(item["gitBlob"], str)
                    or len(item["gitBlob"]) != 40
                    or any(c not in "0123456789abcdef" for c in item["gitBlob"])
                    or not isinstance(item["sha256"], str)
                    or len(item["sha256"]) != 64
                    or any(c not in "0123456789abcdef" for c in item["sha256"])):
                raise ContractError("Web Inspector license entry is unsafe or malformed")
    if value["schemaVersion"] == 4:
        span = value["swiftCompatibilitySpan"]
        if (not isinstance(span, dict) or set(span) != {
                "packageSHA256", "sourcePath", "destinationPath", "bytes", "sha256"
            }
                or span["packageSHA256"] != "8fd03185b98fe27f54f8f523867e297ca5ff12bf8d4d63a6c627d7c60e286e845"
                or span["sourcePath"] != "runtime/owned-webkit/libswiftCompatibilitySpan.dylib"
                or span["destinationPath"] != "libswiftCompatibilitySpan.dylib"
                or type(span["bytes"]) is not int or span["bytes"] != 156544
                or not isinstance(span["sha256"], str)
                or span["sha256"] != "b4256b38185e963651938ed0406c6c8ec54299621c7fa53c5e9a0a325ca5fe4f"):
            raise ContractError("Swift CompatibilitySpan package input is not the pinned official binary")
    return value


def apply_network_sandbox(root: Path, manifest: dict) -> dict:
    """Reduce NetworkProcess IP networking to the fixed local broker."""
    config = manifest["networkSandbox"]
    if config.get("policyRevision") != 13:
        raise ContractError("Runtime network sandbox revision is not the reviewed v13 policy")
    policy = root / config["path"]
    try:
        resolved_root = root.resolve(strict=True)
        resolved_policy = policy.resolve(strict=True)
        resolved_policy.relative_to(resolved_root)
    except (OSError, ValueError) as error:
        raise ContractError("Network sandbox policy is missing or escapes staging") from error
    if policy.is_symlink() or not policy.is_file():
        raise ContractError("Network sandbox policy must be a regular in-tree file")

    # The policy and its port must stay coupled to the already implemented
    # capability-scoped broker. Never accept a drifted endpoint silently.
    source_root = Path(__file__).resolve().parents[1] / "Sources/NeAntik"
    broker = source_root / "WebKitBrokerPort.swift"
    broker_owner = source_root / "WebKitLoopbackBroker.swift"
    try:
        broker_source = broker.read_text(encoding="utf-8")
        owner_source = broker_owner.read_text(encoding="utf-8")
    except OSError as error:
        raise ContractError("WebKit loopback broker source is unavailable") from error
    expected_port = f"static let sandboxPort: UInt16 = {config['relayPort']}"
    if (expected_port not in broker_source
            or "static let sandboxPort: UInt16 = WebKitBrokerPort.sandboxPort" not in owner_source):
        raise ContractError("Sandbox relay port does not match the WebKit broker")

    original = policy.read_bytes()
    original_hash = hashlib.sha256(original).hexdigest()
    if original_hash != config["baseSHA256"]:
        raise ContractError("Network sandbox source hash does not match the pinned runtime")
    marker = b"; NeAntik owned runtime: broker-only network policy."
    if marker in original:
        raise ContractError("Network sandbox rule is already present")
    if b"(version " not in original:
        raise ContractError("Network sandbox source is not an SBPL policy")

    broad_tcp = (
        b'(with-filter (require-not (state-flag "BlockNetworkAccess"))\n'
        b'    (allow network-outbound\n'
        b'        (literal "/private/var/run/mDNSResponder")\n'
        b'        (remote tcp)))'
    )
    broad_udp = b'(allow network-outbound\n    (remote udp))'
    inherited_network = (
        b'(with-filter (require-not (state-flag "BlockNetworkAccess"))\n'
        b'    (allow network*\n'
        b'        (local udp)\n'
        b'        (remote udp)\n'
        b'        (local tcp)\n'
        b'        (remote tcp)))'
    )
    # Match the invocation form, not the macro definition that precedes it.
    delegated_network = b"\n(system-network)\n"
    networkserviceproxy_token = (
        b'(allow mach-lookup\n'
        b'    (global-name "com.apple.networkserviceproxy.fetch-token"))'
    )
    webpush_service_grants = {
        b'(allow mach-lookup (global-name "com.apple.webkit.adattributiond.service"))':
            b"; NeAntik removes WebKit attribution daemon delegation.",
        b'(allow mach-lookup (global-name "org.webkit.pcmtestdaemon.service"))':
            b"; NeAntik removes Private Click Measurement test-daemon delegation.",
        b'(allow mach-lookup (global-name "com.apple.webkit.webpushd.service"))':
            b"; NeAntik removes Web Push daemon delegation.",
        b'(allow mach-lookup (global-name "com.apple.webkit.webpushd.relocatable.service"))':
            b"; NeAntik removes relocatable Web Push daemon delegation.",
        b'(allow mach-lookup (global-name "org.webkit.webpushtestdaemon.service"))':
            b"; NeAntik removes Web Push test-daemon delegation.",
    }
    delegated_service_names = (
        "com.apple.cfnetwork.AuthBrokerAgent",
        "com.apple.cfnetwork.cfnetworkagent",
        "com.apple.nesessionmanager.flow-divert-token",
        "com.apple.nesessionmanager.content-filter",
        "com.apple.mobileasset.autoasset",
        "com.apple.webprivacyd",
        "com.apple.WebPrivacy.Service",
    )

    def remove_delegated_service(source: bytes, service_name: str) -> bytes:
        """Remove one reviewed service name from a multiline mach-lookup rule."""
        needle = f'(global-name "{service_name}")'.encode()
        lines = source.splitlines(keepends=True)
        matches = [index for index, line in enumerate(lines) if needle in line]
        if len(matches) != 1:
            raise ContractError(
                f"Pinned delegated Mach service changed: {service_name}"
            )
        index = matches[0]
        line = lines[index].rstrip(b"\n")
        if line.endswith(b"))"):
            # Keep the outer allow form's close if this was its final service.
            lines[index] = b")\n"
        else:
            del lines[index]
        return b"".join(lines)

    if (original.count(broad_tcp) != 1 or original.count(broad_udp) != 1
            or original.count(inherited_network) != 1
            or original.count(delegated_network) != 1
            or original.count(networkserviceproxy_token) != 1
            or any(original.count(grant) != 1 for grant in webpush_service_grants)
            or b"(deny syscall-unix)" not in original
            or original.count(b"SYS_socketpair") != 1
            or re.search(rb"\bSYS_socket\b", original)
            or any(original.count(f'(global-name "{name}")'.encode()) != 1
                   for name in delegated_service_names)):
        raise ContractError("Pinned WebKit network grants changed; refuse an unreviewed patch")
    # Replace the complete inherited grants. Their state flag is only set when
    # the parent is already sandbox-blocked from mDNS; NeAntik must not depend
    # on that incidental condition to prevent NetworkProcess direct egress.
    patched = original.replace(
        broad_tcp,
        b"; NeAntik removes inherited DNS and arbitrary TCP egress.",
        1,
    ).replace(broad_udp, b"; NeAntik removes WebKit's unrestricted UDP grant.", 1)
    patched = patched.replace(
        inherited_network,
        b"; NeAntik removes the state-flag-dependent general TCP/UDP grant.",
        1,
    )
    # Remove the invocation, not the upstream macro definition. The function
    # grants Mach lookups to DNS/network services and AF_SYSTEM/netsrc control
    # sockets that can route work outside the profile broker. Also remove the
    # independent Network Service Proxy token lookup. This remains a static
    # candidate until exact headed WebKit compatibility and enforcement tests.
    patched = patched.replace(
        delegated_network,
        b"; NeAntik does not invoke WebKit's delegated system-network grants.",
        1,
    )
    patched = patched.replace(
        networkserviceproxy_token,
        b"; NeAntik removes the Network Service Proxy token delegation.",
        1,
    )
    # Attribution and Web Push hand work to system daemons outside the
    # NetworkProcess socket sandbox. Keep those APIs unavailable in the
    # isolated runtime until their egress is proven profile-scoped.
    for grant, comment in webpush_service_grants.items():
        patched = patched.replace(grant, comment, 1)
    # Remove known delegates outside the NetworkProcess socket sandbox. A
    # Mach lookup can hand work to a system service, so a broker-only socket
    # grant alone is not sufficient while these unresolved egress paths remain.
    for name in delegated_service_names:
        patched = remove_delegated_service(patched, name)
    patched += (
        b"\n" + marker + b"\n"
        # Exact QA16 failed socket(AF_INET, SOCK_STREAM) with EPERM. A local
        # in-process Seatbelt probe reproduced this under the pinned policy;
        # allowing only SYS_socket made broker port 45100 reachable while
        # unrelated loopback port 45102 still failed at connect with EPERM.
        + b'(allow syscall-unix (syscall-number SYS_socket))\n'
        + f'(allow network-outbound (remote tcp "localhost:{config["relayPort"]}"))\n'.encode()
        + b'(deny mach-lookup\n'
        + b'    (global-name "com.apple.dnssd.service")\n'
        + b'    (global-name "com.apple.system.opendirectoryd.libinfo"))\n'
    )
    parent = policy.parent
    if parent.is_symlink() or not parent.is_dir():
        raise ContractError("Network sandbox parent must be a physical directory")
    descriptor, temporary = tempfile.mkstemp(prefix=".neantik-network-sandbox-", dir=parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(patched)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, policy.stat().st_mode & 0o777)
        os.replace(temporary, policy)
        directory = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
    return {
        "policyRevision": config["policyRevision"],
        "path": config["path"],
        "baseSHA256": original_hash,
        "patchedSHA256": hashlib.sha256(patched).hexdigest(),
        "relayPort": config["relayPort"],
        "policy": "v13: remove inherited direct TCP/UDP and system-daemon grants; allow SYS_socket for the fixed localhost broker; deny resolver mach endpoints and other network destinations",
        "removedInheritedNetworkStarGrant": True,
        "removedDelegatedSystemNetworkInvocation": True,
        "removedNetworkServiceProxyTokenGrant": True,
        "removedWebPushDaemonGrants": sum(b"webpush" in grant for grant in webpush_service_grants),
        "removedAttributionServiceGrants": sum(b"adattributiond" in grant for grant in webpush_service_grants),
        "removedPrivateClickTestServiceGrants": sum(b"pcmtestdaemon" in grant for grant in webpush_service_grants),
        "removedDelegatedNetworkServiceGrants": len(delegated_service_names),
        "brokerGrantUnconditional": True,
        "socketSyscallGranted": True,
        "validationScope": "staged policy transformation only; exact NetworkProcess context still needs signed headed runtime controls",
    }


def physical_directory(path: Path) -> Path:
    if path.is_symlink() or not path.is_dir():
        raise ContractError("Build root must be a physical directory")
    return path.resolve(strict=True)


def create_physical_parents(path: Path) -> None:
    missing = []
    current = path
    while not current.exists() and not current.is_symlink():
        missing.append(current)
        current = current.parent
    physical_directory(current)
    for directory in reversed(missing):
        directory.mkdir()
        physical_directory(directory)


def omitted(path: Path, excluded: set[str]) -> bool:
    return any(part in excluded for part in path.parts)


def verify_source_item(item: Path, root: Path, excluded: set[str]) -> None:
    if item.is_symlink() or not (item.is_dir() or item.is_file()):
        raise ContractError(f"Runtime item is missing or is a symlink: {item.name}")
    if item.is_file() and item.suffix == ".dylib":
        with item.open("rb") as stream:
            if stream.read(4) not in MACHO_MAGICS:
                raise ContractError(f"Runtime dylib is not Mach-O: {item.name}")
    for entry in item.rglob("*"):
        relative = entry.relative_to(item)
        if omitted(relative, excluded):
            continue
        if entry.is_symlink():
            try:
                resolved = entry.resolve(strict=True)
                resolved.relative_to(root)
            except (OSError, ValueError) as error:
                raise ContractError(f"Runtime contains an unsafe or dangling symlink: {relative}") from error


def copy_runtime(source: Path, destination: Path, manifest: dict,
                 upstream_source: Path | None = None) -> dict:
    root = physical_directory(source)
    if destination.exists() or destination.is_symlink():
        raise ContractError("Destination must not already exist")
    create_physical_parents(destination.parent)
    excluded = set(manifest["excludedPathComponents"])
    items = [root / name for name in manifest["runtimeItems"]]
    for item in items:
        verify_source_item(item, root, excluded)
    validated_licenses = []
    if manifest["schemaVersion"] in (3, 4):
        if "WebInspectorUI.framework" not in manifest["runtimeItems"] or upstream_source is None:
            raise ContractError("Web Inspector notices require the pinned source tree and framework")
        upstream_root = physical_directory(upstream_source)
        for item in manifest["webInspectorLicenseFiles"]:
            source_file = upstream_root / item["sourcePath"]
            try:
                source_file.resolve(strict=True).relative_to(upstream_root)
            except (OSError, ValueError) as error:
                raise ContractError("Web Inspector license source escapes the pinned checkout") from error
            if source_file.is_symlink() or not source_file.is_file():
                raise ContractError("Pinned Web Inspector license bytes changed")
            source_bytes = source_file.read_bytes()
            if hashlib.sha256(source_bytes).hexdigest() != item["sha256"]:
                raise ContractError("Pinned Web Inspector license bytes changed")
            # Source distribution archives have no .git metadata. Verify the
            # pinned Git object identity directly from its canonical blob
            # preimage instead of requiring a full checkout or network fetch.
            git_blob = hashlib.sha1(
                b"blob " + str(len(source_bytes)).encode("ascii") + b"\0" + source_bytes
            ).hexdigest()
            if git_blob != item["gitBlob"]:
                raise ContractError("Pinned Web Inspector license Git blob changed")
            validated_licenses.append((item, source_file))
    validated_span = None
    if manifest["schemaVersion"] == 4:
        span = manifest["swiftCompatibilitySpan"]
        project_root = Path(__file__).resolve().parents[1]
        source_file = project_root / span["sourcePath"]
        try:
            source_file.resolve(strict=True).relative_to(project_root.resolve(strict=True))
        except (OSError, ValueError) as error:
            raise ContractError("CompatibilitySpan source escapes the project root") from error
        if (source_file.is_symlink() or not source_file.is_file()
                or source_file.stat().st_size != span["bytes"]
                or digest(source_file) != span["sha256"]):
            raise ContractError("Pinned CompatibilitySpan library bytes changed")
        with source_file.open("rb") as stream:
            if stream.read(4) not in MACHO_MAGICS:
                raise ContractError("Pinned CompatibilitySpan library is not Mach-O")
        validated_span = (span, source_file)
    webkit = root / "WebKit.framework/Versions/A/WebKit"
    swift = root / "libWebKitSwift.dylib"
    if not webkit.is_file() or not swift.is_file():
        raise ContractError("Pinned build is missing WebKit or its required WebKitSwift dylib")

    destination.mkdir()
    try:
        for item in items:
            target = destination / item.name

            def ignore(directory: str, names: list[str]) -> set[str]:
                return set(names).intersection(excluded)

            if item.is_dir():
                shutil.copytree(item, target, symlinks=True, ignore=ignore, copy_function=shutil.copy2)
            else:
                shutil.copy2(item, target, follow_symlinks=False)

        # WebKit's upstream framework layout points this dylib symlink outside
        # the framework to the sibling top-level runtime item. macOS code
        # signing rejects a framework bundle that contains a symlink escaping
        # its own bundle, even when the target stays inside the wider payload.
        # Keep the top-level dylib for other runtime consumers and materialize
        # a byte-identical copy inside WebKit.framework for a sealable bundle.
        required_link = destination / "WebKit.framework/Versions/A/Frameworks/libWebKitSwift.dylib"
        if not required_link.is_symlink():
            raise ContractError("WebKit's required WebKitSwift framework link is missing")
        try:
            resolved_link = required_link.resolve(strict=True)
            resolved_link.relative_to(destination.resolve())
        except (OSError, ValueError) as error:
            raise ContractError("WebKit's required WebKitSwift link escapes staged runtime") from error
        if resolved_link != (destination / "libWebKitSwift.dylib").resolve():
            raise ContractError("WebKit's required WebKitSwift framework link targets an unexpected image")
        required_link.unlink()
        shutil.copy2(destination / "libWebKitSwift.dylib", required_link)
        if digest(required_link) != digest(destination / "libWebKitSwift.dylib"):
            raise ContractError("WebKit's embedded WebKitSwift image differs from the staged top-level image")

        for item, source_file in validated_licenses:
            target = destination / item["destinationPath"]
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists() or target.is_symlink():
                raise ContractError("Web Inspector license destination already exists")
            shutil.copy2(source_file, target, follow_symlinks=False)

        if validated_span is not None:
            item, source_file = validated_span
            target = destination / item["destinationPath"]
            if target.exists() or target.is_symlink():
                raise ContractError("CompatibilitySpan runtime destination already exists")
            shutil.copy2(source_file, target, follow_symlinks=False)
            if digest(target) != item["sha256"]:
                raise ContractError("Staged CompatibilitySpan library differs from pinned bytes")

        sandbox_result = apply_network_sandbox(destination, manifest)
        image_hashes = {}
        symlinks = []
        for entry in destination.rglob("*"):
            if omitted(entry.relative_to(destination), excluded):
                raise ContractError("Excluded developer path was copied into staging")
            if entry.is_symlink():
                try:
                    resolved = entry.resolve(strict=True)
                    resolved.relative_to(destination.resolve())
                except (OSError, ValueError) as error:
                    raise ContractError(f"Staged symlink escapes or is dangling: {entry.relative_to(destination)}") from error
                symlinks.append({"path": str(entry.relative_to(destination)), "target": os.readlink(entry)})
            elif entry.is_file():
                with entry.open("rb") as stream:
                    if stream.read(4) in MACHO_MAGICS:
                        image_hashes[str(entry.relative_to(destination))] = digest(entry)

        if required_link.is_symlink() or not required_link.is_file():
            raise ContractError("WebKit's embedded WebKitSwift image is not a regular file")
        return {
            "status": "staged-pre-sign-only",
            "upstreamCommit": manifest["upstream"]["commit"],
            "items": [p.name for p in items],
            "machOCount": len(image_hashes),
            "machOSHA256": image_hashes,
            "symlinks": symlinks,
            "excludedComponents": manifest["excludedPathComponents"],
            "networkSandbox": sandbox_result,
            "webInspectorLicenseFiles": [
                {"component": item["component"], "path": item["destinationPath"],
                 "gitBlob": item["gitBlob"], "sha256": item["sha256"]}
                for item, _ in validated_licenses
            ],
            "swiftCompatibilitySpan": None if validated_span is None else {
                "path": validated_span[0]["destinationPath"],
                "sha256": digest(destination / validated_span[0]["destinationPath"]),
                "packageSHA256": validated_span[0]["packageSHA256"],
            },
            "signingRequired": True,
            "launchQualified": False,
        }
    except Exception:
        # On failure, leave any partial output intact for diagnosis.
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_root", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--upstream-source", type=Path,
                        help="Pinned WebKit source checkout; required by manifest schema v3")
    parser.add_argument("--manifest", type=Path,
                        default=Path(__file__).resolve().parents[1] / "runtime/webkit-production-staging-v4.json")
    args = parser.parse_args()
    try:
        result = copy_runtime(args.build_root, args.destination,
                              load_manifest(args.manifest), args.upstream_source)
    except ContractError as error:
        print(json.dumps({"status": "refused", "reason": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

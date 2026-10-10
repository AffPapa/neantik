#!/usr/bin/env python3
"""Prepare public M156 source receipts without publishing private originals.

The projection retains every field and record. Known filesystem roots become
explicit aliases; unknown absolute paths or credential fields fail closed.
This is preparation only, not a source/build/runtime/release qualification.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
from urllib.parse import parse_qsl, urlsplit
from pathlib import Path
from typing import Any

VERSION = "156.0.8078.12"
COMMIT = "634b046faf2137b83af71c87baf362b533af9104"
TREE = "64e212cac2a53bcbd28b0530cf6eb092141bddec"
HASH = re.compile(r"[0-9a-f]{64}\Z")
NAME = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9._-]{0,180}\Z")
PRIVATE_MARKERS = ("/Users/", "/private/tmp/", "/var/folders/", "file://", "\\Users\\")
SECRET_KEYS = {"password", "proxyPassword", "credentials", "accessToken", "refreshToken",
               "privateKey", "cookies", "authorization", "bearerToken"}


def reject_embedded_absolute_paths(text: str, *, logical_receipt: str | None = None) -> None:
    # Public HTTP source references contain slash tokens too. Inspect their
    # authority, then mask only for this lexical check; retain original text.
    def source_url(match):
        url = urlsplit(match[0])
        if not url.hostname or url.username is not None or url.password is not None:
            raise ProjectionError("Credential-shaped source URL")
        secret_query_keys = {"accesstoken", "refreshtoken", "token", "password", "authorization",
                             "signature", "xgoogsignature", "xamzsignature", "apikey", "key"}
        if any(re.sub(r"[_-]", "", key).lower() in secret_query_keys
               for key, _ in parse_qsl(url.query, keep_blank_values=True)):
            raise ProjectionError("Credential-shaped source URL query")
        return " " * len(match[0])
    lexical = re.sub(r"\bhttps?://[^\s\"'<>),]+", source_url, text)
    if logical_receipt == "m156-acquisition-exact-gates.json":
        lexical = re.sub(r"\bgs://[^\s\"'<>),]+", source_url, lexical)
    if logical_receipt == "m156-DEPS-receipt.json":
        # Exact hash-bound DEPS excerpts contain concatenated Git URL
        # suffixes, not local filesystem paths. Preserve original snippets.
        lexical = re.sub(r"(?<=\+ )'/[A-Za-z0-9_./-]+'", "DEPS_URL_SUFFIX", lexical)
    if logical_receipt in GN_LEXICAL_RECEIPTS:
        lexical = re.sub(r"(?:gn-source:)?//[A-Za-z0-9_.+*/:@-]+(?:/[A-Za-z0-9_.+*/:@-]+)*", "GN_TOKEN", lexical)
    if logical_receipt == "m156-pinned-build-types-exact-ts-action.json":
        for alias in TS_ALIASES:
            lexical = lexical.replace("typescript-module-alias:" + alias + "|", "TS_ALIAS|")
    if (re.search(r"(?:^|\s)-(?:I|L|F|isystem|iquote|include|imacros|isysroot)/", lexical) or
        re.search(r"(?:^|[\s=:\"'])\\\\[^\s\\]", lexical)):
        raise ProjectionError("Unknown attached compiler or UNC filesystem path")
    # '+' is a valid relative source component (libc++), not a separator
    # introducing an absolute path. '=' and ':' remain separators.
    if (re.search(r"(?<![A-Za-z0-9_./+-])/(?![\s/])[^\s\"'<>),;]+", lexical) or
        re.search(r"(?<![A-Za-z0-9_./+-])//[^\s/]+", lexical) or
        re.search(r"(?<![A-Za-z0-9_])[A-Za-z]:[\\/]", lexical)):
        raise ProjectionError("Unknown embedded filesystem path in source receipt")
# These exact frozen receipts contain GN source-root tokens or TypeScript
# module aliases that look like absolute paths. Their semantics were checked
# against native GN/ts_library.py, not exempted through a generic slash rule.
LOGICAL_RECEIPTS = {
    "native-pvt-production-graph.json": "d7a459dcf687ef3ea5a3e4cd7eb34ee75e6c36210f87dd724ff000e52beec983",
    "m156-crubit-native-supersession.json": "99fd8630b4b7ae5cf2b7bb6091d99e0398bb6a1a5dd72056475e1941225d0d83",
    "m156-ift-crubit-graph.json": "c8d51be8eee0d657149daf2d2d80f263590746986dc9f0a40dbc499248ef34aa",
    "m156-web-package-crubit-graph.json": "51603c16783dec34ad2c16420048728d8212145567ffa961451b0e9ea6b586e1",
    "m156-pinned-build-types-exact-ts-action.json": "c7b985bf2f47dcd758877e89725499bb88cc51c901c4590e34087550dffbcb8e",
}
TS_ALIASES = (
    "/tools/typescript/definitions/*",
    "/third_party/node/node_modules/typescript/lib/typescript.js",
    "/third_party/node/node_modules/@typescript-eslint/*",
    "/third_party/node/node_modules/esquery/dist/esquery.esm.min.js",
    "/third_party/node/node_modules/eslint-plugin-lit/lib/index.js",
)
GN_LEXICAL_RECEIPTS = frozenset(("m156-ift-crubit-graph.json",
                               "native-pvt-production-graph.json",
                               "m156-crubit-native-supersession.json",
                               "m156-web-package-crubit-graph.json",
                               "m156-generated-effective-args.txt"))
LEXICAL_RECEIPTS = {
    **LOGICAL_RECEIPTS,
    "m156-generated-effective-args.txt": "99b5be94ded1827abf1b563e435ccb543c8a00ebbc207c70dc5dcb394f0ea82a",
    "m156-acquisition-exact-gates.json": "30138553a2a91f803b476525e607cd8e0f5cee452c923617d4a24e57c4eb133b",
    "m156-DEPS-receipt.json": "afd64acb2504007f5b37ae8e9a490e72cfd22009d27fb776a81b1dfc7bfb6c82",
}


class ProjectionError(ValueError):
    pass


def checked_file(root: Path, name: str) -> bytes:
    if not isinstance(name, str) or not NAME.fullmatch(name):
        raise ProjectionError("Unsafe receipt filename")
    root = root.resolve(strict=True)
    fd = os.open(root / name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        import stat
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_size > 64 * 1024 * 1024:
            raise ProjectionError("Receipt is not a bounded regular file")
        with os.fdopen(os.dup(fd), "rb") as stream:
            data = stream.read(64 * 1024 * 1024 + 1)
        after = os.fstat(fd)
        current = os.lstat(root / name)
        if (len(data) != before.st_size or
            (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) !=
            (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns) or
            not stat.S_ISREG(current.st_mode) or
            (current.st_dev, current.st_ino) != (before.st_dev, before.st_ino)):
            raise ProjectionError("Receipt changed while reading")
        return data
    finally:
        os.close(fd)


def strict_json(data: bytes) -> Any:
    def object_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ProjectionError("Duplicate JSON key")
            result[key] = value
        return result
    def invalid_constant(_):
        raise ProjectionError("Nonfinite JSON constant")
    return json.loads(data, object_pairs_hook=object_pairs, parse_constant=invalid_constant)


def project_value(value: Any, roots: dict[str, Path], *, depth: int = 0,
                  logical_receipt: str | None = None) -> Any:
    if depth > 64:
        raise ProjectionError("Receipt nesting exceeds bound")
    if isinstance(value, dict):
        result = {}
        for key, child in value.items():
            if not isinstance(key, str) or key.lower() in {s.lower() for s in SECRET_KEYS}:
                raise ProjectionError("Credential-shaped field in source receipt")
            normalized_key = project_value(key, roots, depth=depth + 1, logical_receipt=logical_receipt)
            if normalized_key in result:
                raise ProjectionError("Root normalization creates duplicate keys")
            result[normalized_key] = project_value(child, roots, depth=depth + 1, logical_receipt=logical_receipt)
        return result
    if isinstance(value, list):
        return [project_value(child, roots, depth=depth + 1, logical_receipt=logical_receipt) for child in value]
    if not isinstance(value, str):
        return value
    text = value
    # Longest root first preserves the distinction between src, its build
    # workspace, and the surrounding research checkout. Alias syntax cannot
    # be mistaken for a filesystem path used by the packaging scripts.
    replacements = sorted(((str(p), alias) for alias, p in roots.items()),
                          key=lambda item: len(item[0]), reverse=True)
    for original, alias in replacements:
        text = re.sub(re.escape(original) + r"(?=/|\s|$|['\"),])",
                      lambda _: "root:" + alias, text)
    if text.startswith(("/", "\\")) or any(marker in text for marker in PRIVATE_MARKERS):
        raise ProjectionError("Unknown private path in source receipt")
    reject_embedded_absolute_paths(text, logical_receipt=logical_receipt)
    return text


def projection(raw: bytes, name: str, roots: dict[str, Path]) -> dict[str, Any]:
    if not NAME.fullmatch(name):
        raise ProjectionError("Unsafe receipt filename")
    for alias, root in roots.items():
        if not re.fullmatch(r"[a-z][a-z0-9-]{0,40}", alias) or not root.is_absolute():
            raise ProjectionError("Invalid explicit root alias")
    if len(set(str(p) for p in roots.values())) != len(roots):
        raise ProjectionError("Ambiguous duplicate root aliases")
    logical_receipt = None
    if name in LEXICAL_RECEIPTS:
        if hashlib.sha256(raw).hexdigest() != LEXICAL_RECEIPTS[name]:
            raise ProjectionError("Logical path receipt changed and requires fresh semantic review")
        logical_receipt = name
    if name.endswith(".json"):
        original = strict_json(raw)
        if name in LOGICAL_RECEIPTS:
            if hashlib.sha256(raw).hexdigest() != LOGICAL_RECEIPTS[name]:
                raise ProjectionError("Logical path receipt changed and requires fresh semantic review")
            if name in GN_LEXICAL_RECEIPTS:
                def gn_tokens(value):
                    if isinstance(value, dict):
                        return {gn_tokens(key): gn_tokens(child) for key, child in value.items()}
                    if isinstance(value, list):
                        return [gn_tokens(child) for child in value]
                    return "gn-source:" + value if isinstance(value, str) and value.startswith("//") else value
                original = gn_tokens(original)
            else:
                command = original.get("command")
                if not isinstance(command, list) or len(command) < 39 or command[33] != "--path_mappings":
                    raise ProjectionError("Reviewed TypeScript mapping segment missing")
                for index, alias in enumerate(TS_ALIASES, 34):
                    mapping = command[index]
                    if not isinstance(mapping, str) or mapping.count("|") != 1:
                        raise ProjectionError("Invalid TypeScript mapping")
                    left, right = mapping.split("|")
                    if left != alias or not right or Path(right).is_absolute() or any(p in mapping for p in PRIVATE_MARKERS):
                        raise ProjectionError("Unreviewed TypeScript alias or target")
                    # The exact frozen original hash binds the reviewed RHS
                    # and its successful native declared-dependency action.
                    command[index] = "typescript-module-alias:" + mapping
        payload = project_value(original, roots, logical_receipt=logical_receipt)
        kind = "json"
    elif name.endswith((".txt", ".patch")):
        payload = project_value(raw.decode("utf-8"), roots, logical_receipt=logical_receipt)
        kind = "text"
    else:
        raise ProjectionError("Unsupported source receipt type")
    return {"schemaVersion": 1, "status": "source-projection-prepared-unqualified",
            "receipt": name, "originalReceiptSHA256": hashlib.sha256(raw).hexdigest(),
            "normalizationPolicy": "explicit-root-aliases-v1; every field and record retained",
            "reviewedLogicalReceiptSHA256": LOGICAL_RECEIPTS.get(name),
            "rootAliases": sorted(roots), "payloadType": kind, "payload": payload,
            "releaseReady": False}


def prepare(artifact_root: Path, roots: dict[str, Path], output: Path, *,
            contract_name: str, contract_sha256: str) -> dict[str, Any]:
    # The caller must choose the preserved freeze explicitly. A moving
    # "latest" or a historical default could omit a subsequent source fix.
    match = re.fullmatch(r"m156-prebuild-attempt-([1-9][0-9]*)-contract\.json", contract_name)
    if not match or not isinstance(contract_sha256, str) or not HASH.fullmatch(contract_sha256):
        raise ProjectionError("Explicit reviewed prebuild contract and digest required")
    raw_contract = checked_file(artifact_root, contract_name)
    if hashlib.sha256(raw_contract).hexdigest() != contract_sha256:
        raise ProjectionError("Selected prebuild contract changed")
    contract = strict_json(raw_contract)
    if (not isinstance(contract, dict) or type(contract.get("schemaVersion")) is not int or
        contract["schemaVersion"] != 1 or contract.get("chromiumVersion") != VERSION or
        contract.get("officialCommit") != COMMIT or contract.get("officialTree") != TREE or
        contract.get("status") != "native-inputs-frozen-unqualified" or
        contract.get("releaseReady") is not False or not isinstance(contract.get("inputs"), dict) or
        type(contract.get("attempt")) is not int or contract["attempt"] != int(match[1])):
        raise ProjectionError("Unreviewed prebuild contract")
    inputs = dict(contract["inputs"])
    replay_name = "m156-full-source-replay.json"
    if replay_name not in inputs:
        raise ProjectionError("Missing full ordered replay")
    replay_raw = checked_file(artifact_root, replay_name)
    if hashlib.sha256(replay_raw).hexdigest() != inputs[replay_name]:
        raise ProjectionError("Frozen replay changed")
    replay = strict_json(replay_raw)
    if not isinstance(replay.get("inputReceipts"), dict):
        raise ProjectionError("Missing replay lineage receipts")
    for name, digest in replay["inputReceipts"].items():
        if name in inputs and inputs[name] != digest:
            raise ProjectionError("Conflicting frozen receipt hashes")
        inputs[name] = digest
    inputs[contract_name] = hashlib.sha256(raw_contract).hexdigest()
    prepared = []
    for name, expected in sorted(inputs.items()):
        if not isinstance(expected, str) or not HASH.fullmatch(expected):
            raise ProjectionError("Invalid frozen receipt hash")
        raw = checked_file(artifact_root, name)
        if hashlib.sha256(raw).hexdigest() != expected:
            raise ProjectionError("Frozen receipt changed")
        prepared.append((name, projection(raw, name, roots)))
    # Validate all inputs before creating any output. O_EXCL preserves prior
    # projections; changing the preparation requires a new owned directory.
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    records = []
    for name, document in prepared:
        data = (json.dumps(document, sort_keys=True, indent=2, ensure_ascii=True) + "\n").encode()
        target = output / (name + ".projection.json")
        fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
        records.append({"path": target.name, "originalReceiptSHA256": document["originalReceiptSHA256"],
                        "projectionSHA256": hashlib.sha256(data).hexdigest()})
    registry = {"schemaVersion": 1, "status": "source-projection-prepared-unqualified",
                "chromiumVersion": VERSION, "originalPrebuildContract": contract_name,
                "originalPrebuildContractSHA256": hashlib.sha256(raw_contract).hexdigest(),
                "projectionToolSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                "receipts": records, "releaseReady": False,
                "limits": ["No final source snapshot or binary binding", "No signed runtime or GUI evidence",
                           "Not a replacement for original receipts or source/runtime qualification"]}
    data = (json.dumps(registry, sort_keys=True, indent=2) + "\n").encode()
    fd = os.open(output / "registry.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
    return registry


def verify_prepared(output: Path, *, contract_name: str, contract_sha256: str,
                    registry_sha256: str) -> dict[str, Any]:
    """Verify closed projection/lineage bindings, never infer build readiness.

    Both the original freeze and derivative registry digests are independent
    inputs. The registry pins payload bytes, while the freeze pins original
    receipt identities. Neither authenticates a new binary.
    """
    if output.is_symlink() or not output.is_dir():
        raise ProjectionError("Projection store must be a regular directory")
    if (not isinstance(contract_name, str) or not NAME.fullmatch(contract_name) or
        not isinstance(contract_sha256, str) or not HASH.fullmatch(contract_sha256) or
        not isinstance(registry_sha256, str) or not HASH.fullmatch(registry_sha256)):
        raise ProjectionError("Explicit reviewed contract binding required")
    registry_raw = checked_file(output, "registry.json")
    if hashlib.sha256(registry_raw).hexdigest() != registry_sha256:
        raise ProjectionError("Pinned projection registry changed")
    registry = strict_json(registry_raw)
    registry_keys = {"schemaVersion", "status", "chromiumVersion", "originalPrebuildContract",
                     "originalPrebuildContractSHA256", "projectionToolSHA256", "receipts",
                     "releaseReady", "limits"}
    if (not isinstance(registry, dict) or set(registry) != registry_keys or
        type(registry["schemaVersion"]) is not int or registry["schemaVersion"] != 1 or
        registry["status"] != "source-projection-prepared-unqualified" or
        registry["chromiumVersion"] != VERSION or registry["releaseReady"] is not False or
        registry["originalPrebuildContract"] != contract_name or
        registry["originalPrebuildContractSHA256"] != contract_sha256 or
        not isinstance(registry["projectionToolSHA256"], str) or
        not HASH.fullmatch(registry["projectionToolSHA256"]) or
        not isinstance(registry["receipts"], list) or not 1 <= len(registry["receipts"]) <= 256):
        raise ProjectionError("Projection registry identity mismatch")
    project_value(registry, {})
    documents, actual_names = {}, {"registry.json"}
    expected_document_keys = {"schemaVersion", "status", "receipt", "originalReceiptSHA256",
                             "normalizationPolicy", "reviewedLogicalReceiptSHA256", "rootAliases",
                             "payloadType", "payload", "releaseReady"}
    for record in registry["receipts"]:
        if not isinstance(record, dict) or set(record) != {"path", "originalReceiptSHA256", "projectionSHA256"}:
            raise ProjectionError("Projection record schema mismatch")
        name = record["path"]
        if not isinstance(name, str) or not NAME.fullmatch(name) or not name.endswith(".projection.json") or name in actual_names:
            raise ProjectionError("Unsafe or duplicate projection filename")
        actual_names.add(name)
        for key in ("originalReceiptSHA256", "projectionSHA256"):
            if not isinstance(record[key], str) or not HASH.fullmatch(record[key]):
                raise ProjectionError("Invalid projection digest")
        raw = checked_file(output, name)
        if hashlib.sha256(raw).hexdigest() != record["projectionSHA256"]:
            raise ProjectionError("Projection changed")
        doc = strict_json(raw)
        if (not isinstance(doc, dict) or set(doc) != expected_document_keys or
            type(doc["schemaVersion"]) is not int or doc["schemaVersion"] != 1 or
            doc["status"] != registry["status"] or doc["releaseReady"] is not False or
            not isinstance(doc["receipt"], str) or not NAME.fullmatch(doc["receipt"]) or
            doc["receipt"] + ".projection.json" != name or
            doc["originalReceiptSHA256"] != record["originalReceiptSHA256"] or
            doc["normalizationPolicy"] != "explicit-root-aliases-v1; every field and record retained" or
            doc["reviewedLogicalReceiptSHA256"] != LOGICAL_RECEIPTS.get(doc["receipt"]) or
            not isinstance(doc["rootAliases"], list) or
            not all(isinstance(a, str) and re.fullmatch(r"[a-z][a-z0-9-]{0,40}", a) for a in doc["rootAliases"]) or
            doc["rootAliases"] != sorted(set(doc["rootAliases"])) or
            not isinstance(doc["payloadType"], str) or doc["payloadType"] not in {"json", "text"} or
            (doc["payloadType"] == "text" and not isinstance(doc["payload"], str))):
            raise ProjectionError("Projection document identity mismatch")
        # The normalized payload must itself be safe. Never recover private
        # roots for publication, or discard a field that fails this check.
        logical_receipt = None
        if doc["receipt"] in LEXICAL_RECEIPTS:
            if doc["originalReceiptSHA256"] != LEXICAL_RECEIPTS[doc["receipt"]]:
                raise ProjectionError("Logical path receipt original digest mismatch")
            logical_receipt = doc["receipt"]
        project_value(doc["payload"], {}, logical_receipt=logical_receipt)
        documents[doc["receipt"]] = doc
    if {p.name for p in output.iterdir()} != actual_names:
        raise ProjectionError("Projection store has missing or extra files")
    if contract_name not in documents or documents[contract_name]["originalReceiptSHA256"] != contract_sha256:
        raise ProjectionError("Projection does not bind selected freeze")
    contract = documents[contract_name]["payload"]
    if (not isinstance(contract, dict) or contract.get("chromiumVersion") != VERSION or
        contract.get("officialCommit") != COMMIT or contract.get("officialTree") != TREE or
        contract.get("releaseReady") is not False or not isinstance(contract.get("inputs"), dict)):
        raise ProjectionError("Projected prebuild identity mismatch")
    expected = dict(contract["inputs"])
    replay_name = "m156-full-source-replay.json"
    if replay_name not in expected or replay_name not in documents:
        raise ProjectionError("Projected ordered replay missing")
    replay = documents[replay_name]["payload"]
    if not isinstance(replay, dict) or not isinstance(replay.get("inputReceipts"), dict):
        raise ProjectionError("Projected replay lineage missing")
    for name, digest in replay["inputReceipts"].items():
        if name in expected and expected[name] != digest:
            raise ProjectionError("Conflicting projected lineage")
        expected[name] = digest
    expected[contract_name] = contract_sha256
    if set(documents) != set(expected) or any(documents[n]["originalReceiptSHA256"] != h for n, h in expected.items()):
        raise ProjectionError("Projected receipt set or original bindings mismatch")
    return registry

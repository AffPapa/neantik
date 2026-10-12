#!/usr/bin/env python3
"""Scan every reachable Git blob without ever printing matched secret text."""

from __future__ import annotations

import argparse
import ast
import re
import subprocess
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SCAN_CHUNK_BYTES = 1024 * 1024
SCAN_OVERLAP_BYTES = 1024
FORBIDDEN_NAMES = {".env", "credentials.json", "service-account.json"}
FORBIDDEN_SUFFIXES = {
    ".key",
    ".mobileprovision",
    ".p12",
    ".p8",
    ".pem",
    ".provisionprofile",
}
FORBIDDEN_PARTS = {".credentials", ".secrets", "private-keys", "private_keys"}
SECRET_PATTERNS = {
    "private key": re.compile(rb"BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY"),
    "GitHub token": re.compile(
        rb"\b(?:gh[opsu]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b"
    ),
    "AWS access key": re.compile(rb"\bAKIA[0-9A-Z]{16}\b"),
    "OpenAI API key": re.compile(rb"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b"),
    "Slack token": re.compile(rb"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"),
    "Stripe live secret": re.compile(rb"\bsk_live_[A-Za-z0-9]{16,}\b"),
    "Google API key": re.compile(rb"\bAIza[0-9A-Za-z_-]{30,}\b"),
    "GitLab token": re.compile(rb"\bglpat-[A-Za-z0-9_-]{20,}\b"),
    "wallet recovery phrase": re.compile(
        rb"\b(?:mnemonic|seed[ _-]?phrase)\s*[:=]\s*"
        rb"(?:[a-z]{3,16}\s+){11,23}[a-z]{3,16}\b",
        re.IGNORECASE,
    ),
}


class HistorySecretAuditError(RuntimeError):
    pass


def nonsecret_pem_check_spans(data: bytes, paths: set[str]) -> list[tuple[int, int]]:
    """A header-only startswith check contains no key bytes. Everything else
    retains the original marker refusal, including incomplete/invalid source.
    There are no filename hashes or per-repository secret exceptions.
    """
    if not paths or not all(Path(path).suffix == ".py" for path in paths):
        return []
    try:
        tree = ast.parse(data.decode("utf-8"))
    except (SyntaxError, UnicodeError, ValueError, RecursionError):
        return []
    lines = data.splitlines(keepends=True); offsets = [0]
    for line in lines: offsets.append(offsets[-1] + len(line))
    headers = {"-----BEGIN " + kind + "PRIVATE KEY-----\n" for kind in ("", "RSA ", "EC ", "OPENSSH ")}
    spans = []
    for call in ast.walk(tree):
        if not (isinstance(call, ast.Call) and isinstance(call.func, ast.Attribute)
                and call.func.attr == "startswith" and len(call.args) == 1 and not call.keywords):
            continue
        value = call.args[0]
        if not isinstance(value, ast.Constant) or not isinstance(value.value, (str, bytes)):
            continue
        content = value.value.decode("ascii", errors="replace") if isinstance(value.value, bytes) else value.value
        if content in headers:
            spans.append((offsets[value.lineno - 1] + value.col_offset,
                          offsets[value.end_lineno - 1] + value.end_col_offset))
    return spans


def git_output(repo: Path, *arguments: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(repo), *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise HistorySecretAuditError(detail or "Git command failed")
    return result.stdout


def reachable_objects(repo: Path) -> dict[str, set[str]]:
    objects: dict[str, set[str]] = {}
    output = git_output(repo, "rev-list", "--objects", "--all")
    for raw_line in output.splitlines():
        oid_bytes, separator, path_bytes = raw_line.partition(b" ")
        oid = oid_bytes.decode("ascii", errors="strict")
        paths = objects.setdefault(oid, set())
        if separator:
            paths.add(path_bytes.decode("utf-8", errors="surrogateescape"))
    return objects


def unsafe_path_reason(path: str) -> str | None:
    candidate = Path(path)
    if candidate.name in FORBIDDEN_NAMES:
        return "credential-bearing filename"
    if candidate.suffix.lower() in FORBIDDEN_SUFFIXES:
        return "credential-bearing suffix"
    if any(part in FORBIDDEN_PARTS for part in candidate.parts):
        return "private secret-store path"
    return None


def read_batch_header(stream: object) -> tuple[str, str, int]:
    raw_header = stream.readline()
    if not raw_header:
        raise HistorySecretAuditError("git cat-file ended unexpectedly")
    header = raw_header.decode("ascii", errors="replace").strip().split()
    if len(header) != 3 or not header[2].isdigit():
        raise HistorySecretAuditError("git cat-file returned malformed metadata")
    return header[0], header[1], int(header[2])


def audit(repo: Path = PROJECT_ROOT) -> tuple[int, int]:
    repo = repo.resolve()
    if git_output(repo, "rev-parse", "--is-shallow-repository").strip() != b"false":
        raise HistorySecretAuditError(
            "Cannot audit complete history from a shallow repository. Fetch full history first."
        )
    objects = reachable_objects(repo)
    findings: list[str] = []
    # rev-list deduplicates objects and retains only one traversal path for a
    # blob. Check names independently, including both sides of every rename
    # and merge, so moving identical bytes cannot hide an earlier secret file.
    historical_paths = git_output(
        repo, "log", "--all", "--format=", "--name-only", "-z", "--no-renames", "--root", "-m"
    )
    for raw_path in sorted(set(historical_paths.split(b"\0"))):
        if not raw_path:
            continue
        path = raw_path.decode("utf-8", errors="surrogateescape")
        if reason := unsafe_path_reason(path):
            findings.append(f"historical path {path}: {reason}")
    scanned_blobs = 0
    process = subprocess.Popen(
        ["git", "-C", str(repo), "cat-file", "--batch"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert process.stdin is not None
    assert process.stdout is not None
    try:
        for requested_oid, paths in objects.items():
            process.stdin.write(requested_oid.encode("ascii") + b"\n")
            process.stdin.flush()
            actual_oid, object_type, size = read_batch_header(process.stdout)
            # Scan large blobs as well; a size ceiling must not silently turn
            # unexamined public bytes into a passing privacy verdict.
            remaining = size
            tail = b""
            matched_labels: set[str] = set()
            while remaining:
                chunk = process.stdout.read(min(remaining, SCAN_CHUNK_BYTES))
                if not chunk:
                    raise HistorySecretAuditError("git cat-file returned truncated data")
                remaining -= len(chunk)
                if object_type == "blob":
                    window = tail + chunk
                    for label, pattern in SECRET_PATTERNS.items():
                        matches = list(pattern.finditer(window))
                        marker_spans = nonsecret_pem_check_spans(window, paths) if label == "private key" and matches else []
                        if any(not any(start <= match.start() and match.end() <= end for start, end in marker_spans)
                               for match in matches):
                            matched_labels.add(label)
                    tail = window[-SCAN_OVERLAP_BYTES:]
            if process.stdout.read(1) != b"\n":
                raise HistorySecretAuditError("git cat-file returned truncated data")
            if actual_oid != requested_oid or object_type != "blob":
                continue
            scanned_blobs += 1
            display_path = sorted(paths)[0] if paths else "<unknown-path>"
            for path in sorted(paths):
                if reason := unsafe_path_reason(path):
                    findings.append(f"{requested_oid} {display_path}: {reason}")
                    break
            for label in matched_labels:
                findings.append(f"{requested_oid} {display_path}: {label}")
        process.stdin.close()
        return_code = process.wait(timeout=30)
        if return_code != 0:
            detail = (process.stderr.read() if process.stderr else b"").decode(
                "utf-8", errors="replace"
            ).strip()
            raise HistorySecretAuditError(detail or "git cat-file failed")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        process.stdout.close()
        if process.stderr is not None:
            process.stderr.close()
    if findings:
        raise HistorySecretAuditError(
            "reachable Git history contains potential secret material:\n  - "
            + "\n  - ".join(sorted(set(findings)))
        )
    return len(objects), scanned_blobs


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Scan every reachable Git blob for credential files and known secret formats."
    )
    parser.add_argument("--repo", type=Path, default=PROJECT_ROOT)
    arguments = parser.parse_args()
    try:
        objects, blobs = audit(arguments.repo)
    except (OSError, subprocess.SubprocessError, HistorySecretAuditError) as error:
        print(f"Git history secret audit failed: {error}", file=sys.stderr)
        return 1
    print(
        "PASS: reachable Git history contains no credential files or recognized "
        f"secret material; {blobs} unique blob(s), {objects} object(s) checked."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

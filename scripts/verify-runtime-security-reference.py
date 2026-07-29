#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import urllib.parse
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BASELINE = PROJECT_ROOT / "runtime" / "security-baseline.json"
CHROME_RELEASES_HOST = "chromereleases.googleblog.com"
VERSION_RE = re.compile(r"\b\d+\.\d+\.\d+\.\d+\b")


class SecurityReferenceError(ValueError):
    pass


def load_baseline(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SecurityReferenceError(f"Cannot read runtime security baseline: {error}") from error
    if not isinstance(value, dict):
        raise SecurityReferenceError("Runtime security baseline must be a JSON object")
    return value


def assert_official_reference(url: object) -> str:
    if not isinstance(url, str) or not url.startswith("https://"):
        raise SecurityReferenceError("Baseline reference must be an HTTPS URL")
    parsed = urllib.parse.urlparse(url)
    if parsed.netloc != CHROME_RELEASES_HOST:
        raise SecurityReferenceError(
            f"Baseline reference must use {CHROME_RELEASES_HOST}, got {parsed.netloc}"
        )
    return url


def fetch_text(url: str, *, timeout: int = 20) -> str:
    completed = subprocess.run(
        [
            "curl",
            "-fsSL",
            "--max-time",
            str(timeout),
            "--user-agent",
            "NeAntikReleaseVerifier/1.0",
            url,
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        error = completed.stderr.strip() or f"curl exited {completed.returncode}"
        raise SecurityReferenceError(f"Cannot fetch baseline reference: {error}")
    return completed.stdout


def version_appears_in_text(version: str, text: str, versions: set[str]) -> bool:
    if version in versions:
        return True
    prefix, suffix = version.rsplit(".", 1)
    return f"{prefix}." in text and f"/.{suffix}" in text


def verify_reference(
    *,
    baseline_path: Path,
    html_text: str | None = None,
) -> str:
    baseline = load_baseline(baseline_path)
    if baseline.get("schemaVersion") != 1:
        raise SecurityReferenceError("Unexpected runtime security baseline schema")
    minimum = baseline.get("minimumPublicChromiumVersion")
    if not isinstance(minimum, str) or not VERSION_RE.fullmatch(minimum):
        raise SecurityReferenceError("minimumPublicChromiumVersion must be a four-part version")
    also_observed = baseline.get("alsoObservedPublicChromiumVersions")
    if not isinstance(also_observed, list) or not all(
        isinstance(version, str) and VERSION_RE.fullmatch(version)
        for version in also_observed
    ):
        raise SecurityReferenceError(
            "alsoObservedPublicChromiumVersions must be a list of four-part versions"
        )
    if baseline.get("channel") != "Desktop Stable":
        raise SecurityReferenceError("Baseline channel must be Desktop Stable")
    platforms = baseline.get("platforms")
    if not isinstance(platforms, list) or "macOS" not in platforms:
        raise SecurityReferenceError("Baseline platforms must include macOS")
    security_fix_count = baseline.get("securityFixCount")
    if not isinstance(security_fix_count, int) or security_fix_count < 1:
        raise SecurityReferenceError("Baseline securityFixCount must be positive")
    if baseline.get("referenceTitle") != "Stable Channel Update for Desktop":
        raise SecurityReferenceError("Baseline referenceTitle must match Desktop Stable post")
    if baseline.get("sourceLabel") != "Chrome Releases":
        raise SecurityReferenceError("Baseline sourceLabel must be Chrome Releases")
    release_boundary = baseline.get("releaseBoundary")
    if not isinstance(release_boundary, str) or "not a live updater" not in release_boundary:
        raise SecurityReferenceError("Baseline releaseBoundary must declare manual refresh")
    reference = assert_official_reference(baseline.get("reference"))
    text = html_text if html_text is not None else fetch_text(reference)
    versions = set(VERSION_RE.findall(text))
    if minimum not in versions:
        raise SecurityReferenceError(
            f"Baseline version {minimum} was not found in the official reference"
        )
    for version in also_observed:
        if not version_appears_in_text(version, text, versions):
            raise SecurityReferenceError(
                f"Observed public version {version} was not found in the official reference"
            )
    if "Stable Channel Update for Desktop" not in text:
        raise SecurityReferenceError(
            "Official reference does not look like a desktop Stable Channel update"
        )
    if "security" not in text.lower():
        raise SecurityReferenceError("Official reference does not mention security")
    if "mac" not in text.lower():
        raise SecurityReferenceError("Official reference does not mention Mac")
    if str(security_fix_count) not in text:
        raise SecurityReferenceError(
            f"Official reference does not mention securityFixCount {security_fix_count}"
        )
    return (
        "Runtime security baseline reference verified: "
        f"{minimum} appears in official Chrome Releases source {reference}; "
        f"also observed {', '.join(also_observed)}; security fixes {security_fix_count}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify NeAntik's Chromium security baseline against its official source.",
    )
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
    parser.add_argument(
        "--html-file",
        type=Path,
        help="Use saved HTML instead of fetching the baseline reference.",
    )
    args = parser.parse_args()
    html_text = args.html_file.read_text(encoding="utf-8") if args.html_file else None
    try:
        print(verify_reference(baseline_path=args.baseline, html_text=html_text))
    except SecurityReferenceError as error:
        raise SystemExit(str(error)) from error
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SUITES = (
    "AppPathsTests",
    "BrowserLaunchBuilderTests",
    "BrowserProcessManagerTests",
    "BrowserRuntimeInspectorTests",
    "BrowserRuntimePreflightTests",
    "FingerprintAuditTests",
    "KeychainStoreTests",
    "LaunchIntentTests",
    "ProfileStoreTests",
    "ProxyTesterTests",
    "RuntimePreferenceStoreTests",
    "TelemetryTests",
)
SUITE_TIMEOUT_SECONDS = 120


def main() -> None:
    temporary_root = Path(
        tempfile.mkdtemp(prefix="neantik-swift-ci-", dir="/private/tmp")
    )
    try:
        swiftpm_home = temporary_root / "swiftpm-home"
        module_cache = temporary_root / "module-cache"
        build_root = temporary_root / "build"
        swiftpm_home.mkdir()
        module_cache.mkdir()
        build_root.mkdir()

        environment = os.environ.copy()
        environment["SWIFTPM_HOME"] = str(swiftpm_home)
        environment["CLANG_MODULE_CACHE_PATH"] = str(module_cache)

        for suite in SUITES:
            print(f"Running Swift suite: {suite}", flush=True)
            command = [
                "swift",
                "test",
                "--disable-sandbox",
                "--scratch-path",
                str(build_root),
                "--filter",
                suite,
            ]
            try:
                subprocess.run(
                    command,
                    cwd=PROJECT_ROOT,
                    env=environment,
                    check=True,
                    timeout=SUITE_TIMEOUT_SECONDS,
                )
            except subprocess.TimeoutExpired as error:
                raise SystemExit(
                    f"FAIL: Swift suite {suite} exceeded "
                    f"{SUITE_TIMEOUT_SECONDS} seconds"
                ) from error

        print(f"PASS: {len(SUITES)} Swift suites completed independently.")
    finally:
        if (
            temporary_root.parent == Path("/private/tmp")
            and temporary_root.name.startswith("neantik-swift-ci-")
        ):
            shutil.rmtree(temporary_root)


if __name__ == "__main__":
    main()

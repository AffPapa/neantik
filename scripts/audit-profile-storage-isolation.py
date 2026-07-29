#!/usr/bin/env python3

import argparse
import datetime
import hashlib
import html
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class IsolationAuditError(RuntimeError):
    pass


class IsolationPageHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        operation = query.get("op", ["read"])[0]
        value = query.get("value", [""])[0]
        operation_json = json.dumps(operation)
        value_json = json.dumps(value)
        document = f"""<!doctype html>
<meta charset="utf-8">
<title>NeAntik profile isolation audit</title>
<pre id="result">pending</pre>
<script>
const operation = {operation_json};
const value = {value_json};
if (operation === "set") {{
  document.cookie = "nevision_isolation=" + encodeURIComponent(value) +
    "; Path=/; Max-Age=3600; SameSite=Lax";
  localStorage.setItem("nevision_isolation", value);
}}
const cookies = Object.fromEntries(
  document.cookie.split(";").map(item => item.trim()).filter(Boolean).map(
    item => {{
      const separator = item.indexOf("=");
      return [
        item.slice(0, separator),
        decodeURIComponent(item.slice(separator + 1))
      ];
    }}
  )
);
document.getElementById("result").textContent =
  "NV_RESULT:" + JSON.stringify({{
    cookie: cookies.nevision_isolation || "",
    storage: localStorage.getItem("nevision_isolation") || ""
  }});
</script>
"""
        payload = document.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, _format, *_arguments):
        return


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_dumped_result(output):
    match = re.search(r"NV_RESULT:(\{[^<]+\})", output)
    if match is None:
        raise IsolationAuditError("headless_shell output has no NV_RESULT marker")
    try:
        result = json.loads(html.unescape(match.group(1)))
    except json.JSONDecodeError as error:
        raise IsolationAuditError("NV_RESULT marker is invalid JSON") from error
    if (
        not isinstance(result, dict)
        or not isinstance(result.get("cookie"), str)
        or not isinstance(result.get("storage"), str)
    ):
        raise IsolationAuditError("NV_RESULT payload is incomplete")
    return result


def verify_sequence(captures, token_a, token_b):
    expected = {
        "aSet": {"cookie": token_a, "storage": token_a},
        "aRead1": {"cookie": token_a, "storage": token_a},
        "bReadEmpty": {"cookie": "", "storage": ""},
        "bSet": {"cookie": token_b, "storage": token_b},
        "aRead2": {"cookie": token_a, "storage": token_a},
        "bRead": {"cookie": token_b, "storage": token_b},
    }
    issues = []
    for name, expected_value in expected.items():
        if captures.get(name) != expected_value:
            issues.append(
                f"{name} expected {expected_value} but got {captures.get(name)}"
            )
    return issues


def run_capture(runtime, data_directory, base_url, operation, value=""):
    query = urllib.parse.urlencode({"op": operation, "value": value})
    url = f"{base_url}/?{query}"
    arguments = [
        str(runtime),
        "--dump-dom",
        "--single-process",
        "--no-sandbox",
        "--disable-background-networking",
        "--disable-extensions",
        "--no-first-run",
        "--no-default-browser-check",
        f"--user-data-dir={data_directory}",
        url,
    ]
    process = subprocess.run(
        arguments,
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    if process.returncode != 0:
        error_tail = process.stderr.strip()[-2000:]
        raise IsolationAuditError(
            f"headless_shell exited {process.returncode}: {error_tail}"
        )
    return parse_dumped_result(process.stdout)


def run_audit(runtime, report_path):
    if not runtime.is_absolute() or not runtime.is_file():
        raise IsolationAuditError("runtime must be an existing absolute file")
    if runtime.name != "headless_shell" or not os.access(runtime, os.X_OK):
        raise IsolationAuditError("runtime must be an executable headless_shell")
    if not report_path.is_absolute():
        raise IsolationAuditError("report path must be absolute")

    file_result = subprocess.run(
        ["/usr/bin/file", str(runtime)],
        check=False,
        capture_output=True,
        text=True,
    )
    if file_result.returncode != 0 or "arm64" not in file_result.stdout:
        raise IsolationAuditError("runtime is not an ARM64 executable")
    version_result = subprocess.run(
        [str(runtime), "--version"],
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    version = version_result.stdout.strip()
    if version_result.returncode != 0 or not version:
        raise IsolationAuditError("runtime version is unavailable")

    token_a = f"A-{uuid.uuid4().hex}"
    token_b = f"B-{uuid.uuid4().hex}"
    captures = {}

    with tempfile.TemporaryDirectory(
        prefix="nevision-profile-isolation-"
    ) as temporary_directory:
        root = Path(temporary_directory)
        profile_a = root / "Profile-A"
        profile_b = root / "Profile-B"
        profile_a.mkdir(mode=0o700)
        profile_b.mkdir(mode=0o700)

        server = ThreadingHTTPServer(("127.0.0.1", 0), IsolationPageHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base_url = f"http://127.0.0.1:{server.server_port}"
        try:
            captures["aSet"] = run_capture(
                runtime,
                profile_a,
                base_url,
                "set",
                token_a,
            )
            captures["aRead1"] = run_capture(
                runtime,
                profile_a,
                base_url,
                "read",
            )
            captures["bReadEmpty"] = run_capture(
                runtime,
                profile_b,
                base_url,
                "read",
            )
            captures["bSet"] = run_capture(
                runtime,
                profile_b,
                base_url,
                "set",
                token_b,
            )
            captures["aRead2"] = run_capture(
                runtime,
                profile_a,
                base_url,
                "read",
            )
            captures["bRead"] = run_capture(
                runtime,
                profile_b,
                base_url,
                "read",
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

    issues = verify_sequence(captures, token_a, token_b)
    report = {
        "schemaVersion": 1,
        "createdAt": datetime.datetime.now(
            datetime.timezone.utc
        ).isoformat().replace("+00:00", "Z"),
        "executionMode": "headless-single-process-storage-diagnostic",
        "runtime": {
            "path": str(runtime),
            "version": version,
            "architecture": "arm64",
            "sha256": sha256_file(runtime),
        },
        "sequence": [
            "A set",
            "A read",
            "B empty",
            "B set",
            "A unchanged",
            "B unchanged",
        ],
        "surfaces": ["cookie", "localStorage"],
        "captures": captures,
        "issues": issues,
        "verdict": "verified" if not issues else "failed",
        "boundary": (
            "Real Blink storage behavior in an explicit single-process "
            "diagnostic; this does not replace the production GUI fingerprint gate."
        ),
    }
    report_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_report = report_path.with_name(
        f".{report_path.name}.{uuid.uuid4().hex}.tmp"
    )
    try:
        temporary_report.write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        os.chmod(temporary_report, 0o600)
        temporary_report.replace(report_path)
        os.chmod(report_path, 0o600)
    finally:
        if temporary_report.exists():
            temporary_report.unlink()

    if issues:
        raise IsolationAuditError("storage isolation failed: " + " ".join(issues))
    return report


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Verify persistent cookie/localStorage isolation across two "
            "source-built Chromium user-data directories."
        )
    )
    parser.add_argument("--runtime", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    arguments = parser.parse_args()
    try:
        report = run_audit(arguments.runtime, arguments.report)
    except (
        IsolationAuditError,
        OSError,
        subprocess.SubprocessError,
    ) as error:
        print(f"Profile storage isolation audit failed: {error}", file=sys.stderr)
        return 1

    print("Profile storage isolation verified.")
    print(f"Runtime: {report['runtime']['version']}")
    print("Surfaces: cookie, localStorage")
    print(f"Report: {arguments.report}")
    print(
        "DIAGNOSTIC ONLY: production GUI fingerprint qualification remains separate."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

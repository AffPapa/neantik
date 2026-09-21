#!/usr/bin/env python3
"""Measure a minimized, self-hosted loopback HTTP network smoke report.

This intentionally reports only partial evidence. It proves that a local
HTTP request reached a temporary self-hosted endpoint; it does not prove proxy
egress, DNS behavior, TLS, HTTP/2/3, or WebRTC behavior.
"""

from __future__ import annotations

import argparse
import json
import sys
import threading
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import URLError


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )


def _unverified_report() -> dict[str, object]:
    return {
        "status": "unverified",
        "routeMode": "unknown",
        "effectiveHTTPRouteObserved": False,
        "dnsPath": "not_observed",
        "negotiatedProtocol": "unknown",
        "tlsObserved": False,
        "webrtcDirectCandidates": 0,
        "bypassDetected": False,
        "generatedAt": _utc_now(),
    }


class _Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 - stdlib callback name
        body = b"neantik-network-harness\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *_args: object) -> None:
        return


def run() -> dict[str, object]:
    try:
        server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    except OSError:
        return _unverified_report()
    ready = threading.Event()

    def serve() -> None:
        ready.set()
        server.serve_forever()

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    report: dict[str, object]
    try:
        if not ready.wait(timeout=3):
            return _unverified_report()
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(
            f"http://127.0.0.1:{server.server_port}/health", timeout=3
        ) as response:
            if response.status != 200 or response.read() != b"neantik-network-harness\n":
                raise RuntimeError("self-hosted endpoint returned an unexpected response")
        report = {
            "status": "partial",
            "routeMode": "direct",
            "effectiveHTTPRouteObserved": True,
            "dnsPath": "not_observed",
            "negotiatedProtocol": "http1",
            "tlsObserved": False,
            "webrtcDirectCandidates": 0,
            "bypassDetected": False,
            "generatedAt": _utc_now(),
        }
    except (OSError, RuntimeError, TimeoutError, URLError):
        report = _unverified_report()
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)
        if thread.is_alive():
            report = _unverified_report()
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true")
    parser.parse_args(argv)
    try:
        report = run()
    except (OSError, RuntimeError, TimeoutError, URLError) as error:
        print(
            f"network reality harness failed: {type(error).__name__}",
            file=sys.stderr,
        )
        return 1
    print(json.dumps(report, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

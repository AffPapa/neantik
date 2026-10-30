#!/usr/bin/env python3
"""Exact loopback-only HTTP CONNECT A/B fixture for the approved NeAntik 0a78 QA.

Proxy A accepts only the configured CONNECT authority, then one exact tunneled
GET. Direct B has a separate origin route. If A falls back to Direct, the
origin returns and records a distinct bypass sentinel. No external socket,
credential, DNS lookup, or real profile is used.
"""
from __future__ import annotations

import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import signal
import socket
import stat
import tempfile
import threading
import time

ROOT = Path("/private/tmp/neantik-webkit-shared-broker-pool-qa-root-20261021")
PROFILES_SHA256 = "b33dff8fc1177ab273c759e34d3d2eac0f7191ce4d206bedc930e6a70e553c3a"
MODE = ROOT / "fixture-mode.json"
LEDGER = ROOT / "fixture-ledger.jsonl"
PROXY_PORT = 45101
ORIGIN_PORT = 45102
EXPECTED_HOST = f"127.0.0.1:{ORIGIN_PORT}"
QA_DOM_PERSISTENCE = False
LOCK = threading.Lock()


class FixtureError(ValueError):
    pass


def classify_connect_authority(authority: str, host: str | None) -> str:
    """Accept only the exact authority used by ProxyRelayWireCodec.httpConnect."""
    return "accepted" if authority == EXPECTED_HOST and host == EXPECTED_HOST else "authority-mismatch"


def classify_tunneled_request(request_line: str, host: str | None) -> str:
    """Accept only the declared QA paths carried after CONNECT."""
    allowed = {"GET /proxy-a HTTP/1.1"}
    if QA_DOM_PERSISTENCE:
        allowed.update(("GET /qa-dom-written HTTP/1.1", "GET /qa-dom-restored HTTP/1.1"))
    return "accepted" if request_line in allowed and host == EXPECTED_HOST else "request-mismatch"


def proxy_body(path: str) -> bytes:
    if path != "/proxy-a":
        return b"NEANTIK_QA_BEACON_OK"
    if not QA_DOM_PERSISTENCE:
        return b"<!doctype html><meta charset=utf-8><body>NEANTIK_QA_PROXY_A_OK</body>"
    return b'''<!doctype html><meta charset=utf-8><title>NeAntik QA</title>
<body><div id="neantik-qa-sentinel">NEANTIK_QA_DOM_WAITING</div>
<script>
(() => {
  const key = 'neantik-qa-dom-v1';
  const value = 'neantik-qa-disposable-marker';
  let sent = false;
  function report() {
    if (sent || document.visibilityState !== 'visible') return;
    const element = document.getElementById('neantik-qa-sentinel');
    const box = element.getBoundingClientRect();
    if (!box.width || !box.height || getComputedStyle(element).visibility !== 'visible') return;
    const prior = localStorage.getItem(key);
    let phase;
    if (prior === null) {
      localStorage.setItem(key, value);
      phase = 'written';
    } else if (prior === value) {
      phase = 'restored';
    } else {
      element.textContent = 'NEANTIK_QA_DOM_INVALID';
      return;
    }
    sent = true;
    element.textContent = 'NEANTIK_QA_DOM_' + phase.toUpperCase();
    location.hash = 'qa-' + phase;
    fetch('/qa-dom-' + phase, {cache: 'no-store'}).catch(() => {});
  }
  document.addEventListener('visibilitychange', report);
  if (document.readyState === 'complete') report();
  else window.addEventListener('load', report, {once: true});
})();
</script></body>'''


def checked_root(*, initial: bool = False) -> None:
    try:
        info = ROOT.lstat()
        profile = ROOT / "profiles.json"
        profile_info = profile.lstat()
        digest = hashlib.sha256(profile.read_bytes()).hexdigest()
    except OSError as exc:
        raise FixtureError("exact QA root/profile is unavailable") from exc
    if (ROOT.resolve() != ROOT or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o700 or not stat.S_ISREG(profile_info.st_mode)
            or profile_info.st_uid != os.getuid() or stat.S_IMODE(profile_info.st_mode) != 0o600
            or (initial and digest != PROFILES_SHA256)):
        raise FixtureError("exact owner-only 0a78 A/B fixture refused")
    try:
        document = json.loads(profile.read_text(encoding="utf-8"))
        profiles = {item["name"]: item for item in document["profiles"]}
        a = profiles["Shared Broker QA 20261021 A proxy"]
        b = profiles["Shared Broker QA 20261021 B direct"]
        if (document.get("schemaVersion") != 5 or len(profiles) != 2
                or a.get("id") != "89B59F14-2CA7-47FA-A6B4-7878B297D238"
                or b.get("id") != "404CF496-1856-411E-88AE-54924D71ADD9"
                or a.get("engine") != "webkit" or b.get("engine") != "webkit"
                or a.get("webKitRuntimeGeneration") != "isolatedV1"
                or b.get("webKitRuntimeGeneration") != "isolatedV1"
                or a.get("startURL") != "http://127.0.0.1:45102/proxy-a"
                or b.get("startURL") != "http://127.0.0.1:45102/direct-b"
                or a.get("proxy") != {"host": "127.0.0.1", "kind": "http", "port": 45101, "username": ""}
                or b.get("proxy") is not None):
            raise FixtureError("A/B route identity/configuration changed")
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise FixtureError("A/B profile metadata is unreadable or changed") from exc


def record(kind: str, **fields: object) -> None:
    entry = {"monotonicNs": time.monotonic_ns(), "kind": kind, **fields}
    data = (json.dumps(entry, sort_keys=True, separators=(",", ":")) + "\n").encode()
    with LOCK:
        fd = os.open(LEDGER, os.O_WRONLY | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0))
        try:
            os.write(fd, data)
            os.fsync(fd)
        finally:
            os.close(fd)


def mode_available() -> bool:
    info = MODE.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        raise FixtureError("proxy mode file ownership/mode refused")
    value = json.loads(MODE.read_text(encoding="utf-8"))
    if set(value) != {"available"} or type(value["available"]) is not bool:
        raise FixtureError("proxy mode file schema refused")
    return value["available"]


def write_mode(available: bool) -> None:
    checked_root()
    if not MODE.exists() or MODE.is_symlink():
        raise FixtureError("proxy fixture is not running or mode file is unsafe")
    fd, raw = tempfile.mkstemp(prefix=".fixture-mode-", dir=ROOT)
    temp = Path(raw)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump({"available": available}, stream, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, MODE)
        dir_fd = os.open(ROOT, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    finally:
        try:
            temp.unlink()
        except FileNotFoundError:
            pass


def read_events() -> list[dict[str, object]]:
    checked_root(initial=True)
    info = LEDGER.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        raise FixtureError("event ledger ownership/mode refused")
    events = []
    for line in LEDGER.read_text(encoding="utf-8").splitlines():
        item = json.loads(line)
        if not isinstance(item, dict) or type(item.get("monotonicNs")) is not int:
            raise FixtureError("malformed fixture event")
        events.append(item)
    return events


def summarize(events: list[dict[str, object]]) -> dict[str, object]:
    proxy_ok = [e for e in events if e.get("kind") == "proxy-response-complete"]
    direct_b = [e for e in events if e.get("kind") == "direct-b-response-complete"]
    refused = [e for e in events if e.get("kind") == "proxy-refused"]
    bypass = [e for e in events if e.get("kind") == "direct-proxy-a-bypass"]
    bad = [e for e in events if e.get("kind") == "proxy-authority-mismatch"]
    tunnel_bad = [e for e in events if e.get("kind") in {
        "proxy-tunneled-request-mismatch", "proxy-unexpected-credentials", "proxy-response-write-failed"
    }]
    if not proxy_ok or not direct_b or not refused or bypass or bad or tunnel_bad:
        raise FixtureError("A/B, refusal, recovery, exact-authority or no-Direct evidence is incomplete")
    if any(e.get("authority") != EXPECTED_HOST or e.get("path") != "/proxy-a" for e in proxy_ok + refused):
        raise FixtureError("proxy event authority/path does not match exact configured target")
    kinds = [e.get("kind") for e in events]
    first_refusal = kinds.index("proxy-refused")
    if not any(kind == "proxy-response-complete" for kind in kinds[first_refusal + 1:]):
        raise FixtureError("proxy did not recover after the refused request")
    return {"proxyResponses": len(proxy_ok), "directBResponses": len(direct_b),
            "proxyRefusals": len(refused), "directFallbacks": len(bypass),
            "authorityMismatches": len(bad), "sequence": kinds,
            "result": "loopback route evidence only; headed page sentinel must be visually confirmed"}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "NeAntikLoopbackQA/1"

    def log_message(self, *_: object) -> None:
        return

    def reply(self, body: str) -> bool:
        data = ("<!doctype html><meta charset=utf-8><title>NeAntik QA</title><body>" + body + "</body>").encode()
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data)
            self.wfile.flush()
            return True
        except (BrokenPipeError, ConnectionResetError, OSError):
            return False
        finally:
            self.close_connection = True


class Origin(Handler):
    def do_GET(self) -> None:
        if self.path == "/direct-b" and self.headers.get("Host") == EXPECTED_HOST:
            ok = self.reply("NEANTIK_QA_DIRECT_B_OK")
            if ok:
                record("direct-b-response-complete", authority=EXPECTED_HOST, path=self.path)
        elif self.path == "/proxy-a":
            record("direct-proxy-a-bypass", authority=self.headers.get("Host", ""), path=self.path)
            self.reply("NEANTIK_QA_DIRECT_BYPASS_DETECTED")
        else:
            self.send_error(404)


class Proxy(Handler):
    def do_CONNECT(self) -> None:
        result = classify_connect_authority(self.path, self.headers.get("Host"))
        if result != "accepted":
            record("proxy-authority-mismatch", authority=self.headers.get("Host", ""), target=self.path[:256])
            self.send_error(502)
            return
        if self.headers.get("Proxy-Authorization") is not None:
            record("proxy-unexpected-credentials")
            self.send_error(407)
            return
        if not mode_available():
            try:
                self.send_error(502, "controlled upstream unavailable")
            except OSError:
                pass
            record("proxy-refused", authority=EXPECTED_HOST, path="/proxy-a")
            self.close_connection = True
            return

        # Model an HTTP proxy: acknowledge the CONNECT, then inspect one
        # bounded request inside the tunnel. No destination socket is opened.
        self.send_response_only(200, "Connection Established")
        self.end_headers()
        self.wfile.flush()
        self.connection.settimeout(5)
        try:
            request_line = self.rfile.readline(8193)
            if len(request_line) > 8192 or not request_line.endswith(b"\r\n"):
                raise FixtureError("tunneled request line exceeded bound")
            decoded_line = request_line[:-2].decode("ascii", errors="strict")
            total = len(request_line)
            tunneled_host = None
            while True:
                line = self.rfile.readline(8193)
                total += len(line)
                if len(line) > 8192 or total > 8192 or not line.endswith(b"\r\n"):
                    raise FixtureError("tunneled request headers exceeded bound")
                if line == b"\r\n":
                    break
                name, separator, value = line[:-2].partition(b":")
                if not separator:
                    raise FixtureError("malformed tunneled header")
                if name.lower() == b"host":
                    if tunneled_host is not None:
                        raise FixtureError("duplicate tunneled Host header")
                    tunneled_host = value.strip().decode("ascii", errors="strict")
            if classify_tunneled_request(decoded_line, tunneled_host) != "accepted":
                record("proxy-tunneled-request-mismatch", request=decoded_line[:128], host=tunneled_host or "")
                return
            path = decoded_line.split(" ", 2)[1]
            body = proxy_body(path)
            response = (b"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                        b"Cache-Control: no-store\r\nConnection: close\r\nContent-Length: "
                        + str(len(body)).encode("ascii") + b"\r\n\r\n" + body)
            self.wfile.write(response)
            self.wfile.flush()
            if path == "/proxy-a":
                record("proxy-response-complete", authority=EXPECTED_HOST, path=path)
            else:
                record("qa-dom-" + path.rsplit("-", 1)[1], authority=EXPECTED_HOST, path=path)
        except (OSError, UnicodeError, FixtureError):
            record("proxy-response-write-failed", authority=EXPECTED_HOST, path="/proxy-a")
        finally:
            self.close_connection = True


def available_port(port: int) -> bool:
    with socket.socket() as probe:
        try:
            probe.bind(("127.0.0.1", port))
        except OSError:
            return False
        return True


def serve() -> None:
    checked_root()
    if MODE.exists() or LEDGER.exists() or MODE.is_symlink() or LEDGER.is_symlink():
        raise FixtureError("fixture files already exist; refusing overwrite")
    if not available_port(PROXY_PORT) or not available_port(ORIGIN_PORT):
        raise FixtureError("QA loopback port already in use")
    mode_fd = os.open(MODE, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        os.write(mode_fd, b'{"available":true}\n')
        os.fsync(mode_fd)
    finally:
        os.close(mode_fd)
    ledger_fd = os.open(LEDGER, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    os.close(ledger_fd)
    servers = []
    threads = []
    try:
        for port, handler in ((ORIGIN_PORT, Origin), (PROXY_PORT, Proxy)):
            server = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
            server.daemon_threads = True
            servers.append(server)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            threads.append(thread)
        print(json.dumps({"status": "ready", "bind": "127.0.0.1 only", "proxyPort": PROXY_PORT,
                          "originPort": ORIGIN_PORT, "candidateSHA256": "0a78e1a80cdca443699859104ab36e272f25fa7ceeea7e88d702d563d0f596d9"}), flush=True)
        signal.pause()
    finally:
        for server in reversed(servers):
            server.shutdown()
            server.server_close()
        for thread in threads:
            thread.join(timeout=3)
        # Preserve mode/ledger as QA evidence until explicit verify/cleanup.


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument("--serve", action="store_true")
    actions.add_argument("--proxy-unavailable", action="store_true")
    actions.add_argument("--proxy-available", action="store_true")
    actions.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    try:
        if args.serve:
            serve()
        elif args.proxy_unavailable:
            write_mode(False)
            print("PASS: only the QA loopback proxy fixture is marked unavailable")
        elif args.proxy_available:
            write_mode(True)
            print("PASS: only the QA loopback proxy fixture is marked available")
        else:
            print(json.dumps(summarize(read_events()), indent=2))
    except (FixtureError, OSError, ValueError, json.JSONDecodeError) as exc:
        parser.exit(1, "QA fixture refused: " + str(exc) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

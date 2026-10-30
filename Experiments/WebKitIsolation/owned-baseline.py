#!/usr/bin/env python3
"""Bounded headed A/B baseline, before any QA network rule is installed.

Only the two signed disposable hosts and literal endpoints bound by this process
are used. This baseline measures reachability, never network isolation.
"""
import argparse
import datetime
import hashlib
import hmac
import http.server
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import sys
import threading
import time
import urllib.request
import uuid

PACKAGE = Path(__file__).resolve().parent
ROOT = PACKAGE.parents[1]
TEAM = "H6VGU2M6JD"
BASE = "app.neantik.desktop.network-qa"


def parse_observation(data, *, role, run_id, exit_code, timed_out):
    """Reject missing, duplicate or foreign receipts; a timeout never passes."""
    if timed_out or exit_code != 0 or len(data) > 16384:
        raise ValueError("Host timeout, failed exit or oversized observation")
    lines = data.splitlines()
    if len(lines) != 1:
        raise ValueError("Expected exactly one host observation")
    value = json.loads(lines[0])
    required = {"schemaVersion", "mode", "role", "runID", "outcome", "uptime", "timestamp"}
    optional = {"httpStatus", "errorDomain", "errorCode"}
    if (not isinstance(value, dict) or not required <= value.keys()
            or value.keys() - required - optional
            or value["schemaVersion"] != 1 or value["mode"] != "headed-owned-endpoint"
            or value["role"] != role or value["runID"] != run_id
            or value["outcome"] not in {"loaded", "failure", "timeout", "refused", "unexpected-response"}
            or type(value["uptime"]) not in (int, float) or not 0 < value["uptime"] < 1e12):
        raise ValueError("Invalid or foreign host observation")
    if not isinstance(value["timestamp"], str) or datetime.datetime.fromisoformat(value["timestamp"].replace("Z", "+00:00")).tzinfo is None:
        raise ValueError("Expected a timezone-qualified observation timestamp")
    if "httpStatus" in value and (type(value["httpStatus"]) is not int or not 100 <= value["httpStatus"] <= 599):
        raise ValueError("Invalid HTTP status")
    if "errorDomain" in value and value["errorDomain"] not in {"NSURLErrorDomain", "WKErrorDomain", "other"}:
        raise ValueError("Unredacted error domain")
    if "errorCode" in value and type(value["errorCode"]) is not int:
        raise ValueError("Invalid error code")
    if value["outcome"] == "loaded" and (value.get("httpStatus") != 200 or "errorCode" in value or "errorDomain" in value):
        raise ValueError("Contradictory success observation")
    if value["outcome"] == "failure" and not {"errorDomain", "errorCode"} <= value.keys():
        raise ValueError("Failure requires typed error evidence")
    return value


def reached_origin(observation, origin_events):
    """Require both actual browser completion and the corresponding own origin."""
    return (observation.get("outcome") == "loaded"
            and observation.get("httpStatus") == 200 and len(origin_events) == 1)


class Origin:
    def __init__(self, address, run_id, labels, *, proof_key=None, port=0):
        self.events = {label: [] for label in labels}
        self.lock = threading.Lock()
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                prefix = "/__neantik_isolation_qa/" + run_id + "/"
                label = self.path[len(prefix):] if self.path.startswith(prefix) else ""
                if label == "__proof" and proof_key is not None:
                    challenge = self.headers.get("X-NeAntik-QA-Challenge", "")
                    try:
                        if str(uuid.UUID(challenge)) != challenge:
                            raise ValueError("challenge")
                    except ValueError:
                        self.send_error(404)
                        return
                    message = f"{run_id}\n{challenge}\n{owner.port}".encode()
                    body = json.dumps({"proof": hmac.new(proof_key, message, hashlib.sha256).hexdigest()}).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Cache-Control", "no-store")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                if label not in owner.events:
                    self.send_error(404)
                    return
                with owner.lock:
                    owner.events[label].append({"timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                                                "uptime": time.monotonic()})
                body = b"<!doctype html><title>Owned baseline</title><p>Disposable QA origin</p>"
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_):
                pass  # Never retain client addresses or request headers.

        class Server(http.server.ThreadingHTTPServer):
            address_family = socket.AF_INET6 if ":" in address else socket.AF_INET

            def server_bind(self):
                if self.address_family == socket.AF_INET6:
                    self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                super().server_bind()

        self.server = Server((address, port), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.address, self.port = self.server.server_address[:2]
        self.run_id = run_id

    def url(self, label):
        host = f"[{self.address}]" if ":" in self.address else self.address
        return f"http://{host}:{self.port}/__neantik_isolation_qa/{self.run_id}/{label}"

    def snapshot(self, label):
        with self.lock:
            return list(self.events[label])

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


def command(args):
    result = subprocess.run(args, capture_output=True, timeout=30)
    if result.returncode:
        raise ValueError("Required preflight failed")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--signed-root", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--manifest-sha256", required=True)
    parser.add_argument("--private-address", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    address = ipaddress.ip_address(args.private_address)
    if address.version != 4 or not any(address in ipaddress.ip_network(net) for net in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")):
        raise ValueError("Expected an owned RFC1918 address; server bind must also succeed")
    raw = args.manifest.read_bytes()
    if hashlib.sha256(raw).hexdigest() != args.manifest_sha256:
        raise ValueError("Frozen signed-host manifest mismatch")
    manifest = json.loads(raw)
    run_id = manifest["runID"]
    if str(uuid.UUID(run_id)) != run_id:
        raise ValueError("Invalid run identity")
    hosts = {}
    for role, suffix, name in (("A", ".profilehost", "NeAntik Isolation Host.app"),
                                ("B", ".control", "NeAntik Isolation Control.app")):
        app = args.signed_root / name
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if info["CFBundleIdentifier"] != BASE + suffix or info["NeAntikQARunID"] != run_id:
            raise ValueError("Wrong signed QA host")
        executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
        entry = manifest["hosts"][role]
        if executable.is_symlink() or hashlib.sha256(executable.read_bytes()).hexdigest() != entry["executableSHA256"]:
            raise ValueError("Signed executable mismatch")
        requirement = f'anchor apple generic and identifier "{BASE + suffix}" and certificate leaf[subject.OU] = "{TEAM}" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
        command(["/usr/bin/codesign", "--verify", "--strict", "-R=" + requirement, str(app)])
        command(["/usr/sbin/spctl", "--assess", "--type", "execute", str(app)])
        hosts[role] = executable
    spec = importlib.util.spec_from_file_location("qa_preparation", PACKAGE / "prepare-qa.py")
    prep = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(prep)
    prep.distinct_host_uuids(*(hosts[role].read_bytes() for role in ("A", "B")))
    # No settings writes. Stop rather than test with a lingering active rule.
    extensions = command(["/usr/bin/systemextensionsctl", "list"]).decode()
    qa_lines = [line for line in extensions.splitlines() if BASE + ".proxy" in line]
    if any("[activated disabled]" not in line for line in qa_lines):
        raise ValueError("QA extension must be absent or durably disabled")
    if b"NeAntik owned WebKit isolation QA" in command(["/usr/sbin/scutil", "--nc", "list"]):
        raise ValueError("Remove the owned QA rule before a baseline")
    readiness = json.loads(command([sys.executable, "-B", str(ROOT / "scripts/native-qa-readiness.py"), "--check"]))
    output = args.output.absolute()
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    report = {"status": "RUNNING", "runID": run_id, "signedManifestSHA256": args.manifest_sha256,
              "admission": readiness, "cases": [], "scope": "headed reachability baseline;no network rule;not isolation proof",
              "networkSettingsChanged": False, "realProfilesOrKeychainUsed": False}

    def save():
        (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")

    origins = []
    save()
    try:
        for target, bind in (("loopback", "127.0.0.1"), ("private", str(address))):
            labels = ["server-control", "b-baseline", "a-baseline"]
            origin = Origin(bind, run_id, labels)
            origins.append(origin)
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(origin.url("server-control"), timeout=3) as response:
                if response.status != 200 or len(origin.snapshot("server-control")) != 1:
                    raise ValueError("Own origin control failed")
            for role in ("B", "A"):
                label = role.lower() + "-baseline"
                env = os.environ.copy()
                env["NEANTIK_OWNED_QA_ENDPOINT"] = origin.url(label)
                start = time.monotonic()
                process = subprocess.Popen([str(hosts[role])], env=env, stdout=subprocess.PIPE,
                                           stderr=subprocess.DEVNULL, start_new_session=True)
                timed_out = False
                forced = False
                try:
                    data, _ = process.communicate(timeout=25)
                except subprocess.TimeoutExpired:
                    timed_out = True
                    process.terminate()  # Only the exact subprocess created above.
                    try:
                        data, _ = process.communicate(timeout=3)
                    except subprocess.TimeoutExpired:
                        forced = True
                        process.kill()
                        data, _ = process.communicate(timeout=3)
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=3)
                case = {"role": role, "target": target, "seconds": time.monotonic() - start,
                        "exitCode": process.returncode, "outerTimeout": timed_out, "forcedKill": forced,
                        "originEvents": origin.snapshot(label), "originControl": origin.snapshot("server-control")}
                try:
                    case["observation"] = parse_observation(data, role=role, run_id=run_id,
                                                           exit_code=process.returncode, timed_out=timed_out)
                    case["reachable"] = reached_origin(case["observation"], case["originEvents"])
                except (ValueError, TypeError, KeyError):
                    case["observationRejected"] = True
                    case["reachable"] = False
                report["cases"].append(case)
                save()
        report["status"] = "BASELINE PASS;NOT ISOLATION PROOF" if all(x["reachable"] for x in report["cases"]) else "BASELINE FAILED;DIAGNOSE RETAINED TYPED OBSERVATIONS"
    except BaseException:
        report["status"] = "HARNESS OR SETUP FAILED;NOT A PRODUCT RESULT"
        raise
    finally:
        for origin in origins:
            origin.close()
        report["ownedOriginsClosed"] = True
        save()
    print(json.dumps({"status": report["status"], "cases": len(report["cases"]),
                      "reachable": sum(x["reachable"] for x in report["cases"])}))
    return 0 if all(x["reachable"] for x in report["cases"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())

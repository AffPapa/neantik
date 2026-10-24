#!/usr/bin/env python3
"""Run the bounded loopback WebKit A/B fixture for one frozen Dev QA receipt."""
from __future__ import annotations

import argparse
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import signal
import stat
import sys
import threading
import uuid

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def regular_owner_only(path: Path, mode: int) -> bool:
    info = path.lstat()
    return (stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
            and stat.S_IMODE(info.st_mode) == mode)


def verify_mixed_pair(path: Path, prefix: str, proxy_port: int, origin_port: int,
                      *, proxy_target_host: str = "127.0.0.1",
                      require_shared_identity: bool,
                      dom_persistence: bool = False) -> None:
    """Check owned Proxy A and independent system-WebKit Direct B."""
    document = json.loads(path.read_text())
    profiles = document.get("profiles")
    if document.get("schemaVersion") != 5 or not isinstance(profiles, list) or len(profiles) != 2:
        raise ValueError("live QA pair shape changed")
    by_name = {item.get("name"): item for item in profiles if isinstance(item, dict)}
    if len(by_name) != 2:
        raise ValueError("live QA pair names changed")
    expected = {
        prefix + " A proxy": ("proxy-a", "isolatedV1", proxy_target_host,
                               {"kind": "http", "host": "127.0.0.1",
                                "port": proxy_port, "username": ""}),
        prefix + " B direct": ("direct-b", "system", "127.0.0.1", None),
    }
    ids = set()
    identities = []
    for name, (route, generation, target_host, proxy) in expected.items():
        profile = by_name.get(name)
        if (profile is None or profile.get("engine") != "webkit"
                or profile.get("webKitRuntimeGeneration") != generation
                or profile.get("startURL") != f"http://{target_host}:{origin_port}/{route}"
                or (dom_persistence and name.endswith(" A proxy")
                    and profile.get("startupMode") != "restoreSession")
                or profile.get("proxy") != proxy
                or not isinstance(profile.get("identity"), dict)
                or any(isinstance(value, dict) and "password" in value for value in profile.values())):
            raise ValueError("live QA route or isolation changed")
        try:
            uuid.UUID(str(profile.get("id")))
        except (TypeError, ValueError, AttributeError) as error:
            raise ValueError("live QA profile ID invalid") from error
        ids.add(profile.get("id"))
        identities.append(profile["identity"])
    if len(ids) != 2:
        raise ValueError("live QA profile IDs collided")
    if require_shared_identity and identities[0] != identities[1]:
        raise ValueError("initial A/B synthetic identity differs")


def load_fixture(receipt_path: Path, prefix: str):
    receipt = json.loads(receipt_path.read_text())
    if receipt.get("fixtureScriptSHA256") and digest(Path(__file__)) != receipt["fixtureScriptSHA256"]:
        raise ValueError("frozen recipient QA fixture changed")
    proxy_target_host = receipt.get("proxyTargetHost", "127.0.0.1")
    dom_persistence = receipt.get("domPersistence", False)
    if proxy_target_host not in ("127.0.0.1", "neantik-proxy-qa.invalid"):
        raise ValueError("unrecognized synthetic proxy target")
    if type(dom_persistence) is not bool or (dom_persistence and proxy_target_host != "neantik-proxy-qa.invalid"):
        raise ValueError("unrecognized DOM persistence fixture")
    root = Path(receipt["root"])
    consumed = root / ("qa-" + receipt["sha256"][:12] + "-single-start-consumed")
    seed_preserved = digest(root / "profiles.previous.json") == receipt["profileSeedSHA256"]
    if (root.is_symlink() or root.resolve() != root
            or not root.is_dir() or root.stat().st_uid != os.getuid()
            or stat.S_IMODE(root.stat().st_mode) != 0o700
            or not regular_owner_only(root / "profiles.previous.json", 0o600)
            or not (seed_preserved or regular_owner_only(consumed, 0o600))
            or digest(Path(receipt["archive"])) != receipt["sha256"]):
        raise ValueError("frozen Dev QA receipt or owner-only root changed")

    source = Path(__file__).with_name("shared-broker-qa-fixture.py")
    if receipt.get("sharedFixtureSHA256") and digest(source) != receipt["sharedFixtureSHA256"]:
        raise ValueError("frozen shared QA fixture changed")
    spec = importlib.util.spec_from_file_location("neantik_bounded_fixture", source)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.ROOT = root
    module.MODE = root / "fixture-mode.json"
    module.LEDGER = root / "fixture-ledger.jsonl"
    module.QA_DOM_PERSISTENCE = dom_persistence
    if proxy_target_host == "neantik-proxy-qa.invalid":
        module.EXPECTED_HOST = f"{proxy_target_host}:{module.ORIGIN_PORT}"

        class DirectOrigin(module.Handler):
            def do_GET(self) -> None:
                if self.path == "/direct-b" and self.headers.get("Host") == f"127.0.0.1:{module.ORIGIN_PORT}":
                    if self.reply("NEANTIK_QA_DIRECT_B_OK"):
                        module.record("direct-b-response-complete", path=self.path)
                elif self.path in ("/proxy-a", "/qa-dom-written", "/qa-dom-restored"):
                    module.record("direct-proxy-a-bypass", path=self.path)
                    self.reply("NEANTIK_QA_DIRECT_BYPASS_DETECTED")
                else:
                    self.send_error(404)

        module.Origin = DirectOrigin

    def checked_root(*, initial: bool = False) -> None:
        if (root.is_symlink() or root.resolve() != root or not root.is_dir()
                or root.stat().st_uid != os.getuid()
                or stat.S_IMODE(root.stat().st_mode) != 0o700
                or not regular_owner_only(root / "profiles.json", 0o600)
                or not regular_owner_only(root / "profiles.previous.json", 0o600)
                or not (digest(root / "profiles.previous.json") == receipt["profileSeedSHA256"]
                        or regular_owner_only(consumed, 0o600))):
            raise ValueError("owner-only QA pair or frozen seed changed")
        verify_mixed_pair(root / "profiles.json", prefix,
                          module.PROXY_PORT, module.ORIGIN_PORT,
                          proxy_target_host=proxy_target_host,
                          require_shared_identity=initial and not consumed.exists(),
                          dom_persistence=dom_persistence)

    module.checked_root = checked_root
    checked_root(initial=True)
    return module, receipt


def serve(module, receipt: dict) -> None:
    module.checked_root(initial=True)
    if (module.MODE.exists() or module.LEDGER.exists()
            or not module.available_port(module.PROXY_PORT)
            or not module.available_port(module.ORIGIN_PORT)):
        raise ValueError("fixture files or loopback ports are already in use")
    for path, contents in ((module.MODE, b'{"available":true}\n'), (module.LEDGER, b"")):
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(contents)
            stream.flush()
            os.fsync(stream.fileno())
    servers = []
    threads = []
    try:
        for port, handler in ((module.ORIGIN_PORT, module.Origin), (module.PROXY_PORT, module.Proxy)):
            server = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
            server.daemon_threads = True
            servers.append(server)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            threads.append(thread)
        print(json.dumps({"status": "ready", "bind": "127.0.0.1 only",
                          "proxyPort": module.PROXY_PORT, "originPort": module.ORIGIN_PORT,
                          "candidateSHA256": receipt["sha256"]}), flush=True)
        signal.pause()
    finally:
        for server in reversed(servers):
            server.shutdown()
            server.server_close()
        for thread in threads:
            thread.join(timeout=3)


def verify_dom(events: list[dict], expected_host: str) -> dict:
    kinds = [item.get("kind") for item in events]
    forbidden = {"direct-proxy-a-bypass", "proxy-authority-mismatch",
                 "proxy-tunneled-request-mismatch", "proxy-response-write-failed",
                 "proxy-unexpected-credentials"}
    if any(kind in forbidden for kind in kinds):
        raise ValueError("DOM fixture recorded a bypass or protocol failure")
    written = [index for index, kind in enumerate(kinds) if kind == "qa-dom-written"]
    restored = [index for index, kind in enumerate(kinds) if kind == "qa-dom-restored"]
    pages = [index for index, kind in enumerate(kinds) if kind == "proxy-response-complete"]
    if not (len(written) == len(restored) == 1 and len(pages) >= 2
            and pages[0] < written[0] < pages[1] < restored[0]):
        raise ValueError("DOM write/restore sequence incomplete or out of order")
    for item in events:
        if item.get("kind") in ("qa-dom-written", "qa-dom-restored", "proxy-response-complete"):
            if item.get("authority") != expected_host:
                raise ValueError("DOM request authority changed")
    return {"result": "DOM script and persistent localStorage marker observed via exact proxy",
            "written": 1, "restored": 1, "proxyPages": len(pages), "directFallbacks": 0}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipt", type=Path)
    parser.add_argument("--name-prefix", required=True)
    actions = parser.add_mutually_exclusive_group(required=True)
    for name in ("serve", "proxy-unavailable", "proxy-available", "verify", "verify-dom", "snapshot"):
        actions.add_argument("--" + name, action="store_true")
    args = parser.parse_args()
    module, receipt = load_fixture(args.receipt, args.name_prefix)
    if args.serve:
        serve(module, receipt)
    elif args.proxy_unavailable:
        module.write_mode(False)
        print("PASS own loopback proxy marked unavailable")
    elif args.proxy_available:
        module.write_mode(True)
        print("PASS own loopback proxy marked available")
    elif args.verify:
        print(json.dumps(module.summarize(module.read_events()), sort_keys=True))
    elif args.verify_dom:
        if not receipt.get("domPersistence"):
            raise ValueError("DOM verification is not enabled for this QA candidate")
        print(json.dumps(verify_dom(module.read_events(), module.EXPECTED_HOST), sort_keys=True))
    else:
        events = module.read_events()
        print(json.dumps({"events": [item["kind"] for item in events]}, sort_keys=True))


if __name__ == "__main__":
    main()

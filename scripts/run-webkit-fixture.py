#!/usr/bin/env python3
"""Serve only the NeAntik synthetic WebKit fixture on IPv4 loopback."""
import argparse
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--port", type=int, default=0)
args = parser.parse_args()
if not 0 <= args.port <= 65535:
    parser.error("port must be 0..65535")
fixture = Path(__file__).resolve().parents[1] / "Tests/Fixtures/webkit/index.html"

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # No addresses, credentials or browsing logs.

    def do_GET(self):
        if self.path not in ("/fixture", "/two", "/favicon.ico"):
            self.send_error(404)
            return
        body = fixture.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

with HTTPServer(("127.0.0.1", args.port), Handler) as server:
    print(f"http://127.0.0.1:{server.server_port}/fixture", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass

"""Fresh TURN/TLS chain with a measured loopback AIA issuer endpoint."""

from contextlib import contextmanager
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
from threading import Lock, Thread

from tls_fixture import certificates
from turn_tcp_fixture import TurnTCPFixture

ISSUER_PATH = "/issuer.der"


def _openssl(*args: str) -> None:
    if subprocess.run(["/usr/bin/openssl", *args], capture_output=True, timeout=10).returncode:
        raise ValueError("could not generate private TURN/TLS certificate chain")


class IssuerCanary:
    def __init__(self):
        self.issuer = b""
        self.requests = 0
        self.lock = Lock()

    def count(self) -> int:
        with self.lock:
            return self.requests


@contextmanager
def material(root: Path, case: str):
    """Keep the canary alive until its TURN fixture has stopped."""
    if case not in {"complete", "wrong-host", "missing-intermediate"}:
        raise ValueError("invalid private TURN/TLS certificate case")
    counter = IssuerCanary()

    class Handler(BaseHTTPRequestHandler):
        def parse_request(self):
            if not super().parse_request():
                return False
            with counter.lock:
                counter.requests += 1
            return True

        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path != ISSUER_PATH:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/pkix-cert")
            self.send_header("Content-Length", str(len(counter.issuer)))
            self.end_headers()
            self.wfile.write(counter.issuer)

    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        port = server.server_port
        certs = certificates(root / "certs", "127.0.0.1", TurnTCPFixture.host)
        intermediate_ext = certs / "intermediate.ext"
        intermediate_ext.write_text("basicConstraints=critical,CA:TRUE,pathlen:0\n"
                                    "keyUsage=critical,keyCertSign,cRLSign\n"
                                    "subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n")
        leaf_ext = certs / "leaf.ext"
        hostname = "wrong-neantik.invalid" if case == "wrong-host" else TurnTCPFixture.host
        leaf_ext.write_text("basicConstraints=critical,CA:FALSE\n"
                            "keyUsage=critical,digitalSignature,keyEncipherment\n"
                            "extendedKeyUsage=serverAuth\n"
                            f"subjectAltName=DNS:{hostname}\n"
                            f"authorityInfoAccess=caIssuers;URI:http://127.0.0.1:{port}{ISSUER_PATH}\n")
        intermediate = certs / "intermediate.pem"
        intermediate_key = certs / "intermediate.key"
        csr = certs / "intermediate.csr"
        _openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=NeAntik TURN QA issuer",
                 "-keyout", str(intermediate_key), "-out", str(csr))
        intermediate_key.chmod(0o600)
        _openssl("x509", "-req", "-in", str(csr), "-CA", str(certs / "ca.pem"), "-CAkey", str(certs / "ca.key"),
                 "-set_serial", "2", "-days", "1", "-sha256", "-extfile", str(intermediate_ext),
                 "-out", str(intermediate))
        leaf = certs / "leaf.pem"
        _openssl("x509", "-req", "-in", str(certs / "leaf.csr"), "-CA", str(intermediate),
                 "-CAkey", str(intermediate_key), "-set_serial", "3", "-days", "1", "-sha256",
                 "-extfile", str(leaf_ext), "-out", str(leaf))
        der = certs / "issuer.der"
        _openssl("x509", "-in", str(intermediate), "-outform", "DER", "-out", str(der))
        counter.issuer = der.read_bytes()
        chain, key = root / "chain.pem", root / "leaf.key"
        chain.touch(mode=0o600)
        chain.write_bytes(leaf.read_bytes() + (b"" if case == "missing-intermediate" else intermediate.read_bytes()))
        key.touch(mode=0o600)
        key.write_bytes((certs / "leaf.key").read_bytes())

        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            connection = HTTPConnection("127.0.0.1", port, timeout=3)
            try:
                connection.request("GET", ISSUER_PATH)
                response = connection.getresponse()
                if response.status != 200 or response.read() != counter.issuer or counter.count() != 1:
                    raise ValueError("private issuer canary did not serve its intermediate")
            finally:
                connection.close()
            yield (chain, key), (certs / "ca.der").read_bytes(), counter
        finally:
            server.shutdown()
            thread.join(timeout=3)

"""Preflight capabilities required by local manager regression suites."""
import socket
import subprocess


def full_run_capability_gaps():
    """Return missing process-inspection and loopback TCP/UDP capabilities."""
    gaps = []
    try:
        result = subprocess.run(
            ["/bin/ps", "-A", "-o", "pid="], stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, timeout=2, check=False,
        )
        if result.returncode != 0 or not result.stdout.strip():
            gaps.append("process-inspection")
    except (OSError, subprocess.SubprocessError):
        gaps.append("process-inspection")

    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.settimeout(1)
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            with socket.create_connection(listener.getsockname(), timeout=1):
                connection, _ = listener.accept()
                connection.close()
    except OSError:
        gaps.append("loopback-tcp")

    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as receiver:
            receiver.settimeout(1)
            receiver.bind(("127.0.0.1", 0))
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender:
                sender.sendto(b"neantik-test-preflight", receiver.getsockname())
                data, _ = receiver.recvfrom(64)
                if data != b"neantik-test-preflight":
                    gaps.append("loopback-udp")
    except OSError:
        gaps.append("loopback-udp")
    return gaps

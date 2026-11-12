"""Own the local TURN/TCP test process and its private handoff."""

import json
import os
from pathlib import Path
import re
import select
import stat
import subprocess

TURN_BROWSER_STATUSES = (
    'fixture-invalid', 'api-unavailable', 'relay-candidate-missing',
    'nonce-mismatch', 'relay-pair-unverified', 'relay-nonce-delivered',
    'timeout', 'browser-error',
)
TURN_BROWSER_PROBE = Path(__file__).resolve().parent / 'turn-fixture/browser-probe.js'


def turn_probe_fragment(target, token):
    """Render only for the owned synthetic origin and a single armed run."""
    if not isinstance(target, TurnTCPFixture) or not isinstance(token, str) or not re.fullmatch('[0-9a-f]{32}', token):
        raise ValueError('Live TURN fixture and exact probe token required')
    source = TURN_BROWSER_PROBE.read_text(encoding='utf-8')
    config = json.dumps(target.browser_config())
    return f"""<pre id="turn-probe">pending</pre><script>
(async () => {{
  const result = await {source}({config});
  document.getElementById('turn-probe').textContent = result.status;
  const response = await fetch('/qa-turn/{token}/' + result.status, {{cache: 'no-store', credentials: 'same-origin'}});
  if (!response.ok) throw Error('OwnedTURNReceiptRefused');
}})().catch(() => {{ document.getElementById('turn-probe').textContent = 'receipt-error'; }});
</script>"""


class TurnTCPFixture:
    host = 'turn-neantik.invalid'

    def __init__(self, executable: Path, root: Path):
        if executable != executable.resolve(strict=True) or not executable.is_file():
            raise ValueError('Physical absolute TURN fixture executable required')
        entry = root.lstat()
        if (root != root.resolve(strict=True) or not stat.S_ISDIR(entry.st_mode)
                or entry.st_uid != os.geteuid() or stat.S_IMODE(entry.st_mode) != 0o700):
            raise ValueError('Owner-only TURN fixture directory required')
        handoff = root / 'turn-ready.json'
        if os.path.lexists(handoff):
            raise ValueError('TURN handoff already exists')
        self.process = subprocess.Popen(
            [str(executable), '-ready-file', str(handoff)], cwd=root,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        self.executable = executable
        try:
            assert self.process.stdout is not None
            ready, _, _ = select.select([self.process.stdout], [], [], 5)
            if not ready or os.read(self.process.stdout.fileno(), 128) != b'{"status":"ready"}\n':
                raise ValueError('TURN fixture did not report readiness')
            with os.fdopen(os.open(handoff, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), 'rb') as stream:
                info = os.fstat(stream.fileno())
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                        or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > 1024):
                    raise ValueError('Invalid TURN fixture handoff')
                try:
                    data = json.load(stream)
                except (ValueError, UnicodeError):
                    raise ValueError('Invalid TURN fixture handoff') from None
            if (not isinstance(data, dict) or set(data) != {'host', 'port', 'username', 'credential', 'realm'}
                    or data['host'] != '127.0.0.1' or type(data['port']) is not int
                    or not 1024 <= data['port'] <= 65535 or data['username'] != 'neantik-fixture'
                    or data['realm'] != 'neantik-turn-fixture.invalid'
                    or not isinstance(data['credential'], str) or not re.fullmatch('[0-9a-f]{64}', data['credential'])
                    or self.process.poll() is not None):
                raise ValueError('Invalid TURN fixture handoff')
            self.port = data['port']
            self._username = data['username']
            self._credential = data['credential']
        except BaseException:
            if self.process.poll() is None:
                self.process.kill()
            self.process.communicate()
            raise

    @property
    def authority(self):
        return f'{self.host}:{self.port}'

    def loopback_destination(self, authority):
        if authority != self.authority or self.process.poll() is not None:
            raise ValueError('TURN fixture authority is not live')
        return '127.0.0.1', self.port

    def browser_config(self):
        self.loopback_destination(self.authority)
        return {'url': f'turn:{self.authority}?transport=tcp',
                'username': self._username, 'credential': self._credential}

    def stop(self):
        if self.process.poll() is None:
            self.process.terminate()
        try:
            output, _ = self.process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.communicate()
            raise ValueError('TURN fixture shutdown timed out') from None
        try:
            result = json.loads(output)
        except (ValueError, UnicodeError):
            raise ValueError('TURN fixture did not provide final counts') from None
        if (self.process.returncode != 0 or not isinstance(result, dict) or set(result) != {'allocations'}
                or type(result['allocations']) is not int or result['allocations'] < 0):
            raise ValueError('Invalid TURN fixture shutdown receipt')
        return result

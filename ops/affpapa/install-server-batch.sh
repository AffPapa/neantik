#!/usr/bin/env bash
# Root-only one-time installer for the restricted NeAntik AffPapa channel.
set -Eeuo pipefail

[[ "$(id -u)" -eq 0 ]] || {
    echo "Run as root." >&2
    exit 1
}
[[ $# -eq 1 ]] || {
    echo "Usage: $0 <staged-source-dir>" >&2
    exit 2
}

STAGED=$(readlink -f "$1")
LIVE_ROOT="/var/www/hrband"
BLADE_LIVE="$LIVE_ROOT/resources/views/affpapa/neantik.blade.php"
CONTENT_LIVE="$LIVE_ROOT/public/neantik/content.json"
RELEASE_LIVE="$LIVE_ROOT/public/neantik/release.json"
SUDOERS_LIVE="/etc/sudoers.d/neantik-deploy"
AUTHORIZED_KEYS="/home/neantik-deploy/.ssh/authorized_keys"
OPS_MANIFEST="/etc/neantik-release-ops.json"
BACKUP_ROOT="$LIVE_ROOT/storage/app/codex-backups"
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP="$BACKUP_ROOT/neantik-final-access-$TIMESTAMP"
CONTENT_EXISTED=0
OPS_MANIFEST_EXISTED=0

required=(
    neantik-release-deploy
    neantik-release-rollback
    neantik-release-status
    neantik-release-abort
    neantik-upload
    neantik-ssh-dispatcher
    neantik-validate-release
    neantik.blade.php
    content.json
    neantik-deploy.sudoers
)
for filename in "${required[@]}"; do
    [[ -f "$STAGED/$filename" ]] || {
        echo "Missing staged file: $filename" >&2
        exit 1
    }
done

for script in \
    neantik-release-deploy \
    neantik-release-rollback \
    neantik-release-status \
    neantik-release-abort \
    neantik-upload \
    neantik-ssh-dispatcher; do
    bash -n "$STAGED/$script"
done
python3 -c \
    "compile(open('$STAGED/neantik-validate-release', encoding='utf-8').read(), 'neantik-validate-release', 'exec')"
php -l "$STAGED/neantik.blade.php" >/dev/null
python3 -m json.tool "$STAGED/content.json" >/dev/null
visudo -cf "$STAGED/neantik-deploy.sudoers" >/dev/null

mkdir -p "$BACKUP/sbin"
cp -a /usr/local/sbin/neantik-* "$BACKUP/sbin/"
cp -a "$BLADE_LIVE" "$BACKUP/neantik.blade.php"
cp -a "$RELEASE_LIVE" "$BACKUP/release.json"
cp -a "$SUDOERS_LIVE" "$BACKUP/neantik-deploy.sudoers"
cp -a "$AUTHORIZED_KEYS" "$BACKUP/authorized_keys"
if [[ -f "$CONTENT_LIVE" ]]; then
    CONTENT_EXISTED=1
    cp -a "$CONTENT_LIVE" "$BACKUP/content.json"
fi
if [[ -f "$OPS_MANIFEST" ]]; then
    OPS_MANIFEST_EXISTED=1
    cp -a "$OPS_MANIFEST" "$BACKUP/neantik-release-ops.json"
fi
BEFORE_RELEASE_SHA=$(sha256sum "$RELEASE_LIVE" | cut -d' ' -f1)

restore_install() {
    local status=$?
    echo "Install failed; restoring previous server files." >&2
    cp -a "$BACKUP/sbin/"neantik-* /usr/local/sbin/ || true
    cp -a "$BACKUP/neantik.blade.php" "$BLADE_LIVE" || true
    cp -a "$BACKUP/neantik-deploy.sudoers" "$SUDOERS_LIVE" || true
    if [[ "$CONTENT_EXISTED" -eq 1 ]]; then
        cp -a "$BACKUP/content.json" "$CONTENT_LIVE" || true
    else
        rm -f "$CONTENT_LIVE"
    fi
    if [[ "$OPS_MANIFEST_EXISTED" -eq 1 ]]; then
        cp -a "$BACKUP/neantik-release-ops.json" "$OPS_MANIFEST" || true
    else
        rm -f "$OPS_MANIFEST"
    fi
    cd "$LIVE_ROOT"
    sudo -u deploy php artisan view:clear >/dev/null 2>&1 || true
    sudo -u deploy php artisan view:cache >/dev/null 2>&1 || true
    exit "$status"
}
trap restore_install ERR

install -m 755 -o root -g root \
    "$STAGED/neantik-release-deploy" \
    "$STAGED/neantik-release-rollback" \
    "$STAGED/neantik-release-status" \
    "$STAGED/neantik-release-abort" \
    "$STAGED/neantik-upload" \
    "$STAGED/neantik-ssh-dispatcher" \
    "$STAGED/neantik-validate-release" \
    /usr/local/sbin/
install -m 440 -o root -g root \
    "$STAGED/neantik-deploy.sudoers" \
    "$SUDOERS_LIVE"
visudo -cf "$SUDOERS_LIVE" >/dev/null

ops_manifest_tmp=$(mktemp /etc/neantik-release-ops.json.install-XXXXXX)
python3 - "$ops_manifest_tmp" <<'PY'
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

paths = sorted(Path("/usr/local/sbin").glob("neantik-*"))
manifest = {
    "schemaVersion": 1,
    "installedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "files": {
        path.name: hashlib.sha256(path.read_bytes()).hexdigest()
        for path in paths
        if path.is_file() and not path.is_symlink()
    },
}
Path(sys.argv[1]).write_text(
    json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
chown root:root "$ops_manifest_tmp"
chmod 644 "$ops_manifest_tmp"
mv -f "$ops_manifest_tmp" "$OPS_MANIFEST"

content_tmp=$(mktemp "$CONTENT_LIVE.install-XXXXXX")
install -m 644 -o deploy -g deploy "$STAGED/content.json" "$content_tmp"
mv -f "$content_tmp" "$CONTENT_LIVE"

blade_tmp=$(mktemp "$BLADE_LIVE.install-XXXXXX")
install -m 644 -o root -g root "$STAGED/neantik.blade.php" "$blade_tmp"
mv -f "$blade_tmp" "$BLADE_LIVE"

cd "$LIVE_ROOT"
sudo -u deploy php artisan view:clear >/dev/null
sudo -u deploy php artisan view:cache >/dev/null

AFTER_RELEASE_SHA=$(sha256sum "$RELEASE_LIVE" | cut -d' ' -f1)
[[ "$AFTER_RELEASE_SHA" == "$BEFORE_RELEASE_SHA" ]] || {
    echo "Live release.json changed during access installation." >&2
    false
}

# The origin vhost has an incomplete local CA chain. This exception is limited
# to affpapa.org pinned to loopback; external client verification stays strict.
curl -fsS --insecure --resolve "affpapa.org:443:127.0.0.1" \
    "https://affpapa.org/neantik" >/dev/null
served_content=$(mktemp /tmp/neantik-content-install-XXXXXX)
curl -fsS --insecure --resolve "affpapa.org:443:127.0.0.1" \
    "https://affpapa.org/neantik/content.json" >"$served_content"
cmp -s "$served_content" "$CONTENT_LIVE"

trap - ERR
echo "PASS: final NeAntik access batch installed."
echo "Backup: $BACKUP"
sha256sum /usr/local/sbin/neantik-*

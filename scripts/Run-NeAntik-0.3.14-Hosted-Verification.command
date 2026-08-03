#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DOWNLOAD_URL="${NEANTIK_DOWNLOAD_URL:-https://affpapa.org/neantik/downloads/NeAntik-0.3.14-arm64-notarized.zip}"

pause_on_error() {
  local exit_code=$?
  trap - ERR
  echo
  echo "Проверка скачанного выпуска остановлена (код $exit_code)."
  echo "Локальный архив и опубликованный файл не изменялись."
  if [[ -t 0 ]]; then
    read -r "?Нажмите Return, чтобы закрыть окно… " || true
  fi
  exit "$exit_code"
}
trap pause_on_error ERR

echo "NeAntik 0.3.14 — проверка опубликованного ZIP"
echo "Файл будет заново скачан с affpapa.org и проверен без изменения релиза."
echo

python3 "$PROJECT_DIR/scripts/verify-direct-hosted-download.py" \
  --archive "$PROJECT_DIR/dist/NeAntik-0.3.14-arm64-notarized.zip" \
  --download-url "$DOWNLOAD_URL" \
  --candidate-manifest "$PROJECT_DIR/dist/direct-candidate-manifest.json" \
  --release-channel "${NEANTIK_RELEASE_CHANNEL:-public-alpha}" \
  --fingerprint-evidence "$PROJECT_DIR/dist/fingerprint-audit.json" \
  --fingerprint-attestation "$PROJECT_DIR/dist/fingerprint-audit-summary.json"

echo
echo "Готово: скачанный ZIP, SHA-256, подпись, локальная policy-проверка и fingerprint binding проверены."
if [[ -t 0 ]]; then
  read -r "?Нажмите Return, чтобы закрыть окно… "
fi

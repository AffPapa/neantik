#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DOWNLOAD_URL="https://github.com/AffPapa/neantik/releases/download/v0.3.12/NeAntik-0.3.12-arm64-notarized.dmg"

pause_on_error() {
  local exit_code=$?
  trap - ERR
  echo
  echo "Проверка скачанного DMG остановлена (код $exit_code)."
  echo "Локальный DMG, GitHub Release и сайт не изменялись."
  if [[ -t 0 ]]; then
    read -r "?Нажмите Return, чтобы закрыть окно… " || true
  fi
  exit "$exit_code"
}
trap pause_on_error ERR

echo "NeAntik 0.3.12 — проверка опубликованного DMG"
echo "Файл будет заново скачан с GitHub и проверен без изменения релиза."
echo

"$PROJECT_DIR/scripts/verify-direct-hosted-dmg.sh" "$DOWNLOAD_URL"

echo
echo "Готово: скачанный DMG, SHA-256, подпись, содержимое, stapling и Gatekeeper проверены."
if [[ -t 0 ]]; then
  read -r "?Нажмите Return, чтобы закрыть окно… "
fi

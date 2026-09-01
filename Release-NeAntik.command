#!/bin/zsh

set -euo pipefail
umask 077
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
export DEVELOPER_DIR="$(
  "$PROJECT_DIR/scripts/resolve-compatible-developer-dir.sh"
)"
VERSION="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "$PROJECT_DIR/Resources/Info.plist"
)"
BUILD="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleVersion' \
    "$PROJECT_DIR/Resources/Info.plist"
)"
RELEASE_SCRIPT="$PROJECT_DIR/scripts/Run-NeAntik-Release.command"
ZIP_PATH="$PROJECT_DIR/dist/NeAntik-$VERSION-arm64-notarized.zip"
DMG_PATH="$PROJECT_DIR/dist/NeAntik-$VERSION-arm64-notarized.dmg"
PREVIOUS_ARTIFACTS_ROOT="$PROJECT_DIR/artifacts/neantik/private-release-attempts"

if [[ ! -x "$RELEASE_SCRIPT" ]]; then
  echo "Не найден единый release-сценарий NeAntik:" >&2
  echo "$RELEASE_SCRIPT" >&2
  echo "Публикация не запускалась." >&2
  exit 66
fi

echo "NeAntik $VERSION — единый Direct release"
echo "Канал выпуска: Direct Distribution."
echo

previous_artifacts=(
  "$ZIP_PATH"
  "$ZIP_PATH.sha256"
  "$DMG_PATH"
  "$DMG_PATH.sha256"
  "$PROJECT_DIR/dist/notary/$(basename "$DMG_PATH").notary-submit.log"
  "$PROJECT_DIR/dist/notary/$(basename "$DMG_PATH").notary-receipt.json"
)
has_previous_artifacts=0
for artifact in "${previous_artifacts[@]}"; do
  if [[ -e "$artifact" || -L "$artifact" ]]; then
    has_previous_artifacts=1
    break
  fi
done
if (( has_previous_artifacts == 1 )); then
  previous_dir="$PREVIOUS_ARTIFACTS_ROOT/$(date -u '+%Y%m%dT%H%M%SZ')-$$-previous-$VERSION-$BUILD"
  mkdir -p "$previous_dir"
  chmod 0700 "$previous_dir"
  echo "Сохраняю предыдущие локальные файлы этого выпуска:"
  echo "$previous_dir"
  for artifact in "${previous_artifacts[@]}"; do
    if [[ -e "$artifact" || -L "$artifact" ]]; then
      mv "$artifact" "$previous_dir/"
    fi
  done
  echo
fi

echo "[1/2] Готовлю подписанный и notarized ZIP для точного текущего исходного коммита."
"$RELEASE_SCRIPT"

echo
echo "[2/2] Готовлю подписанный и notarized DMG из точного проверенного ZIP."
"$PROJECT_DIR/scripts/release-direct-dmg.sh"

echo
echo "PASS: локальный Direct release готов."
echo "ZIP: $ZIP_PATH"
echo "DMG: $DMG_PATH"
echo "GitHub и сайт этим сценарием не изменялись."

#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "$PROJECT_DIR/Resources/Info.plist"
)"
RELEASE_SCRIPT="$PROJECT_DIR/scripts/Run-NeAntik-$VERSION-Release.command"
ZIP_PATH="$PROJECT_DIR/dist/NeAntik-$VERSION-arm64-notarized.zip"
DMG_PATH="$PROJECT_DIR/dist/NeAntik-$VERSION-arm64-notarized.dmg"

if [[ ! -x "$RELEASE_SCRIPT" ]]; then
  echo "Не найден исполняемый release-сценарий для NeAntik $VERSION:" >&2
  echo "$RELEASE_SCRIPT" >&2
  echo "Публикация не запускалась." >&2
  exit 66
fi

echo "NeAntik $VERSION — единый Direct release"
echo "Канал выпуска: Direct Distribution."
echo

if [[ -f "$ZIP_PATH" ]]; then
  echo "[1/2] ZIP уже существует — проверяю вместо повторной notarization."
  python3 "$PROJECT_DIR/scripts/verify-direct-notarized-archive.py" \
    --project-root "$PROJECT_DIR" \
    --archive "$ZIP_PATH"
else
  echo "[1/2] Готовлю подписанный и notarized ZIP."
  "$RELEASE_SCRIPT"
fi

if [[ -f "$DMG_PATH" ]]; then
  echo
  echo "[2/2] DMG уже существует — проверяю вместо повторной notarization."
  "$PROJECT_DIR/scripts/verify-direct-notarized-dmg.sh" "$DMG_PATH"
else
  echo
  echo "[2/2] Готовлю подписанный и notarized DMG."
  "$PROJECT_DIR/scripts/release-direct-dmg.sh"
fi

echo
echo "PASS: локальный Direct release готов."
echo "ZIP: $ZIP_PATH"
echo "DMG: $DMG_PATH"
echo "GitHub и сайт этим сценарием не изменялись."

#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPMENT_ROOT="$PROJECT_DIR/.build/neantik-local"
SOURCE_APP="$PROJECT_DIR/dist/NeAntik.app"
DEVELOPMENT_APP="$DEVELOPMENT_ROOT/NeAntik-Dev.app"
SWIFT_SCRATCH="$DEVELOPMENT_ROOT/swift"
SWIFT_CACHE="$DEVELOPMENT_ROOT/cache"
SWIFT_CONFIG="$DEVELOPMENT_ROOT/config"
SWIFT_SECURITY="$DEVELOPMENT_ROOT/security"
CLANG_CACHE="$DEVELOPMENT_ROOT/clang-module-cache"
SHOULD_OPEN=1
REFRESH_RUNTIME=0

# A `.command` file is launched by Terminal with the user's home directory as
# the working directory. Keep every SwiftPM operation anchored to the project
# so double-click and command-line launches behave identically.
cd "$PROJECT_DIR"

usage() {
  echo "Использование: ./Develop-NeAntik.command [--no-open] [--refresh-runtime]"
  echo
  echo "  --no-open          собрать и проверить Dev.app, но не открывать"
  echo "  --refresh-runtime  заново клонировать встроенный runtime из dist/NeAntik.app"
}

while (( $# > 0 )); do
  case "$1" in
    --no-open)
      SHOULD_OPEN=0
      ;;
    --refresh-runtime)
      REFRESH_RUNTIME=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Неизвестный параметр: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

if [[ ! -d "$SOURCE_APP/Contents/Resources/NeAntik Browser.app" ]]; then
  echo "Не найден встроенный Chromium в $SOURCE_APP" >&2
  echo "Сначала нужен один готовый локальный Direct-кандидат." >&2
  exit 66
fi

mkdir -p \
  "$DEVELOPMENT_ROOT" \
  "$SWIFT_CACHE" \
  "$SWIFT_CONFIG" \
  "$SWIFT_SECURITY" \
  "$CLANG_CACHE"

echo "NeAntik — быстрый локальный запуск интерфейса"
echo "Публичный релиз, dist, notarization и сайт не изменяются."
echo

SECONDS=0
CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" \
SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_CACHE" \
TMPDIR="$DEVELOPMENT_ROOT" \
swift build \
  --disable-sandbox \
  --disable-dependency-cache \
  --manifest-cache local \
  --cache-path "$SWIFT_CACHE" \
  --config-path "$SWIFT_CONFIG" \
  --security-path "$SWIFT_SECURITY" \
  --scratch-path "$SWIFT_SCRATCH" \
  --configuration debug \
  --product NeAntik
BUILD_SECONDS=$SECONDS

BIN_PATH="$(
  swift build \
    --disable-sandbox \
    --disable-dependency-cache \
    --manifest-cache local \
    --cache-path "$SWIFT_CACHE" \
    --config-path "$SWIFT_CONFIG" \
    --security-path "$SWIFT_SECURITY" \
    --scratch-path "$SWIFT_SCRATCH" \
    --configuration debug \
    --show-bin-path
)"
MANAGER_BINARY="$BIN_PATH/NeAntik"
if [[ ! -x "$MANAGER_BINARY" ]]; then
  echo "Swift-бинарник не найден: $MANAGER_BINARY" >&2
  exit 70
fi

if (( REFRESH_RUNTIME == 1 )) || \
   [[ ! -d "$DEVELOPMENT_APP/Contents/Resources/NeAntik Browser.app" ]]; then
  echo "Один раз клонирую встроенный runtime для Dev.app…"
  if [[ -e "$DEVELOPMENT_APP" ]]; then
    /bin/rm -rf "$DEVELOPMENT_APP"
  fi
  /bin/cp -cR "$SOURCE_APP" "$DEVELOPMENT_APP"
fi

INFO_PLIST="$DEVELOPMENT_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleIdentifier app.neantik.desktop.dev" \
  "$INFO_PLIST"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleDisplayName NeAntik Dev" \
  "$INFO_PLIST"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleName NeAntik Dev" \
  "$INFO_PLIST"

/bin/cp "$MANAGER_BINARY" \
  "$DEVELOPMENT_APP/Contents/MacOS/NeAntik"
/usr/bin/codesign \
  --force \
  --sign - \
  "$DEVELOPMENT_APP"
/usr/bin/codesign \
  --verify \
  --deep \
  --strict \
  "$DEVELOPMENT_APP"

echo
echo "PASS: NeAntik Dev.app готов за ${BUILD_SECONDS} с."
echo "Приложение: $DEVELOPMENT_APP"
echo "Данные: ~/Library/Application Support/NeAntik Development"
echo "Связка ключей: app.neantik.dev.proxy"

if (( SHOULD_OPEN == 1 )); then
  /usr/bin/osascript \
    -e 'tell application id "app.neantik.desktop.dev" to quit' \
    >/dev/null 2>&1 || true
  echo "Открываю изолированную локальную версию."
  exec "$DEVELOPMENT_APP/Contents/MacOS/NeAntik"
else
  echo "Открытие пропущено (--no-open)."
fi

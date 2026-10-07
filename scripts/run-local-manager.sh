#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPMENT_ROOT="$PROJECT_DIR/.build/neantik-local"
SOURCE_APP="$PROJECT_DIR/dist/NeAntik.app"
DEVELOPMENT_APP="$DEVELOPMENT_ROOT/NeAntik-Dev.app"
DEVELOPMENT_RUNTIME_APP="$DEVELOPMENT_APP/Contents/Resources/NeAntik Browser.app"
SWIFT_SCRATCH="$DEVELOPMENT_ROOT/swift"
SWIFT_CACHE="$DEVELOPMENT_ROOT/cache"
SWIFT_CONFIG="$DEVELOPMENT_ROOT/config"
SWIFT_SECURITY="$DEVELOPMENT_ROOT/security"
CLANG_CACHE="$DEVELOPMENT_ROOT/clang-module-cache"
SHOULD_OPEN=1
REFRESH_RUNTIME=0
USE_FRESH_FIXTURE=0

# A `.command` file is launched by Terminal with the user's home directory as
# the working directory. Keep every SwiftPM operation anchored to the project
# so double-click and command-line launches behave identically.
cd "$PROJECT_DIR"

export DEVELOPER_DIR="$(
  "$PROJECT_DIR/scripts/resolve-compatible-developer-dir.sh"
)"

usage() {
  echo "Использование: ./Develop-NeAntik.command [--no-open] [--refresh-runtime] [--fixture]"
  echo
  echo "  --no-open          собрать и проверить Dev.app, но не открывать"
  echo "  --refresh-runtime  заново клонировать встроенный runtime из dist/NeAntik.app"
  echo "  --fixture          новый временный стенд для проверки, без чтения старых Dev-данных"
}

while (( $# > 0 )); do
  case "$1" in
    --no-open)
      SHOULD_OPEN=0
      ;;
    --fixture)
      USE_FRESH_FIXTURE=1
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
echo "Xcode: $DEVELOPER_DIR"
echo

SECONDS=0
CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" \
SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_CACHE" \
TMPDIR="$DEVELOPMENT_ROOT" \
swift build \
  --build-system native \
  --jobs 2 \
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
    --build-system native \
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
DEVELOPMENT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")"
DEVELOPMENT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PROJECT_DIR/Resources/Info.plist")"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $DEVELOPMENT_VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $DEVELOPMENT_BUILD" "$INFO_PLIST"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleIdentifier app.neantik.desktop.dev" \
  "$INFO_PLIST"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleDisplayName NeAntik Dev" \
  "$INFO_PLIST"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleName NeAntik Dev" \
  "$INFO_PLIST"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleDevelopmentRegion ru" \
  "$INFO_PLIST"
if ! /usr/libexec/PlistBuddy \
    -c "Print :CFBundleLocalizations" \
    "$INFO_PLIST" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy \
    -c "Add :CFBundleLocalizations array" \
    "$INFO_PLIST"
fi
if ! /usr/libexec/PlistBuddy \
    -c "Print :CFBundleLocalizations:0" \
    "$INFO_PLIST" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy \
    -c "Add :CFBundleLocalizations:0 string ru" \
    "$INFO_PLIST"
else
  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleLocalizations:0 ru" \
    "$INFO_PLIST"
fi
mkdir -p "$DEVELOPMENT_APP/Contents/Resources/ru.lproj"
/bin/cp \
  "$PROJECT_DIR/Resources/ru.lproj/InfoPlist.strings" \
  "$PROJECT_DIR/Resources/ru.lproj/Localizable.strings" \
  "$DEVELOPMENT_APP/Contents/Resources/ru.lproj/"

# The localized production strings intentionally call the product "NeAntik".
# Keep the isolated engineering bundle visibly distinct after those resources
# are copied so testers never confuse Dev.app with a release installation.
DEVELOPMENT_INFO_STRINGS="$DEVELOPMENT_APP/Contents/Resources/ru.lproj/InfoPlist.strings"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleDisplayName NeAntik Dev" \
  "$DEVELOPMENT_INFO_STRINGS"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleName NeAntik Dev" \
  "$DEVELOPMENT_INFO_STRINGS"

/bin/cp "$MANAGER_BINARY" \
  "$DEVELOPMENT_APP/Contents/MacOS/NeAntik"

# A cached or engineering runtime can have a valid main executable while one
# of its nested Chromium helpers or sealed resources is no longer valid. The
# manager process then fails at the real launch boundary even though a shallow
# signature inspection looks healthy. Repair only the isolated Dev.app copy
# with an ad-hoc signature; never mutate dist or invoke Developer ID,
# notarization or stapling from this fast path.
if ! /usr/bin/codesign \
    --verify \
    --deep \
    --strict \
    "$DEVELOPMENT_RUNTIME_APP" \
    >/dev/null 2>&1; then
  echo "Восстанавливаю локальную ad-hoc подпись Chromium для Dev.app…"
  /usr/bin/codesign \
    --force \
    --deep \
    --sign - \
    "$DEVELOPMENT_RUNTIME_APP"
fi

if (( USE_FRESH_FIXTURE == 1 )); then
  DEVELOPMENT_FIXTURE_ROOT="$(mktemp -d /private/tmp/neantik-dev-fixture.XXXXXXXX)"
  /usr/libexec/PlistBuddy -c 'Delete :NeAntikDevelopmentFixtureRoot' "$INFO_PLIST" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :NeAntikDevelopmentFixtureRoot string $DEVELOPMENT_FIXTURE_ROOT" "$INFO_PLIST"
else
  /usr/libexec/PlistBuddy -c 'Delete :NeAntikDevelopmentFixtureRoot' "$INFO_PLIST" >/dev/null 2>&1 || true
fi

/usr/bin/codesign \
  --verify \
  --deep \
  --strict \
  "$DEVELOPMENT_RUNTIME_APP"
/usr/bin/codesign \
  --force \
  --sign - \
  "$DEVELOPMENT_APP"
/usr/bin/codesign \
  --verify \
  --deep \
  --strict \
  "$DEVELOPMENT_RUNTIME_APP"
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
  if (( USE_FRESH_FIXTURE == 1 )); then
    export NEANTIK_DEVELOPMENT_DATA_ROOT="$DEVELOPMENT_FIXTURE_ROOT"
    echo "Открываю новый временный Dev-стенд. Существующие Dev-данные сохранены."
  fi
  echo "Открываю изолированную локальную версию."
  exec "$DEVELOPMENT_APP/Contents/MacOS/NeAntik"
else
  echo "Открытие пропущено (--no-open)."
fi

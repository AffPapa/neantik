#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$PROJECT_DIR/dist/NeAntik-Integrated.app"
APP_PATH="$PROJECT_DIR/dist/NeAntik.app"
CANDIDATE_MANIFEST="$PROJECT_DIR/dist/direct-candidate-manifest.json"
REPORT_PATH="$PROJECT_DIR/dist/fingerprint-audit.json"
ATTEMPT_STATE_ROOT="$PROJECT_DIR/artifacts/neantik/private-release-attempts/$(date -u '+%Y%m%dT%H%M%SZ')-$$"
DEFAULT_SOURCE_PROVENANCE="/private/tmp/nevision-chromium-150/build/source-provenance.json"
EXPECTED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")"
EXPECTED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PROJECT_DIR/Resources/Info.plist")"

export NEANTIK_SIGNING_IDENTITY="${NEANTIK_SIGNING_IDENTITY:-62831D7DD86D5EDE0C44130F980325C4BFBC1B43}"
export NEANTIK_NOTARY_PROFILE="${NEANTIK_NOTARY_PROFILE:-neantik-notary}"
export NEANTIK_RELEASE_CHANNEL="${NEANTIK_RELEASE_CHANNEL:-public-alpha}"
if [[ -z "${NEANTIK_SOURCE_PROVENANCE:-}" && -f "$DEFAULT_SOURCE_PROVENANCE" ]]; then
  export NEANTIK_SOURCE_PROVENANCE="$DEFAULT_SOURCE_PROVENANCE"
fi

pause_on_error() {
  local exit_code=$?
  trap - ERR
  echo
  echo "Выпуск остановлен на безопасной проверке (код $exit_code)."
  echo "Ничего не публиковалось. Скопируйте только текст ошибки, без секретов."
  if [[ -t 0 ]]; then
    read -r "?Нажмите Return, чтобы закрыть окно… " || true
  fi
  exit "$exit_code"
}
trap pause_on_error ERR

run_logged_stage() {
  local label="$1"
  local log_path="$2"
  shift 2
  echo "$label"
  if "$@" >"$log_path" 2>&1; then
    echo "PASS"
    return 0
  else
    local exit_code=$?
    echo "FAIL: $label" >&2
    echo "Диагностика: $log_path" >&2
    tail -n 40 "$log_path" >&2 || true
    return "$exit_code"
  fi
}

prepare_candidate() {
  run_logged_stage \
    "[1/4] Собираю и проверяю NeAntik $EXPECTED_VERSION ($EXPECTED_BUILD)…" \
    "$ATTEMPT_STATE_ROOT/prepare-candidate.log" \
    "$PROJECT_DIR/scripts/prepare-direct-manager-update.sh" \
    "$SOURCE_APP"
}

echo "NeAntik 0.3.14 — защищённый локальный этап выпуска"
echo "Секреты не запрашиваются: подпись и notarization используют Keychain."
echo "Этапы: сборка → проверка профилей → Apple notarization → готовый ZIP."
echo

mkdir -p "$ATTEMPT_STATE_ROOT"
chmod 0700 "$ATTEMPT_STATE_ROOT"
echo "Private attempt state: $ATTEMPT_STATE_ROOT"

if [[ -d "$APP_PATH" && -f "$CANDIDATE_MANIFEST" &&
      ! -L "$CANDIDATE_MANIFEST" ]]; then
  echo "Проверяю уже подготовленный кандидат."
  NEEDS_REBUILD=0
  if ! python3 "$PROJECT_DIR/scripts/direct-candidate-manifest.py" verify \
      --app "$APP_PATH" \
      --manifest "$CANDIDATE_MANIFEST" \
      --release-channel "$NEANTIK_RELEASE_CHANNEL" \
      >"$ATTEMPT_STATE_ROOT/candidate-reuse-check.log" 2>&1; then
    NEEDS_REBUILD=1
  fi
  CANDIDATE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
  CANDIDATE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$CANDIDATE_VERSION" != "$EXPECTED_VERSION" ||
        "$CANDIDATE_BUILD" != "$EXPECTED_BUILD" ]]; then
    echo "Кандидат имеет версию $CANDIDATE_VERSION ($CANDIDATE_BUILD), ожидается $EXPECTED_VERSION ($EXPECTED_BUILD)."
    NEEDS_REBUILD=1
  fi
  if (( NEEDS_REBUILD != 0 )); then
    echo "Кандидат изменился; переношу его в private attempt state."
    mv "$APP_PATH" "$ATTEMPT_STATE_ROOT/previous-NeAntik.app"
    mv "$CANDIDATE_MANIFEST" "$ATTEMPT_STATE_ROOT/previous-direct-candidate-manifest.json"
    prepare_candidate
  else
    echo "[1/4] PASS: использую неизменившийся кандидат $EXPECTED_VERSION ($EXPECTED_BUILD)."
  fi
elif [[ -e "$APP_PATH" || -e "$CANDIDATE_MANIFEST" ||
        -L "$CANDIDATE_MANIFEST" ]]; then
  echo "Найден неполный локальный кандидат; переношу его в private attempt state."
  if [[ -e "$APP_PATH" ]]; then
    mv "$APP_PATH" "$ATTEMPT_STATE_ROOT/previous-NeAntik.app"
  fi
  if [[ -e "$CANDIDATE_MANIFEST" || -L "$CANDIDATE_MANIFEST" ]]; then
    mv "$CANDIDATE_MANIFEST" "$ATTEMPT_STATE_ROOT/previous-direct-candidate-manifest.json"
  fi
  prepare_candidate
else
  prepare_candidate
fi

echo "[2/4] Проверяю изоляцию профилей A → B → A…"
REUSED_GUI_EVIDENCE=0
REUSE_CHECK_LOG="$ATTEMPT_STATE_ROOT/fingerprint-reuse-check.log"
for EXISTING_SCHEMA8_SOURCE in \
    "$PROJECT_DIR"/artifacts/neantik/private-release-attempts/*/attempt-*/fingerprint-evidence-schema8.json(.Nom); do
  if python3 "$PROJECT_DIR/scripts/collect-gui-fingerprint-evidence.py" \
      --source "$EXISTING_SCHEMA8_SOURCE" \
      --integrated-app "$APP_PATH" \
      --candidate-manifest "$CANDIDATE_MANIFEST" \
      --release-channel "$NEANTIK_RELEASE_CHANNEL" \
      --not-before 1970-01-01T00:00:00Z \
      --output "$REPORT_PATH" \
      >>"$REUSE_CHECK_LOG" 2>&1; then
    echo
    echo "PASS: использую уже проверенный отчёт для этого точного кандидата."
    REUSED_GUI_EVIDENCE=1
    break
  fi
done

attempt=1
while (( REUSED_GUI_EVIDENCE == 0 && attempt <= 3 )); do
  ATTEMPT_STATE_DIR="$ATTEMPT_STATE_ROOT/attempt-$attempt"
  python3 "$PROJECT_DIR/scripts/collect-gui-fingerprint-evidence.py" \
    --prepare-attempt-state "$ATTEMPT_STATE_DIR" \
    --release-channel "$NEANTIK_RELEASE_CHANNEL" \
    --output "$REPORT_PATH"
  SCHEMA8_SOURCE="$ATTEMPT_STATE_DIR/fingerprint-evidence-schema8.json"
  GUI_NOT_BEFORE="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo
  echo "Автоматически запускаю защищённую проверку A → B → A."
  echo "NeAntik сам выполнит проверку, сохранит валидный отчёт и завершится."
  "$APP_PATH/Contents/MacOS/NeAntik" \
    --neantik-release-fingerprint-audit \
    --candidate-manifest "$CANDIDATE_MANIFEST" \
    --output "$SCHEMA8_SOURCE" \
    >"$ATTEMPT_STATE_DIR/neantik-gui-launch.out" \
    2>"$ATTEMPT_STATE_DIR/neantik-gui-launch.err" &
  GUI_PID="$!"
  sleep 2
  if ! kill -0 "$GUI_PID" >/dev/null 2>&1; then
    echo "NeAntik не запустил окно проверки." >&2
    echo "Диагностика stdout: $ATTEMPT_STATE_DIR/neantik-gui-launch.out" >&2
    echo "Диагностика stderr: $ATTEMPT_STATE_DIR/neantik-gui-launch.err" >&2
    if [[ -s "$ATTEMPT_STATE_DIR/neantik-gui-launch.err" ]]; then
      sed -n '1,20p' "$ATTEMPT_STATE_DIR/neantik-gui-launch.err" >&2
    fi
  fi
  GUI_WAIT_SECONDS=0
  GUI_TIMEOUT_SECONDS=240
  while kill -0 "$GUI_PID" >/dev/null 2>&1; do
    if (( GUI_WAIT_SECONDS >= GUI_TIMEOUT_SECONDS )); then
      echo "Автоматическая GUI-проверка не завершилась за ${GUI_TIMEOUT_SECONDS} секунд." >&2
      kill -TERM "$GUI_PID" >/dev/null 2>&1 || true
      break
    fi
    sleep 1
    GUI_WAIT_SECONDS=$((GUI_WAIT_SECONDS + 1))
  done
  wait "$GUI_PID" >/dev/null 2>&1 || true

  if python3 "$PROJECT_DIR/scripts/collect-gui-fingerprint-evidence.py" \
    --source "$SCHEMA8_SOURCE" \
    --integrated-app "$APP_PATH" \
    --candidate-manifest "$CANDIDATE_MANIFEST" \
    --release-channel "$NEANTIK_RELEASE_CHANNEL" \
    --not-before "$GUI_NOT_BEFORE" \
    --output "$REPORT_PATH"; then
    break
  fi

  if (( attempt == 3 )); then
    echo
    echo "Свежий подписанный отчёт A → B → A не создан после трёх попыток." >&2
    echo "Notarization и публикация не запускались." >&2
    exit 66
  fi

  echo
  echo "Отчёт ещё не создан. Команда безопасно повторит автоматическую проверку."
  (( attempt += 1 ))
done

echo "[3/4] Отправляю кандидат в Apple notarization…"
"$PROJECT_DIR/scripts/notarize-direct-candidate.sh"

echo
echo "[4/4] PASS: архив подписан, принят Apple и проверен Gatekeeper."
echo "Готово: dist/NeAntik-0.3.14-arm64-notarized.zip"
echo "Публикация сайта и загрузки выполняется отдельным hosted release gate."

#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="$(
  "$PROJECT_DIR/scripts/resolve-compatible-developer-dir.sh"
)"
SOURCE_APP="$PROJECT_DIR/dist/NeAntik-Integrated.app"
APP_PATH="$PROJECT_DIR/dist/NeAntik.app"
CANDIDATE_MANIFEST="$PROJECT_DIR/dist/direct-candidate-manifest.json"
CANDIDATE_SOURCE_BINDING="$PROJECT_DIR/dist/direct-candidate-source.json"
REPORT_PATH="$PROJECT_DIR/dist/fingerprint-audit.json"
ATTEMPT_STATE_ROOT="$PROJECT_DIR/artifacts/neantik/private-release-attempts/$(date -u '+%Y%m%dT%H%M%SZ')-$$"
DEFAULT_SOURCE_PROVENANCE="/private/tmp/nevision-chromium-151/build/source-provenance.json"
EXPECTED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")"
EXPECTED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PROJECT_DIR/Resources/Info.plist")"

export NEANTIK_SIGNING_IDENTITY="${NEANTIK_SIGNING_IDENTITY:-62831D7DD86D5EDE0C44130F980325C4BFBC1B43}"
export NEANTIK_NOTARY_PROFILE="${NEANTIK_NOTARY_PROFILE:-neantik-notary}"
export NEANTIK_RELEASE_CHANNEL="${NEANTIK_RELEASE_CHANNEL:-public-alpha}"
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

cache_runtime_source_evidence() {
  local cached_dir="$ATTEMPT_STATE_ROOT/runtime-source-evidence"
  local configured_provenance="${NEANTIK_SOURCE_PROVENANCE:-}"
  local configured_lock="${NEANTIK_RUNTIME_CANDIDATE_LOCK:-}"
  local -a evidence_dirs

  if [[ -n "$configured_provenance" || -n "$configured_lock" ]]; then
    if [[ -z "$configured_provenance" || -z "$configured_lock" ||
          "$configured_provenance" != /* || "$configured_lock" != /* ||
          ! -f "$configured_provenance" || ! -f "$configured_lock" ]]; then
      echo "Runtime source evidence variables must name two existing absolute files." >&2
      return 66
    fi
    if ! "$PROJECT_DIR/scripts/verify-runtime-source-provenance.py" \
        "$configured_provenance" >/dev/null 2>&1 ||
      ! "$PROJECT_DIR/scripts/verify-runtime-candidate-lock.py" \
        "$configured_lock" "$configured_provenance" >/dev/null 2>&1; then
      echo "Configured runtime source evidence did not pass verification." >&2
      return 66
    fi
    mkdir -p "$cached_dir"
    cp "$configured_provenance" "$cached_dir/source-provenance.json"
    cp "$configured_lock" "$cached_dir/runtime-candidate-lock.json"
    chmod 0600 \
      "$cached_dir/source-provenance.json" \
      "$cached_dir/runtime-candidate-lock.json"
    export NEANTIK_SOURCE_PROVENANCE="$cached_dir/source-provenance.json"
    export NEANTIK_RUNTIME_CANDIDATE_LOCK="$cached_dir/runtime-candidate-lock.json"
    echo "Runtime source evidence: verified and cached for this release attempt."
    return 0
  else
    evidence_dirs=(
      "$(dirname "$DEFAULT_SOURCE_PROVENANCE")"
      "$APP_PATH/Contents/Resources/NeAntikRuntimeEvidence"
      "$SOURCE_APP/Contents/Resources/NeAntikRuntimeEvidence"
    )
    evidence_dirs+=(
      "${(@f)$(find "$PROJECT_DIR/artifacts/neantik/private-release-attempts" \
        -type f -name source-provenance.json -print 2>/dev/null |
        sed 's#/source-provenance\.json$##' |
        sort -r)}"
    )
  fi

  local evidence_dir
  for evidence_dir in "${evidence_dirs[@]}"; do
    [[ -n "$evidence_dir" ]] || continue
    local provenance="$evidence_dir/source-provenance.json"
    local lock="$evidence_dir/runtime-candidate-lock.json"
    if [[ ! -f "$lock" ]]; then
      lock="$evidence_dir/fingerprint-chromium.lock.json"
    fi
    [[ -f "$provenance" && -f "$lock" ]] || continue
    if ! "$PROJECT_DIR/scripts/verify-runtime-source-provenance.py" \
        "$provenance" >/dev/null 2>&1 ||
      ! "$PROJECT_DIR/scripts/verify-runtime-candidate-lock.py" \
        "$lock" "$provenance" >/dev/null 2>&1; then
      continue
    fi

    mkdir -p "$cached_dir"
    cp "$provenance" "$cached_dir/source-provenance.json"
    cp "$lock" "$cached_dir/runtime-candidate-lock.json"
    chmod 0600 \
      "$cached_dir/source-provenance.json" \
      "$cached_dir/runtime-candidate-lock.json"
    export NEANTIK_SOURCE_PROVENANCE="$cached_dir/source-provenance.json"
    export NEANTIK_RUNTIME_CANDIDATE_LOCK="$cached_dir/runtime-candidate-lock.json"
    echo "Runtime source evidence: verified and cached for this release attempt."
    return 0
  done

  echo "Не найдено проверенное доказательство происхождения встроенного Chromium." >&2
  echo "Сначала восстановите runtime evidence; release gate не был ослаблен." >&2
  return 66
}

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
  python3 "$PROJECT_DIR/scripts/direct-candidate-source-binding.py" create \
    --project-root "$PROJECT_DIR" \
    --manifest "$CANDIDATE_MANIFEST" \
    --binding "$CANDIDATE_SOURCE_BINDING"
}

echo "NeAntik $EXPECTED_VERSION — защищённый локальный этап выпуска"
echo "Секреты не запрашиваются: подпись и notarization используют Keychain."
echo "Этапы: сборка → проверка профилей → Apple notarization → готовый ZIP."
echo

mkdir -p "$ATTEMPT_STATE_ROOT"
chmod 0700 "$ATTEMPT_STATE_ROOT"
echo "Private attempt state: $ATTEMPT_STATE_ROOT"
cache_runtime_source_evidence

if [[ -d "$APP_PATH" && -f "$CANDIDATE_MANIFEST" &&
      ! -L "$CANDIDATE_MANIFEST" &&
      -f "$CANDIDATE_SOURCE_BINDING" &&
      ! -L "$CANDIDATE_SOURCE_BINDING" ]]; then
  echo "Проверяю уже подготовленный кандидат."
  NEEDS_REBUILD=0
  if ! python3 "$PROJECT_DIR/scripts/direct-candidate-manifest.py" verify \
      --app "$APP_PATH" \
      --manifest "$CANDIDATE_MANIFEST" \
      --release-channel "$NEANTIK_RELEASE_CHANNEL" \
      >"$ATTEMPT_STATE_ROOT/candidate-reuse-check.log" 2>&1; then
    NEEDS_REBUILD=1
  fi
  if ! python3 "$PROJECT_DIR/scripts/direct-candidate-source-binding.py" verify \
      --project-root "$PROJECT_DIR" \
      --manifest "$CANDIDATE_MANIFEST" \
      --binding "$CANDIDATE_SOURCE_BINDING" \
      >>"$ATTEMPT_STATE_ROOT/candidate-reuse-check.log" 2>&1; then
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
    mv "$CANDIDATE_SOURCE_BINDING" "$ATTEMPT_STATE_ROOT/previous-direct-candidate-source.json"
    prepare_candidate
  else
    echo "[1/4] PASS: использую неизменившийся кандидат $EXPECTED_VERSION ($EXPECTED_BUILD)."
  fi
elif [[ -e "$APP_PATH" || -e "$CANDIDATE_MANIFEST" ||
        -L "$CANDIDATE_MANIFEST" ||
        -e "$CANDIDATE_SOURCE_BINDING" ||
        -L "$CANDIDATE_SOURCE_BINDING" ]]; then
  echo "Найден неполный локальный кандидат; переношу его в private attempt state."
  if [[ -e "$APP_PATH" ]]; then
    mv "$APP_PATH" "$ATTEMPT_STATE_ROOT/previous-NeAntik.app"
  fi
  if [[ -e "$CANDIDATE_MANIFEST" || -L "$CANDIDATE_MANIFEST" ]]; then
    mv "$CANDIDATE_MANIFEST" "$ATTEMPT_STATE_ROOT/previous-direct-candidate-manifest.json"
  fi
  if [[ -e "$CANDIDATE_SOURCE_BINDING" ||
        -L "$CANDIDATE_SOURCE_BINDING" ]]; then
    mv "$CANDIDATE_SOURCE_BINDING" "$ATTEMPT_STATE_ROOT/previous-direct-candidate-source.json"
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
  python3 "$PROJECT_DIR/scripts/wait-for-neantik-runtime-drain.py" \
    --app "$APP_PATH"
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
  GUI_TIMED_OUT=0
  while kill -0 "$GUI_PID" >/dev/null 2>&1; do
    if (( GUI_WAIT_SECONDS >= GUI_TIMEOUT_SECONDS )); then
      echo "Автоматическая GUI-проверка не завершилась за ${GUI_TIMEOUT_SECONDS} секунд." >&2
      kill -TERM "$GUI_PID" >/dev/null 2>&1 || true
      GUI_TIMED_OUT=1
      break
    fi
    sleep 1
    GUI_WAIT_SECONDS=$((GUI_WAIT_SECONDS + 1))
  done
  GUI_EXIT_STATUS=0
  wait "$GUI_PID" >/dev/null 2>&1 || GUI_EXIT_STATUS="$?"
  python3 "$PROJECT_DIR/scripts/wait-for-neantik-runtime-drain.py" \
    --app "$APP_PATH"
  if (( GUI_TIMED_OUT != 0 )); then
    echo "Повторная попытка после timeout запрещена; notarization не запускалась." >&2
    exit 67
  fi
  if (( GUI_EXIT_STATUS != 0 )); then
    echo "NeAntik завершил автоматическую проверку с кодом $GUI_EXIT_STATUS." >&2
    echo "Notarization не запускалась." >&2
    exit 66
  fi

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
  echo "Отчёт ещё не создан. Жду полного завершения Chromium и безопасно повторяю проверку."
  sleep 3
  (( attempt += 1 ))
done

python3 "$PROJECT_DIR/scripts/wait-for-neantik-runtime-drain.py" \
  --app "$APP_PATH" \
  --timeout 45

python3 "$PROJECT_DIR/scripts/direct-candidate-source-binding.py" verify \
  --project-root "$PROJECT_DIR" \
  --manifest "$CANDIDATE_MANIFEST" \
  --binding "$CANDIDATE_SOURCE_BINDING"

echo "[3/4] Отправляю кандидат в Apple notarization…"
"$PROJECT_DIR/scripts/notarize-direct-candidate.sh"

echo
echo "[4/4] PASS: архив подписан, принят Apple и проверен Gatekeeper."
echo "Готово: dist/NeAntik-$EXPECTED_VERSION-arm64-notarized.zip"
echo "Публикация сайта и загрузки выполняется отдельным hosted release gate."

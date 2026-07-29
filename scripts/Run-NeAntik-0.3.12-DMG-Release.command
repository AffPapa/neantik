#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

pause_on_error() {
  local exit_code=$?
  trap - ERR
  echo
  echo "Создание DMG остановлено на безопасной проверке (код $exit_code)."
  echo "Ничего не опубликовано. Скопируйте только текст ошибки, без секретов."
  if [[ -t 0 ]]; then
    read -r "?Нажмите Return, чтобы закрыть окно… " || true
  fi
  exit "$exit_code"
}
trap pause_on_error ERR

export NEANTIK_NOTARY_PROFILE="${NEANTIK_NOTARY_PROFILE:-neantik-notary}"

echo "NeAntik 0.3.12 — создание проверенного DMG"
echo "Источник: $PROJECT_DIR/dist/NeAntik.app"
echo "Подпись определяется из готового приложения."
echo "Notarization использует профиль Keychain: $NEANTIK_NOTARY_PROFILE"
echo "Пароли и ключи не запрашиваются и не выводятся."
echo

"$PROJECT_DIR/scripts/release-direct-dmg.sh"

echo
echo "DMG готов локально. GitHub и сайт ещё не изменялись."
echo "Следующий этап — загрузить DMG как дополнительный asset и проверить его после скачивания."
if [[ -t 0 ]]; then
  read -r "?Нажмите Return, чтобы закрыть окно… "
fi

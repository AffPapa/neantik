#!/bin/zsh
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CANDIDATE_ROOT="${NEANTIK_DIRECT_CANDIDATE_ROOT:?Set the preserved registered candidate root}"
python3 -B "$PROJECT_DIR/scripts/prepared_manager_bundle.py" verify --project-root "$PROJECT_DIR" --root "$CANDIDATE_ROOT"
APP="$CANDIDATE_ROOT/NeAntik.app"
MANIFEST="$CANDIDATE_ROOT/direct-candidate-manifest.json"
BINDING="$CANDIDATE_ROOT/direct-candidate-source.json"
ENROLLMENT="$CANDIDATE_ROOT/fingerprint-enrollment.json"
if [[ ! -e "$MANIFEST" && ! -L "$MANIFEST" ]]; then
  # Refusal occurs before any authority allocation, never after rebuilding.
  python3 -B "$PROJECT_DIR/scripts/native-qa-readiness.py" --check
  ACTION="$(python3 -B "$PROJECT_DIR/scripts/prepared_manager_bundle.py" reserve-enrollment --project-root "$PROJECT_DIR" --root "$CANDIDATE_ROOT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
  if [[ "$ACTION" == "new-enrollment" ]]; then
    "$PROJECT_DIR/scripts/enroll-direct-fingerprint-authority.sh" "$APP" "$ENROLLMENT"
  elif [[ "$ACTION" != "reuse-enrollment" ]]; then
    echo "Unknown enrollment state; preserve candidate." >&2; exit 65
  fi
  python3 -B "$PROJECT_DIR/scripts/direct-candidate-manifest.py" create --app "$APP" --manifest "$MANIFEST" --release-channel "$NEANTIK_RELEASE_CHANNEL" --fingerprint-enrollment "$ENROLLMENT"
fi
python3 -B "$PROJECT_DIR/scripts/direct-candidate-manifest.py" verify --app "$APP" --manifest "$MANIFEST" --release-channel "$NEANTIK_RELEASE_CHANNEL"
if [[ ! -e "$BINDING" && ! -L "$BINDING" ]]; then
  python3 -B "$PROJECT_DIR/scripts/direct-candidate-source-binding.py" create --project-root "$PROJECT_DIR" --manifest "$MANIFEST" --binding "$BINDING"
fi
python3 -B "$PROJECT_DIR/scripts/direct-candidate-source-binding.py" verify --project-root "$PROJECT_DIR" --manifest "$MANIFEST" --binding "$BINDING"
echo "Prepared candidate bound; exact headed qualification and Direct archive gates remain required."

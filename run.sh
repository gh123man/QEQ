#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Build and launch the app from the repo root.

Usage:
  ./run.sh [--clean] [--no-build]

Options:
  --clean       Do a clean rebuild before launch
  --no-build    Launch the existing app bundle without rebuilding
  -h, --help    Show this help
USAGE
}

terminate_existing_app() {
  local process_name="$1"
  if ! pgrep -x "$process_name" >/dev/null 2>&1; then
    return
  fi

  pkill -TERM -x "$process_name" >/dev/null 2>&1 || true
  for _ in {1..20}; do
    local process_name="$1"
  if ! pgrep -x "$process_name" >/dev/null 2>&1; then
      return
    fi
    sleep 0.1
  done
  pkill -x "$process_name" >/dev/null 2>&1 || true
}

CLEAN_BUILD=false
SKIP_BUILD=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)
      CLEAN_BUILD=true
      shift
      ;;
    --no-build)
      SKIP_BUILD=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$SKIP_BUILD" == true && "$CLEAN_BUILD" == true ]]; then
  echo "--clean cannot be combined with --no-build" >&2
  usage >&2
  exit 1
fi

terminate_existing_app AppMixer
terminate_existing_app QEQ
if [[ "$SKIP_BUILD" == false ]]; then
  if [[ "$CLEAN_BUILD" == true ]]; then
    "$SCRIPT_DIR/AppMixer/scripts/build_macos_app.sh" --clean
  else
    "$SCRIPT_DIR/AppMixer/scripts/build_macos_app.sh"
  fi
fi
exec "$SCRIPT_DIR/AppMixer/scripts/run_macos_app.sh"

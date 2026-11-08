#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Build and launch the app from the repo root.

Usage:
  ./run.sh [--clean] [--no-build] [--profile <jsonl>] [--profile-ui <jsonl>]

Options:
  --clean       Do a clean rebuild before launch
  --no-build    Launch the existing app bundle without rebuilding
  --profile     Record 30 seconds of CPU/route counters with the popup open/closed
  --profile-ui  Profile reproducible animated UI fixtures without capturing/playing audio
  --display-stream  Export latest hardware raster to an absolute prototype directory
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
PROFILE_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --display-stream)
      [[ $# -ge 2 && "$2" == /* ]] || { echo "--display-stream requires an absolute directory" >&2; exit 1; }
      PROFILE_ARGS=(--display-stream "$2")
      shift 2
      ;;
    --clean)
      CLEAN_BUILD=true
      shift
      ;;
    --profile-ui)
      [[ $# -ge 2 && "$2" == /* ]] || { echo "--profile-ui requires an absolute output file path" >&2; exit 1; }
      PROFILE_ARGS=(--profile-ui "$2")
      shift 2
      ;;
    --profile)
      [[ $# -ge 2 && "$2" == /* ]] || { echo "--profile requires an absolute output file path" >&2; exit 1; }
      PROFILE_ARGS=(--profile-performance "$2")
      shift 2
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

terminate_existing_app QEQ
if [[ "$SKIP_BUILD" == false ]]; then
  if [[ "$CLEAN_BUILD" == true ]]; then
    "$SCRIPT_DIR/QEQ/scripts/build_macos_app.sh" --clean
  else
    "$SCRIPT_DIR/QEQ/scripts/build_macos_app.sh"
  fi
fi
if [[ ${#PROFILE_ARGS[@]} -gt 0 ]]; then
  exec "$SCRIPT_DIR/QEQ/scripts/run_macos_app.sh" "${PROFILE_ARGS[@]}"
else
  exec "$SCRIPT_DIR/QEQ/scripts/run_macos_app.sh"
fi

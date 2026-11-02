#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BUNDLE="$PACKAGE_DIR/.dist/AppMixer.app"

if [[ ! -d "$APP_BUNDLE" ]]; then
  "$SCRIPT_DIR/build_macos_app.sh"
fi

open "$APP_BUNDLE"

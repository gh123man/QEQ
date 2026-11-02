#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Build a local macOS .app bundle.

Usage:
  build_macos_app.sh [--clean] [--configuration debug|release] [--output <dir>] [--bundle-id <id>]
USAGE
}

CONFIGURATION="release"
OUTPUT_DIR=""
BUNDLE_ID="${APP_BUNDLE_ID:-local.AppMixer}"
CLEAN_BUILD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)
      CLEAN_BUILD=true
      shift
      ;;
    --configuration)
      CONFIGURATION="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"
      shift 2
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

if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
  echo "Invalid configuration: $CONFIGURATION" >&2
  exit 1
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$PACKAGE_DIR/.dist}"
DERIVED_DATA_PATH="$OUTPUT_DIR/.derived-data"
APP_BUNDLE="$OUTPUT_DIR/QEQ.app"
XCODE_CONFIGURATION="$(tr '[:lower:]' '[:upper:]' <<< "${CONFIGURATION:0:1}")${CONFIGURATION:1}"

require_cmd xcodebuild
require_cmd xcodegen
require_cmd ditto

mkdir -p "$OUTPUT_DIR"
"$SCRIPT_DIR/generate_xcodeproj.sh"

ACTIONS=(build)
if [[ "$CLEAN_BUILD" == true ]]; then
  ACTIONS=(clean build)
fi

xcodebuild \
  -project "$PACKAGE_DIR/QEQ.xcodeproj" \
  -scheme QEQ \
  -configuration "$XCODE_CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  "${ACTIONS[@]}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"

BUILT_APP="$DERIVED_DATA_PATH/Build/Products/$XCODE_CONFIGURATION/QEQ.app"
[[ -d "$BUILT_APP" ]] || { echo "Built app not found: $BUILT_APP" >&2; exit 1; }
rm -rf "$APP_BUNDLE"
ditto "$BUILT_APP" "$APP_BUNDLE"

python3 "$SCRIPT_DIR/configure_bundle.py" "$APP_BUNDLE"

require_cmd codesign
codesign --force --deep --preserve-metadata=entitlements --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "App bundle ready: $APP_BUNDLE"

#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
while IFS= read -r file; do bash -n "$file"; done < <(find AppMixer/scripts -name '*.sh' -print)
bash -n run.sh
python3 -c 'import ast; from pathlib import Path; ast.parse(Path("AppMixer/scripts/release.py").read_text())'
xcrun swift-format lint --strict --recursive AppMixer/App/Sources AppMixer/Sources AppMixer/Tests AppMixer/Package.swift
swift test --package-path AppMixer
./AppMixer/scripts/build_macos_app.sh --configuration release

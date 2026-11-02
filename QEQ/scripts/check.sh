#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
while IFS= read -r file; do bash -n "$file"; done < <(find QEQ/scripts -name '*.sh' -print)
bash -n run.sh
python3 -c 'import ast; from pathlib import Path; [ast.parse(p.read_text()) for p in Path("QEQ/scripts").glob("*.py")]'
python3 -B -m unittest discover -s QEQ/scripts/tests
xcrun swift-format lint --strict --recursive QEQ/App/Sources QEQ/Sources QEQ/Tests QEQ/Package.swift
swift test --package-path QEQ
./QEQ/scripts/build_macos_app.sh --configuration release

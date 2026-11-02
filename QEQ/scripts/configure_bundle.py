#!/usr/bin/env python3
"""Apply version and public update-verification metadata before signing."""
import base64
import json
from pathlib import Path
import plistlib
import sys

PACKAGE = Path(__file__).resolve().parents[1]


def configure(app):
    config = json.loads((PACKAGE / 'release.json').read_text())
    key_path = PACKAGE / 'update-signing.json'
    key = json.loads(key_path.read_text())['publicEDKey'] if key_path.exists() else ''
    if key and len(base64.b64decode(key, validate=True)) != 32:
        raise SystemExit('Invalid update public key')
    path = app / 'Contents/Info.plist'
    with path.open('rb') as handle:
        values = plistlib.load(handle)
    values.update(QEQReleaseVersion=config['version'], CFBundleVersion=str(config['build']),
                  SUPublicEDKey=key)
    with path.open('wb') as handle:
        plistlib.dump(values, handle)


if __name__ == '__main__':
    configure(Path(sys.argv[1]))

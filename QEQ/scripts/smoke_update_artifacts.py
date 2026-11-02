#!/usr/bin/env python3
"""Offline updater packaging smoke test; disposable in-memory key, no publication."""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

import update_artifacts


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tools', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir()  # Refuse to replace any previous test or release.
    package = Path(__file__).resolve().parents[1]
    # Capture the disposable key directly in memory. Do not print or write it.
    code = '''import CryptoKit; import Foundation
let key = Curve25519.Signing.PrivateKey()
let data = try JSONSerialization.data(withJSONObject: ["public": key.publicKey.rawRepresentation.base64EncodedString(), "private": key.rawRepresentation.base64EncodedString()])
FileHandle.standardOutput.write(data)'''
    keys = json.loads(run('swift', '-e', code, capture_output=True, text=True).stdout)
    config = json.loads((package / 'release.json').read_text())
    app = out / 'QEQ.app'
    run('ditto', str(package / '.dist/QEQ.app'), str(app))
    info = app / 'Contents/Info.plist'
    values = plistlib.loads(info.read_bytes())
    values.update(SUPublicEDKey=keys['public'], SURequireSignedFeed=True, CFBundleVersion=str(config['build']),
                  CFBundleShortVersionString=config['version'])
    info.write_bytes(plistlib.dumps(values))
    for target in update_artifacts.signing_targets(app):
        run('codesign', '--force', '--preserve-metadata=entitlements', '--sign', '-', str(target), capture_output=True)
    run('codesign', '--verify', '--deep', '--strict', str(app))
    artifacts = out / 'artifacts'
    artifacts.mkdir()
    archive = artifacts / f'QEQ-{config["version"]}-macOS.zip'
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive))
    # Dependency injection keeps this smoke test independent of production credentials.
    update_artifacts.public_key = lambda: keys['public']
    feed = update_artifacts.generate(archive, config, args.tools.resolve(), keys['private'])
    signature = update_artifacts.validate_appcast(feed, archive, config)
    # A modified archive must be rejected by the same public-key verification.
    with archive.open('ab') as handle:
        handle.write(b'tampered')
    result = subprocess.run(['swift', str(package / 'scripts/verify_update.swift'), keys['public'], str(archive), signature],
                            capture_output=True)
    if result.returncode == 0:
        raise SystemExit('Tampered archive was incorrectly accepted')
    print('PASS: signed feed + archive verified; tampered archive rejected; nested helper signatures intact.')
    # Avoid leaving a deliberately altered ZIP that could be mistaken for a release.
    shutil.rmtree(out)


if __name__ == '__main__':
    main()

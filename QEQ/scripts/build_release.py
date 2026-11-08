#!/usr/bin/env python3
"""Build, Developer ID sign, notarize, staple and verify both release formats."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

import update_artifacts

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / 'QEQ'


def run(*args, capture=False):
    result = subprocess.run(args, cwd=ROOT, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def notarize(path, label, logs):
    credentials = ['--key', os.environ['NOTARY_KEY_PATH'], '--key-id', os.environ['APPLE_NOTARY_KEY_ID'],
                   '--issuer', os.environ['APPLE_NOTARY_ISSUER_ID']]
    result = json.loads(run('xcrun', 'notarytool', 'submit', str(path), *credentials,
                            '--wait', '--timeout', '30m', '--output-format', 'json', capture=True))
    (logs / f'notary-{label}.json').write_text(json.dumps(result, indent=2) + '\n')
    if result.get('status') != 'Accepted':
        if result.get('id'):
            run('xcrun', 'notarytool', 'log', result['id'], *credentials, str(logs / f'notary-{label}-issues.json'))
        raise SystemExit(f'{label} notarization was not accepted: {result.get("status")}')
    return result['id']


def verify_signature(path, team, runtime=False):
    run('codesign', '--verify', '--deep', '--strict', '--verbose=2', str(path))
    signature = subprocess.run(['codesign', '-d', '--verbose=4', str(path)], check=True,
                               text=True, capture_output=True).stderr
    require('Authority=Developer ID Application:' in signature, 'Expected Developer ID Application signature')
    require(f'TeamIdentifier={team}' in signature, 'Unexpected signing team')
    require('Timestamp=' in signature, 'Expected secure timestamp')
    if runtime:
        require('runtime' in signature, 'Expected hardened runtime')
    return signature


def main():
    config = json.loads((PACKAGE / 'release.json').read_text())
    version = config['version']
    require(re.fullmatch(r'\d+\.\d+\.\d+(?:-rc\.\d+)?', version), 'Invalid release version')
    require(config['signing'] == 'Developer ID Application' and config['notarized'] is True,
            'Release must require Developer ID signing and notarization')
    require(os.environ.get('RELEASE_REF_NAME') == f'v{version}', 'Tag and release.json must match')
    update_artifacts.public_key()
    require(os.environ.get('QEQ_SPARKLE_PRIVATE_ED_KEY'), 'Missing QEQ update signing secret')
    commit = run('git', 'rev-parse', 'HEAD', capture=True)
    require(commit == run('git', 'rev-parse', f'v{version}^{{commit}}', capture=True), 'Checkout does not match tag')
    team = os.environ['APPLE_DEVELOPER_TEAM_ID']
    identities = run('security', 'find-identity', '-v', '-p', 'codesigning', os.environ['KEYCHAIN_PATH'], capture=True)
    matches = re.findall(r'([0-9A-F]{40}) "Developer ID Application: [^"\n]+ \(' + re.escape(team) + r'\)"', identities)
    require(len(matches) == 1, 'Expected exactly one Developer ID Application identity for the configured team')
    identity = matches[0]
    out = PACKAGE / '.release' / version
    require(not out.exists(), 'Release output already exists')
    out.mkdir(parents=True)
    logs = out / 'logs'
    logs.mkdir()
    artifacts = out / 'artifacts'
    artifacts.mkdir()
    run(str(PACKAGE / 'scripts/build_macos_app.sh'), '--configuration', 'release',
        '--output', str(out / 'build'), '--bundle-id', config['bundleIdentifier'])
    app = out / 'build/QEQ.app'
    info = app / 'Contents/Info.plist'
    with info.open('rb') as handle:
        values = plistlib.load(handle)
    values.update(CFBundleShortVersionString=version, CFBundleVersion=str(config['build']),
                  QEQReleaseVersion=version, QEQSourceCommit=commit, QEQBuildChannel='release')
    with info.open('wb') as handle:
        plistlib.dump(values, handle)
    # Sign Sparkle helpers inside-out, retaining their sandbox entitlements.
    for target in update_artifacts.signing_targets(app):
        run('codesign', '--force', '--preserve-metadata=entitlements', '--options', 'runtime', '--timestamp',
            '--keychain', os.environ['KEYCHAIN_PATH'], '--sign', identity, str(target))
        verify_signature(target, team, runtime=True)
    signature = verify_signature(app, team, runtime=True)
    architectures = run('lipo', '-archs', str(app / 'Contents/MacOS/QEQ'), capture=True).split()
    require(set(architectures) == {'arm64'}, 'Release must be Apple Silicon only (arm64)')
    submission = out / 'app-notary-submission.zip'
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(submission))
    app_submission = notarize(submission, 'app', logs)
    run('xcrun', 'stapler', 'staple', str(app))
    run('xcrun', 'stapler', 'validate', str(app))
    run('spctl', '--assess', '--verbose=2', '--type', 'execute', str(app))
    archive = artifacts / f'QEQ-{version}-macOS.zip'
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive))
    staging = out / 'dmg-staging'
    staging.mkdir()
    run('ditto', str(app), str(staging / 'QEQ.app'))
    (staging / 'Applications').symlink_to('/Applications')
    dmg = artifacts / f'QEQ-{version}-macOS.dmg'
    run('hdiutil', 'create', '-volname', 'QEQ', '-srcfolder', str(staging), '-format', 'UDZO', str(dmg))
    run('codesign', '--sign', identity, '--timestamp', '--keychain', os.environ['KEYCHAIN_PATH'], str(dmg))
    verify_signature(dmg, team)
    dmg_submission = notarize(dmg, 'dmg', logs)
    run('xcrun', 'stapler', 'staple', str(dmg))
    run('xcrun', 'stapler', 'validate', str(dmg))
    run('spctl', '--assess', '--verbose=2', '--type', 'open', '--context', 'context:primary-signature', str(dmg))
    run('hdiutil', 'verify', str(dmg))
    # Confirm ZIP packaging preserved the app's signature and offline ticket.
    extracted = out / 'zip-verification'
    run('ditto', '-x', '-k', str(archive), str(extracted))
    verify_signature(extracted / 'QEQ.app', team, runtime=True)
    run('xcrun', 'stapler', 'validate', str(extracted / 'QEQ.app'))
    manifest = dict(config, sourceCommit=commit, sourceRepository=os.environ['GITHUB_REPOSITORY'],
                    tag=f'v{version}', architectures=architectures,
                    xcode=run('xcodebuild', '-version', capture=True),
                    notarization={'app': app_submission, 'dmg': dmg_submission, 'status': 'Accepted', 'stapled': True},
                    signature=[line for line in signature.splitlines()
                               if line.startswith(('Authority=', 'TeamIdentifier=', 'Timestamp=', 'CDHash='))])
    manifest_path = artifacts / 'release-manifest.json'
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    screenshots = PACKAGE / '.release/screenshots'
    run('python3', 'QEQ/scripts/screenshots.py', '--check', '--output', str(screenshots))
    screenshot_archive = Path(shutil.make_archive(str(artifacts / f'QEQ-{version}-screenshots'), 'zip', screenshots))
    appcast = update_artifacts.generate(archive, config, Path(os.environ['SPARKLE_TOOLS_DIR']),
                                       os.environ['QEQ_SPARKLE_PRIVATE_ED_KEY'])
    paths = [archive, dmg, manifest_path, screenshot_archive, appcast]
    (artifacts / 'SHA256SUMS').write_text(''.join(
        f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n' for path in paths))
    print(f'Notarized and stapled release artifacts: {artifacts}')


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)

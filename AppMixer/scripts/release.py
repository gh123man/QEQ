#!/usr/bin/env python3
"""Tag pushed, validated main to trigger Developer ID signing and notarization on GitHub."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def run(*args, capture=False):
    result = subprocess.run(args, cwd=ROOT, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--publish', action='store_true', help='Push the release tag to start the GitHub workflow')
    args = parser.parse_args()
    config = json.loads((ROOT / 'AppMixer/release.json').read_text())
    version = config['version']
    require(re.fullmatch(r'\d+\.\d+\.\d+-rc\.\d+', version), 'Expected an RC version')
    require(config['signing'] == 'Developer ID Application' and config['notarized'] is True,
            'Release policy must require Developer ID signing and notarization')
    require(not run('git', 'status', '--porcelain', capture=True), 'Working tree must be clean')
    require(run('git', 'branch', '--show-current', capture=True) == 'main', 'Release from main')
    run('git', 'fetch', 'origin', 'main', '--tags')
    commit = run('git', 'rev-parse', 'HEAD', capture=True)
    require(commit == run('git', 'rev-parse', 'origin/main', capture=True), 'Push main before releasing')
    runs = json.loads(run('gh', 'run', 'list', '--workflow', 'ci.yml', '--commit', commit,
                          '--json', 'status,conclusion', '--limit', '1', capture=True))
    require(runs and runs[0]['status'] == 'completed' and runs[0]['conclusion'] == 'success',
            'The latest CI run for this commit must pass')
    tag = f'v{version}'
    require(not run('git', 'tag', '--list', tag, capture=True), f'Tag already exists: {tag}')
    require((ROOT / 'AppMixer/ReleaseNotes' / f'{version}.md').is_file(), 'Missing release notes')
    secrets = json.loads(run('gh', 'secret', 'list', '--json', 'name', capture=True))
    required = {'APPLE_DEVELOPER_ID_APP_CERT_BASE64', 'APPLE_DEVELOPER_ID_APP_CERT_PASSWORD',
                'APPLE_DEVELOPER_TEAM_ID', 'APPLE_NOTARY_API_KEY_P8', 'APPLE_NOTARY_KEY_ID',
                'APPLE_NOTARY_ISSUER_ID'}
    require(required <= {secret['name'] for secret in secrets}, 'Missing GitHub Apple signing secrets')
    run('swift', 'test', '--package-path', 'AppMixer')
    if args.publish:
        run('git', 'tag', '-a', tag, '-m', f'AppMixer {version}: Developer ID signed and notarized RC')
        run('git', 'push', 'origin', tag)
        print(f'Pushed {tag}. Follow the Release DMG workflow; only verified artifacts will be published.')
    else:
        print(f'Ready to release {tag} from {commit}. Pass --publish to trigger the workflow.')


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)

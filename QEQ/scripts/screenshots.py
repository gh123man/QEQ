#!/usr/bin/env python3
"""Refresh native UI screenshots or verify their source/image provenance."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
NAMES = ('empty', 'mixer', 'equalizer', 'global-equalizer', 'empty-after-removal', 'update-available', 'settings', 'excluded-apps', 'desktop-mixer', 'desktop-app-equalizer', 'hardware-slots', 'hardware-slot-picker', 'hardware-retained-apps', 'hardware-disconnected')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sources():
    paths = list((ROOT / 'QEQ/App/Sources').glob('*.swift'))
    paths += list((ROOT / 'QEQ/Sources/QEQCore').glob('*.swift'))
    paths += list((ROOT / 'QEQ/Sources/QEQAppSupport').glob('*.swift'))
    paths += [ROOT / 'QEQ/project.yml', Path(__file__).resolve()]
    return {str(p.relative_to(ROOT)): digest(p) for p in sorted(paths)}


def verify(output):
    manifest = output / 'screenshots.json'
    if not manifest.is_file():
        raise SystemExit('Missing screenshots. Run cut_release.sh --prepare, then commit the updated images.')
    saved = json.loads(manifest.read_text())
    if saved.get('sources') != sources():
        raise SystemExit('Screenshots are stale. Run cut_release.sh --prepare, then commit the updated images.')
    expected = {name + '.png' for name in NAMES}
    if set(saved.get('images', {})) != expected:
        raise SystemExit('Screenshot set is incomplete.')
    for name, sha in saved['images'].items():
        path = output / name
        if not path.is_file() or digest(path) != sha:
            raise SystemExit(f'Screenshot changed without regeneration: {name}')
    print('Screenshots match the current UI source and image checksums.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'docs/media')
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--skip-build', action='store_true', help='Use the app just built by CI/check.sh')
    args = parser.parse_args()
    output = args.output.resolve()
    if args.check:
        verify(output)
        return
    if not args.skip_build:
        subprocess.run([str(ROOT / 'QEQ/scripts/build_macos_app.sh'), '--configuration', 'release'], check=True)
    command = [str(ROOT / 'QEQ/.dist/QEQ.app/Contents/MacOS/QEQ'), '--render-screenshots', str(output)]
    with subprocess.Popen(command) as renderer:
        try:
            status = renderer.wait(timeout=90)
        except subprocess.TimeoutExpired:
            sample = ROOT / 'QEQ/.release/screenshot-render.sample.txt'
            sample.parent.mkdir(parents=True, exist_ok=True)
            try:
                subprocess.run(['sample', str(renderer.pid), '2', '-file', str(sample)], timeout=15)
            finally:
                renderer.kill()
                renderer.wait()
            raise SystemExit(f'Screenshot renderer timed out; process sample: {sample}')
        if status:
            raise SystemExit(f'Screenshot renderer exited with status {status}')
    record = {'sources': sources(), 'images': {name + '.png': digest(output / (name + '.png')) for name in NAMES}}
    (output / 'screenshots.json').write_text(json.dumps(record, indent=2) + '\n')
    verify(output)


if __name__ == '__main__':
    main()

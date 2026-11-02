#!/usr/bin/env python3
"""Sign Sparkle's nested code and produce a signed, verified per-release appcast."""
import base64
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as ET

PACKAGE = Path(__file__).resolve().parents[1]
SPARKLE_NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'


def signing_targets(app):
    framework = app / 'Contents/Frameworks/Sparkle.framework'
    base = framework / 'Versions/B'
    targets = [base / 'XPCServices/Downloader.xpc', base / 'XPCServices/Installer.xpc',
               base / 'Autoupdate', base / 'Updater.app', framework, app]
    for target in targets:
        if not target.exists():
            raise SystemExit(f'Missing bundled updater component: {target.name}')
    return targets


def public_key():
    key = json.loads((PACKAGE / 'update-signing.json').read_text())['publicEDKey']
    if len(base64.b64decode(key, validate=True)) != 32:
        raise SystemExit('A valid QEQ update public key is required for releases')
    return key


def validate_appcast(path, archive, config):
    root = ET.parse(path).getroot()
    items = root.findall('./channel/item')
    if len(items) != 1:
        raise SystemExit('Expected exactly one update in the per-release appcast')
    item = items[0]
    enclosure = item.find('enclosure')
    expected = f'https://github.com/gh123man/QEQ/releases/download/v{config["version"]}/{archive.name}'
    if enclosure is None or enclosure.get('url') != expected:
        raise SystemExit('Unexpected update download URL')
    if enclosure.get('length') != str(archive.stat().st_size):
        raise SystemExit('Update archive length mismatch')
    if item.findtext(f'{{{SPARKLE_NS}}}version') != str(config['build']):
        raise SystemExit('Update build number mismatch')
    signature = enclosure.get(f'{{{SPARKLE_NS}}}edSignature', '')
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise SystemExit('Missing or invalid archive signature')
    return signature


def generate(archive, config, tools, private_key):
    if not private_key:
        raise SystemExit('QEQ_SPARKLE_PRIVATE_ED_KEY is required')
    key = public_key()
    staging = archive.parent.parent / 'appcast-staging'
    staging.mkdir()
    copied = staging / archive.name
    shutil.copy2(archive, copied)
    shutil.copy2(PACKAGE / 'ReleaseNotes' / (config['version'] + '.md'), copied.with_suffix('.md'))
    feed = archive.parent / 'appcast.xml'
    prefix = f'https://github.com/gh123man/QEQ/releases/download/v{config["version"]}/'
    args = [str(tools / 'bin/generate_appcast'), '--ed-key-file', '-', '--download-url-prefix', prefix,
            '--full-release-notes-url', f'https://github.com/gh123man/QEQ/releases/tag/v{config["version"]}',
            '--embed-release-notes', '--maximum-versions', '1', '-o', str(feed), str(staging)]
    # Never put private keys in command arguments, logs, or temporary files.
    result = subprocess.run(args, input=private_key, text=True, capture_output=True)
    if result.returncode:
        raise SystemExit('Sparkle appcast generation/signing failed')
    signature = validate_appcast(feed, archive, config)
    subprocess.run(['swift', str(PACKAGE / 'scripts/verify_update.swift'), key, str(archive), signature], check=True)
    result = subprocess.run([str(tools / 'bin/sign_update'), '--verify', '--ed-key-file', '-', str(feed)],
                            input=private_key, text=True, capture_output=True)
    if result.returncode:
        raise SystemExit('Sparkle feed signature verification failed')
    if hashlib.sha256(copied.read_bytes()).digest() != hashlib.sha256(archive.read_bytes()).digest():
        raise SystemExit('Update archive changed during appcast generation')
    return feed

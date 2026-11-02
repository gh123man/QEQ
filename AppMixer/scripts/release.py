#!/usr/bin/env python3
"""Build a certificate-signed RC from clean, pushed main; optionally publish privately."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "AppMixer"


def run(*args, capture=False, cwd=ROOT):
    result = subprocess.run(args, cwd=cwd, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--publish", action="store_true", help="Tag and upload a private GitHub prerelease")
    args = parser.parse_args()
    config = json.loads((PACKAGE / "release.json").read_text())
    version = config["version"]
    require(re.fullmatch(r"\d+\.\d+\.\d+-rc\.\d+", version), "Expected an RC version in release.json")
    require(config["signing"] == "Apple Development" and config["notarized"] is False,
            "This internal RC workflow supports Apple Development signing only")
    identity = os.environ.get("SIGNING_IDENTITY", "")
    require(re.fullmatch(r"[0-9A-Fa-f]{40}", identity), "Set SIGNING_IDENTITY to a Keychain certificate SHA-1")
    require(not run("git", "status", "--porcelain", capture=True), "Working tree must be clean")
    require(run("git", "branch", "--show-current", capture=True) == "main", "Release from main")
    run("git", "fetch", "origin", "main", "--tags")
    commit = run("git", "rev-parse", "HEAD", capture=True)
    require(commit == run("git", "rev-parse", "origin/main", capture=True), "Push main before building a release")
    repo = json.loads(run("gh", "repo", "view", "--json", "nameWithOwner,visibility", capture=True))
    require(repo["visibility"] == "PRIVATE", "Internal RC releases require a private repository")
    runs = json.loads(run("gh", "run", "list", "--workflow", "ci.yml", "--commit", commit,
                          "--json", "status,conclusion", "--limit", "1", capture=True))
    require(runs and runs[0]["status"] == "completed" and runs[0]["conclusion"] == "success",
            "The latest CI run for this commit must pass before release")
    identities = run("security", "find-identity", "-v", "-p", "codesigning", capture=True)
    require(any(identity.upper() in line.upper() and '"Apple Development:' in line
                for line in identities.splitlines()), "Identity must be an available Apple Development certificate")
    notes = PACKAGE / "ReleaseNotes" / f"{version}.md"
    require(notes.is_file(), f"Missing release notes: {notes}")
    tag = f"v{version}"
    tags = run("git", "tag", "--list", tag, capture=True)
    require(not tags, f"Tag already exists: {tag}; use a new RC version")
    # Full local suite includes Core Audio integration tests on the development Mac.
    run("swift", "test", "--package-path", str(PACKAGE))
    out = PACKAGE / ".release" / version
    require(not out.exists(), f"Output already exists: {out}; preserve it or choose a new RC")
    out.mkdir(parents=True)
    run(str(PACKAGE / "scripts/build_macos_app.sh"), "--configuration", "release",
        "--output", str(out / "build"), "--bundle-id", config["bundleIdentifier"])
    app = out / "build/AppMixer.app"
    info = app / "Contents/Info.plist"
    with info.open("rb") as handle:
        values = plistlib.load(handle)
    values.update(CFBundleShortVersionString=config["marketingVersion"],
                  CFBundleVersion=str(config["build"]), AppMixerReleaseVersion=version,
                  AppMixerSourceCommit=commit)
    with info.open("wb") as handle:
        plistlib.dump(values, handle)
    # Only static libraries are linked, so there is no nested executable code to sign.
    run("codesign", "--force", "--options", "runtime", "--timestamp", "--sign", identity, str(app))
    run("codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app))
    signature = subprocess.run(["codesign", "-d", "--verbose=4", str(app)],
                               check=True, text=True, capture_output=True).stderr
    require("Authority=Apple Development:" in signature and "runtime" in signature,
            "Expected a certificate signature with hardened runtime")
    architectures = run("lipo", "-archs", str(app / "Contents/MacOS/AppMixer"), capture=True).split()
    require(set(architectures) == {"arm64", "x86_64"}, "Release must be universal")
    archive = out / f"AppMixer-{version}-macOS.zip"
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive))
    staging = out / "dmg-staging"
    staging.mkdir()
    run("ditto", str(app), str(staging / "AppMixer.app"))
    (staging / "Applications").symlink_to("/Applications")
    dmg = out / f"AppMixer-{version}-macOS.dmg"
    run("hdiutil", "create", "-volname", "AppMixer", "-srcfolder", str(staging),
        "-format", "UDZO", str(dmg))
    run("codesign", "--sign", identity, "--timestamp", str(dmg))
    run("codesign", "--verify", "--strict", str(dmg))
    run("hdiutil", "verify", str(dmg))
    shutil.rmtree(staging)
    manifest = dict(config, sourceCommit=commit, sourceRepository=repo["nameWithOwner"],
                    tag=tag, architectures=architectures,
                    xcode=run("xcodebuild", "-version", capture=True),
                    signature=[line for line in signature.splitlines()
                               if line.startswith(("Authority=", "TeamIdentifier=", "Timestamp=", "CDHash="))])
    manifest_path = out / "release-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    artifacts = [archive, dmg, manifest_path]
    checksums = out / "SHA256SUMS"
    checksums.write_text("".join(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n" for p in artifacts))
    artifacts.append(checksums)
    if args.publish:
        require(not run("git", "status", "--porcelain", capture=True), "Sources changed while building")
        require(run("git", "rev-parse", "HEAD", capture=True) == commit, "HEAD changed while building")
        run("git", "tag", "-a", tag, "-m", f"AppMixer {version}")
        run("git", "push", "origin", tag)
        run("gh", "release", "create", tag, "--verify-tag", "--prerelease", "--title", f"AppMixer {version}",
            "--notes-file", str(notes), *map(str, artifacts))
    print(f"Signed internal RC: {out}")
    print("Apple Development signed; not notarized. Signing keys remain in the local Keychain.")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)

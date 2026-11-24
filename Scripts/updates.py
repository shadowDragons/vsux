#!/usr/bin/env python3
"""Configure Sparkle and prepare signed GitHub Release assets (never publishes)."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / ".build/artifacts/sparkle/Sparkle/bin"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def version_tuple(value):
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", value):
        raise ValueError("Version must be X.Y.Z without leading zeroes")
    return tuple(map(int, value.split(".")))


def repository(value):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", value):
        raise ValueError("Repository must be owner/name")
    return value


def configure(plist_path, public_key, repo):
    info = plistlib.loads(plist_path.read_bytes())
    # Absence of a key is an explicitly offline source build.
    if public_key:
        if len(base64.b64decode(public_key, validate=True)) != 32:
            raise ValueError("SPARKLE_PUBLIC_KEY must be a base64 Ed25519 public key")
        info.update({
            "SUFeedURL": f"https://github.com/{repository(repo)}/releases/latest/download/appcast.xml",
            "SUPublicEDKey": public_key,
            "SURequireSignedFeed": True,
            "SUVerifyUpdateBeforeExtraction": True,
            "SUEnableAutomaticChecks": False,
            "SUAllowsAutomaticUpdates": False,
            "SUAutomaticallyUpdate": False,
            "SUEnableSystemProfiling": False,
            "SUScheduledCheckInterval": 86400,
        })
    plist_path.write_bytes(plistlib.dumps(info))


def previous_release(releases, version):
    candidates = []
    for release in releases:
        tag = release["tagName"]
        if release["isDraft"] or release["isPrerelease"] or not tag.startswith("v"):
            continue
        try:
            parsed = version_tuple(tag[1:])
        except ValueError:
            continue
        if parsed < version_tuple(version):
            candidates.append((parsed, tag))
    return max(candidates)[1] if candidates else None


def gh_json(*args):
    return json.loads(subprocess.check_output(["gh", *args], text=True))


def fetch_baseline(version, destination, repo):
    repository(repo)
    releases = gh_json("release", "list", "--repo", repo, "--limit", "100",
                       "--json", "tagName,isDraft,isPrerelease")
    tag = previous_release(releases, version)
    if tag is None:
        print("No previous stable release; generating a full update only.")
        return
    name = f"vsux-{tag[1:]}-macos-arm64.zip"
    assets = gh_json("release", "view", tag, "--repo", repo, "--json", "assets")["assets"]
    names = {asset["name"] for asset in assets}
    if name not in names:
        print(f"{tag} predates update ZIPs; generating a full update only.")
        return
    if name + ".sha256" not in names:
        raise ValueError("Previous update ZIP has no checksum")
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temporary:
        subprocess.run(["gh", "release", "download", tag, "--repo", repo,
                        "--pattern", name, "--pattern", name + ".sha256",
                        "--dir", temporary], check=True)
        archive = Path(temporary) / name
        expected = (Path(temporary) / (name + ".sha256")).read_text().split()[0]
        if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
            raise ValueError("Previous update ZIP checksum does not match")
        shutil.copy2(archive, destination / name)
    print(f"Delta baseline: {tag}")


def validate_feed(feed, directory, version, build, prefix):
    items = ET.parse(feed).findall("./channel/item")
    if len(items) != 1 or items[0].findtext(SPARKLE + "version") != build:
        raise ValueError("Feed must contain exactly the current build")
    if items[0].findtext(SPARKLE + "shortVersionString") != version:
        raise ValueError("Feed marketing version does not match")
    full = items[0].find("enclosure")
    if full is None or full.get("url") != prefix + f"vsux-{version}-macos-arm64.zip":
        raise ValueError("Feed is missing the full update fallback")
    assets = []
    for enclosure in items[0].iter("enclosure"):
        url = enclosure.get("url", "")
        if not url.startswith(prefix):
            raise ValueError("Update asset must belong to this immutable release")
        name = url[len(prefix):]
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
            raise ValueError("Unsafe update asset filename")
        path = directory / name
        if not path.is_file() or str(path.stat().st_size) != enclosure.get("length"):
            raise ValueError("Update asset size does not match feed")
        signature = enclosure.get(SPARKLE + "edSignature", "")
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError("Update asset is missing its Ed25519 signature")
        assets.append((path, signature))
    return assets


def package(version, baseline, repo):
    version_tuple(version)
    repository(repo)
    app = ROOT / "dist/vsux.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info["CFBundleShortVersionString"] != version or not info.get("SUPublicEDKey"):
        raise ValueError("Build the matching version with SPARKLE_PUBLIC_KEY first")
    if info.get("SUFeedURL") != f"https://github.com/{repo}/releases/latest/download/appcast.xml":
        raise ValueError("Build and update package must use the same repository")
    output = ROOT / "dist" / f"updates-{version}"
    if output.exists():
        raise ValueError(f"Refusing to overwrite update assets: {output}")
    prefix = f"https://github.com/{repo}/releases/download/v{version}/"
    # Keep private keys out of command arguments and on-disk artifacts.
    secret = os.environ.get("SPARKLE_PRIVATE_KEY")
    signing_args = ["--ed-key-file", "-"] if secret else ["--account", "vsux"]
    def signed_run(tool, *args):
        subprocess.run([str(TOOLS / tool), *signing_args, *map(str, args)],
                       input=secret, text=True, check=True)

    with tempfile.TemporaryDirectory(prefix=".updates-", dir=ROOT / "dist") as temporary:
        stage = Path(temporary)
        if baseline:
            for archive in baseline.glob("vsux-*-macos-arm64.zip"):
                old_version = archive.name.removeprefix("vsux-").removesuffix("-macos-arm64.zip")
                if version_tuple(old_version) >= version_tuple(version):
                    raise ValueError("Delta baselines must be older than the target version")
                shutil.copy2(archive, stage / archive.name)
        archive = stage / f"vsux-{version}-macos-arm64.zip"
        subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)], check=True)
        signed_run("generate_appcast", "--versions", info["CFBundleVersion"],
                   "--maximum-versions", "1", "--maximum-deltas", "3",
                   "--download-url-prefix", prefix, stage)
        feed = stage / "appcast.xml"
        assets = validate_feed(feed, stage, version, info["CFBundleVersion"], prefix)
        # generate_appcast can warn rather than fail for a missing/mismatched key.
        # Require signatures and verify them before making any uploadable output.
        signed_run("sign_update", "--verify", feed)
        for path, signature in assets:
            signed_run("sign_update", "--verify", path, signature)
        output.mkdir()
        shutil.copy2(feed, output / feed.name)
        for path, _ in assets:
            shutil.copy2(path, output / path.name)
        for path in list(output.iterdir()):
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            (output / (path.name + ".sha256")).write_text(f"{digest}  {path.name}\n")
    print(f"Signed update assets: {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=os.environ.get("UPDATE_REPOSITORY", "shadowDragons/vsux"))
    commands = parser.add_subparsers(dest="command", required=True)
    configure_parser = commands.add_parser("configure")
    configure_parser.add_argument("plist", type=Path)
    baseline_parser = commands.add_parser("fetch-baseline")
    baseline_parser.add_argument("version")
    baseline_parser.add_argument("directory", type=Path)
    package_parser = commands.add_parser("package")
    package_parser.add_argument("version")
    package_parser.add_argument("--baseline", type=Path)
    args = parser.parse_args()
    if args.command == "configure":
        configure(args.plist, os.environ.get("SPARKLE_PUBLIC_KEY", ""), args.repo)
    elif args.command == "fetch-baseline":
        fetch_baseline(args.version, args.directory, args.repo)
    else:
        package(args.version, args.baseline, args.repo)


if __name__ == "__main__":
    main()

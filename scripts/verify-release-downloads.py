"""Check anonymous public installer/feed URLs against the exact local release bytes.

Use before marking a prerelease latest, then again with --latest after promotion.
Runtime downloads are covered by smoke-runtime-install's --download mode.
"""
import argparse
import hashlib
import pathlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

BASE = "https://github.com/daniellee-ux/Seminarly-AI/releases/"
ASSETS = ("Seminarly-AppleSilicon.dmg", "Seminarly-Intel.dmg", "Seminarly.dmg",
          "appcast-arm64.xml", "appcast-x86_64.xml")


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            result.update(block)
    return result.digest()


def verify(tag, artifacts, latest=False):
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise ValueError("Invalid release tag")
    prefix = BASE + ("latest/download/" if latest else f"download/{tag}/")
    with tempfile.TemporaryDirectory(prefix="seminarly-release-download-") as directory:
        root = pathlib.Path(directory)
        for name in ASSETS:
            destination = root / name
            # No GitHub token/cookie headers: this must work for a new app user.
            subprocess.run(["/usr/bin/curl", "-q", "--fail", "--location", "--silent", "--show-error",
                            "--proto", "=https", "--proto-redir", "=https", "--retry", "2",
                            "--connect-timeout", "20", "--max-time", "180", "--output", str(destination),
                            prefix + name], check=True)
            if digest(destination) != digest(artifacts / name):
                raise ValueError(f"Downloaded {name} differs from the signed local artifact")
            if name.endswith(".xml"):
                arch = "arm64" if name == "appcast-arm64.xml" else "x86_64"
                item = ET.parse(destination).find("./channel/item")
                if item is None:
                    raise ValueError("Empty update feed")
                enclosure = item.find("enclosure")
                expected_name = "Seminarly-AppleSilicon.dmg" if arch == "arm64" else "Seminarly-Intel.dmg"
                if enclosure is None or enclosure.get("url") != BASE + f"download/{tag}/{expected_name}":
                    raise ValueError("Update feed has a wrong release or architecture URL")
                if int(enclosure.attrib["length"]) != (artifacts / expected_name).stat().st_size:
                    raise ValueError("Update feed has a wrong installer length")
            print(f"PASS: {'latest' if latest else tag} / {name} — anonymous HTTPS download and exact SHA-256 match", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag")
    parser.add_argument("artifacts", type=pathlib.Path)
    parser.add_argument("--latest", action="store_true")
    args = parser.parse_args()
    verify(args.tag, args.artifacts, args.latest)

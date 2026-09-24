"""Collect pinned runtime assets without re-signing, changing pins, or publishing."""
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys
import urllib.parse


def stage(manifest_path, output, components):
    manifest = json.loads(manifest_path.read_text())
    for artifact in manifest["artifacts"]:
        url = urllib.parse.urlsplit(artifact["url"])
        if url.scheme != "https" or url.netloc != "github.com" or not url.path.startswith("/daniellee-ux/Seminarly-AI/releases/download/"):
            raise ValueError("Unexpected runtime host")
        name = pathlib.PurePosixPath(url.path).name
        destination = output / name
        source = components / name if components else None
        if source and source.is_file() and not source.is_symlink():
            shutil.copy2(source, destination)
        else:
            subprocess.run(["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error", "--retry", "2",
                            "--proto", "=https", "--proto-redir", "=https", "--max-time", "600",
                            "--output", str(destination), artifact["url"]], check=True)
        data = destination.read_bytes()
        if len(data) != artifact["archiveBytes"] or hashlib.sha256(data).hexdigest() != artifact["archiveSHA256"]:
            raise ValueError("Runtime asset does not match source-controlled pin")


if __name__ == "__main__":
    manifest, output, components = sys.argv[1:]
    stage(pathlib.Path(manifest), pathlib.Path(output), pathlib.Path(components) if components else None)

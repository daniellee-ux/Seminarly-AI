"""Generate public, pinned metadata for already signed/notarized component artifacts."""
import hashlib
import json
import pathlib
import sys


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else hashlib.sha256(stream.read()).hexdigest()


if __name__ == "__main__":
    root, version, revision, tag, team = sys.argv[1:]
    root = pathlib.Path(root)
    artifacts = []
    for arch in ("arm64", "x86_64"):
        archive = root / f"ChatGPTConnection-{version}-{revision}-{arch}.tar.xz"
        executable = root / arch / "ChatGPTConnection.app/Contents/MacOS/seminarly-chatgpt"
        artifacts.append(dict(architecture=arch, url=f"https://github.com/daniellee-ux/Seminarly-AI/releases/download/{tag}/{archive.name}",
                              archiveSHA256=digest(archive), archiveBytes=archive.stat().st_size,
                              executableSHA256=digest(executable), executableBytes=executable.stat().st_size))
    manifest = dict(schemaVersion=1, version=version, revision=int(revision), teamIdentifier=team, artifacts=artifacts)
    (root / "ChatGPTRuntime.json").write_text(json.dumps(manifest, indent=2) + "\n")

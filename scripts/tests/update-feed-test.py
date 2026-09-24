"""Offline release-pipeline checks; never read signing keys or call GitHub."""
import hashlib
import contextlib
import io
import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


scripts = pathlib.Path(__file__).resolve().parents[1]
feed_tool = module("feed", scripts / "publish-update-feed.py")
asset_tool = module("assets", scripts / "stage-runtime-assets.py")
download_tool = module("downloads", scripts / "verify-release-downloads.py")
SPARKLE = feed_tool.SPARKLE


class UpdateFeedTests(unittest.TestCase):
    def public_artifacts(self, root):
        for name in download_tool.ASSETS:
            if name.endswith(".dmg"):
                (root / name).write_bytes(b"signed fixture bytes")
            else:
                dmg = "Seminarly-AppleSilicon.dmg" if "arm64" in name else "Seminarly-Intel.dmg"
                (root / name).write_text(f'<rss><channel><item><enclosure url="{download_tool.BASE}download/v0.1.12/{dmg}" length="20"/></item></channel></rss>')

    def test_public_verifier_covers_versioned_and_latest_compatibility_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.public_artifacts(root)
            for latest in (False, True):
                requests = []

                def download(command, check):
                    self.assertTrue(check)
                    self.assertNotIn("--header", command)
                    url = command[-1]
                    requests.append(url)
                    destination = pathlib.Path(command[command.index("--output") + 1])
                    destination.write_bytes((root / url.rsplit("/", 1)[-1]).read_bytes())

                with mock.patch.object(download_tool.subprocess, "run", side_effect=download), contextlib.redirect_stdout(io.StringIO()):
                    download_tool.verify("v0.1.12", root, latest)
                prefix = download_tool.BASE + ("latest/download/" if latest else "download/v0.1.12/")
                self.assertEqual(requests, [prefix + name for name in download_tool.ASSETS])

    def test_public_verifier_rejects_wrong_download_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.public_artifacts(root)

            def wrong_download(command, check):
                pathlib.Path(command[command.index("--output") + 1]).write_bytes(b"wrong release")

            with mock.patch.object(download_tool.subprocess, "run", side_effect=wrong_download):
                with self.assertRaisesRegex(ValueError, "differs"):
                    download_tool.verify("v0.1.12", root)

    def test_public_verifier_rejects_invalid_release_before_network(self):
        with mock.patch.object(download_tool.subprocess, "run") as request:
            with self.assertRaises(ValueError):
                download_tool.verify("../v0.1.12", pathlib.Path("/nonexistent"))
            request.assert_not_called()

    def test_namespaces_architectures_and_preserves_prior_release_urls(self):
        for arch, dmg in (("arm64", "Seminarly-AppleSilicon.dmg"), ("x86_64", "Seminarly-Intel.dmg")):
            with tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                history = root / "history"
                history.mkdir()
                prefix = "https://github.com/daniellee-ux/Seminarly-AI/releases/download/v0.1.13/"
                old_prefix = prefix.replace("v0.1.13", "v0.1.12")
                (root / dmg).write_bytes(b"full")
                (history / "Seminarly14-13.delta").write_bytes(b"patch")
                source = history / "appcast.xml"
                source.write_text(f'''<rss xmlns:sparkle="{SPARKLE}"><channel><item><sparkle:shortVersionString>0.1.13</sparkle:shortVersionString>
                    <enclosure url="{prefix}Seminarly-0.1.13-14-{arch}.dmg" length="4" sparkle:edSignature="signed"/>
                    <sparkle:deltas><enclosure url="{prefix}Seminarly14-13.delta" length="5" sparkle:edSignature="signed" sparkle:deltaFrom="13"/></sparkle:deltas>
                    </item><item><sparkle:shortVersionString>0.1.12</sparkle:shortVersionString><enclosure url="{prefix}Seminarly-0.1.12-13-{arch}.dmg" length="99" sparkle:edSignature="signed"/></item></channel></rss>''')
                result = feed_tool.prepare(source, root, arch, prefix, dmg)
                items = ET.parse(result).findall(".//enclosure")
                self.assertEqual(items[0].get("url"), prefix + dmg)
                self.assertEqual(items[1].get("url"), prefix + arch + "-Seminarly14-13.delta")
                self.assertEqual(items[2].get("url"), old_prefix + dmg)
                self.assertEqual((root / (arch + "-Seminarly14-13.delta")).read_bytes(), b"patch")
                self.assertEqual((history / "Seminarly14-13.delta").read_bytes(), b"patch")

    def test_unsigned_feed_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "source.xml"
            source.write_text('<rss><channel><item><enclosure url="https://example.com/update.dmg" length="1"/></item></channel></rss>')
            with self.assertRaises(ValueError):
                feed_tool.prepare(source, root, "arm64", "https://example.com/", "app.dmg")

    def test_runtime_pins_are_checked_before_distribution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            component = root / "component"
            component.mkdir()
            output = root / "output"
            output.mkdir()
            archive = component / "runtime.tar.xz"
            archive.write_bytes(b"fixture")
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"artifacts": [{"url": "https://github.com/daniellee-ux/Seminarly-AI/releases/download/v0.1.12/runtime.tar.xz",
                "archiveBytes": 7, "archiveSHA256": hashlib.sha256(b"fixture").hexdigest()}]}))
            asset_tool.stage(manifest, output, component)
            self.assertEqual((output / archive.name).read_bytes(), b"fixture")
            archive.write_bytes(b"corrupt")
            with self.assertRaises(ValueError):
                asset_tool.stage(manifest, output, component)


if __name__ == "__main__":
    unittest.main()

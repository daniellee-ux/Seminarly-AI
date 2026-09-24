"""Verify signed enclosures for this release before the feed can be published."""
import pathlib
import subprocess
import sys
import urllib.parse
import xml.etree.ElementTree as ET

if __name__ == "__main__":
    feed, output, prefix, tools, account = sys.argv[1:]
    for item in ET.parse(feed).findall(".//enclosure"):
        url = item.attrib["url"]
        if not url.startswith(prefix):
            continue
        path = pathlib.Path(output) / pathlib.PurePosixPath(urllib.parse.urlsplit(url).path).name
        if path.stat().st_size != int(item.attrib["length"]):
            raise ValueError("Update archive length mismatch")
        signature = item.attrib["{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"]
        subprocess.run([str(pathlib.Path(tools) / "sign_update"), "--account", account, "--verify", str(path), signature], check=True)

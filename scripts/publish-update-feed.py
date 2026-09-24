"""Map generated Sparkle history to immutable GitHub release assets. Re-sign after use."""
import pathlib
import re
import shutil
import sys
import urllib.parse
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def prepare(feed, output, arch, prefix, dmg_name):
    tree = ET.parse(feed)
    for item in tree.findall("./channel/item"):
        version = item.findtext(f"{{{SPARKLE}}}shortVersionString")
        if not version or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
            raise ValueError("Missing or invalid release version")
        # generate_appcast rewrites old enclosure URLs using the new prefix too.
        # Restore each item's immutable release path from its actual app version.
        release_prefix = f"https://github.com/daniellee-ux/Seminarly-AI/releases/download/v{version}/"
        for enclosure in item.findall(".//enclosure"):
            prepare_enclosure(enclosure, feed, output, arch, prefix, release_prefix, dmg_name)
    destination = output / f"appcast-{arch}.xml"
    tree.write(destination, encoding="utf-8", xml_declaration=True)
    return destination


def prepare_enclosure(enclosure, feed, output, arch, prefix, release_prefix, dmg_name):
    url = urllib.parse.urlsplit(enclosure.attrib["url"])
    name = pathlib.PurePosixPath(url.path).name
    if not enclosure.get(f"{{{SPARKLE}}}edSignature"):
        raise ValueError("Unsigned update enclosure")
    is_current = release_prefix == prefix
    if name.endswith(".delta"):
        public_name = name if name.startswith(arch + "-") else arch + "-" + name
        if is_current:
            shutil.copy2(feed.parent / name, output / public_name)
    elif name.endswith(".dmg"):
        public_name = dmg_name
        # Must be byte-for-byte the archive whose signature appears in this feed.
        if is_current and (output / dmg_name).stat().st_size != int(enclosure.attrib["length"]):
            raise ValueError("Full update does not match feed length")
    else:
        raise ValueError("Unexpected update archive type")
    enclosure.set("url", release_prefix + public_name)


if __name__ == "__main__":
    feed, output, arch, prefix, dmg_name = sys.argv[1:]
    prepare(pathlib.Path(feed), pathlib.Path(output), arch, prefix, dmg_name)

#!/usr/bin/env python3
"""Give ImageMagick the standard macOS system fonts.

Usage: imagemagick-fonts.py IMAGEMAGICK_PREFIX

ImageMagick knows fonts only from its type.xml, which an installation on
macOS leaves empty: without fonts, drawing text (Imagick's annotateImage,
ImagickDraw) fails unless the caller names a font file. These fonts are
part of macOS 15 and later, in its read-only system folders, so the map
holds on every supported Mac. Writes type-macos.xml and includes it from
type.xml.
"""
import pathlib
import re
import sys
from xml.sax.saxutils import quoteattr

SYSTEM = "/System/Library/Fonts"
SUPPLEMENTAL = SYSTEM + "/Supplemental"

# name, family, style, weight, file
FONTS = [
    ("Helvetica", "Helvetica", "Normal", 400, f"{SYSTEM}/Helvetica.ttc"),
    ("Helvetica-Neue", "Helvetica Neue", "Normal", 400, f"{SYSTEM}/HelveticaNeue.ttc"),
    ("Courier", "Courier", "Normal", 400, f"{SYSTEM}/Courier.ttc"),
    ("Times-Roman", "Times", "Normal", 400, f"{SYSTEM}/Times.ttc"),
    ("Menlo", "Menlo", "Normal", 400, f"{SYSTEM}/Menlo.ttc"),
    ("Monaco", "Monaco", "Normal", 400, f"{SYSTEM}/Monaco.ttf"),
    ("Symbol", "Symbol", "Normal", 400, f"{SYSTEM}/Symbol.ttf"),
    ("Arial", "Arial", "Normal", 400, f"{SUPPLEMENTAL}/Arial.ttf"),
    ("Arial-Bold", "Arial", "Normal", 700, f"{SUPPLEMENTAL}/Arial Bold.ttf"),
    ("Arial-Italic", "Arial", "Italic", 400, f"{SUPPLEMENTAL}/Arial Italic.ttf"),
    ("Courier-New", "Courier New", "Normal", 400, f"{SUPPLEMENTAL}/Courier New.ttf"),
    ("Georgia", "Georgia", "Normal", 400, f"{SUPPLEMENTAL}/Georgia.ttf"),
    ("Tahoma", "Tahoma", "Normal", 400, f"{SUPPLEMENTAL}/Tahoma.ttf"),
    ("Times-New-Roman", "Times New Roman", "Normal", 400, f"{SUPPLEMENTAL}/Times New Roman.ttf"),
    ("Trebuchet-MS", "Trebuchet MS", "Normal", 400, f"{SUPPLEMENTAL}/Trebuchet MS.ttf"),
    ("Verdana", "Verdana", "Normal", 400, f"{SUPPLEMENTAL}/Verdana.ttf"),
]


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__.strip())
    configuration = pathlib.Path(sys.argv[1]) / "etc/ImageMagick-7"
    type_map = configuration / "type.xml"
    if not type_map.is_file():
        raise SystemExit(f"Not an ImageMagick installation: {type_map} is missing")
    missing = [path for *_, path in FONTS if not pathlib.Path(path).is_file()]
    if missing:
        raise SystemExit("System fonts missing on the build machine:\n" + "\n".join(missing))

    entries = []
    for name, family, style, weight, path in FONTS:
        fullname = name.replace("-", " ")
        entries.append(
            f"  <type name={quoteattr(name)} fullname={quoteattr(fullname)} family={quoteattr(family)}"
            f" style={quoteattr(style)} stretch=\"Normal\" weight=\"{weight}\" glyphs={quoteattr(path)}/>"
        )
    (configuration / "type-macos.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        "<!-- Standard macOS system fonts; written by DevStack's imagemagick-fonts.py. -->\n"
        "<typemap>\n" + "\n".join(entries) + "\n</typemap>\n",
        encoding="utf-8",
    )
    contents = type_map.read_text(encoding="utf-8")
    include = '  <include file="type-macos.xml"/>\n'
    if include not in contents:
        # An installation's type.xml is an empty typemap.
        contents, count = re.subn(r"<typemap>\s*</typemap>", "<typemap>\n" + include + "</typemap>", contents)
        if count != 1:
            raise SystemExit(f"Unexpected {type_map}; review how fonts are included.")
        type_map.write_text(contents, encoding="utf-8")
    print(f"ImageMagick fonts: {len(FONTS)} macOS system fonts in {configuration / 'type-macos.xml'}")


if __name__ == "__main__":
    main()

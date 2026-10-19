#!/usr/bin/env python3
"""Write one tiny document per format to tests/fixtures/formats/ (issue 4)."""
import io
import os
import struct
import sys
import zipfile
import zlib

out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "..", "tests", "fixtures", "formats")
os.makedirs(out, exist_ok=True)


def png(w=4, h=4):
    raw = b"".join(b"\x00" + b"\xff\x00\x00" * w for _ in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


def zipbytes(files, stored_first=None):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        if stored_first:
            z.writestr(zipfile.ZipInfo(stored_first[0]), stored_first[1], compress_type=zipfile.ZIP_STORED)
        for name, data in files:
            z.writestr(name, data, compress_type=zipfile.ZIP_DEFLATED)
    return buf.getvalue()


files = {
    "sample.png": png(),
    "sample.svg": b'<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50"><text x="5" y="30">Hello SVG</text></svg>',
    "sample.cbz": zipbytes([("page1.png", png())]),
    "sample.xps": zipbytes([
        ("[Content_Types].xml", b'<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="fdseq" ContentType="application/vnd.ms-package.xps-fixeddocumentsequence+xml"/><Default Extension="fdoc" ContentType="application/vnd.ms-package.xps-fixeddocument+xml"/><Default Extension="fpage" ContentType="application/vnd.ms-package.xps-fixedpage+xml"/><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/></Types>'),
        ("_rels/.rels", b'<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Type="http://schemas.microsoft.com/xps/2005/06/fixedrepresentation" Target="/doc.fdseq" Id="R0"/></Relationships>'),
        ("doc.fdseq", b'<FixedDocumentSequence xmlns="http://schemas.microsoft.com/xps/2005/06"><DocumentReference Source="/doc.fdoc"/></FixedDocumentSequence>'),
        ("doc.fdoc", b'<FixedDocument xmlns="http://schemas.microsoft.com/xps/2005/06"><PageContent Source="/p1.fpage"/></FixedDocument>'),
        ("p1.fpage", b'<FixedPage xmlns="http://schemas.microsoft.com/xps/2005/06" Width="200" Height="100" xml:lang="en"><Path Data="M 10,10 L 190,10 190,90 10,90 Z" Fill="#FF0000"/></FixedPage>'),
    ]),
    "sample.epub": zipbytes([
        ("META-INF/container.xml", b'<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'),
        ("content.opf", b'<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0"><metadata/><manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c1"/></spine></package>'),
        ("c1.xhtml", b'<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Hello EPUB</p></body></html>'),
    ], stored_first=("mimetype", b"application/epub+zip")),
    "sample.html": b"<html><body><p>Hello HTML</p></body></html>",
    "sample.txt": b"Hello plain text\n",
    "sample.fb2": b'<?xml version="1.0"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><body><section><p>Hello FB2</p></section></body></FictionBook>',
    "sample.docx": zipbytes([("[Content_Types].xml", b'<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>'), ("word/document.xml", b'<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Hello</w:t></w:r></w:p></w:body></w:document>')]),
}
for name, data in files.items():
    with open(os.path.join(out, name), "wb") as f:
        f.write(data)
    print(f"wrote formats/{name} ({len(data)} bytes)")

#!/usr/bin/env python3
"""Generate malformed PDF fixtures used by the issue-1 regression tests.

Each fixture has a *valid* xref table (offsets are computed), so MuPDF parses
the broken structure as written instead of falling back to repair mode. That
is what makes MuPDF throw from calls such as fz_count_pages / fz_bound_page.

Usage: python3 scripts/repro/make_malformed_fixtures.py [outdir]
"""
import os
import sys

CONTENT = b"BT /F1 12 Tf 72 720 Td (Hello malformed) Tj ET"


def build(objs, trailer_extra=b"", root=1):
    """objs: list of bytes bodies, object N is objs[N-1]."""
    out = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for i, body in enumerate(objs, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % i + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n" % (len(objs) + 1)
    out += b"0000000000 65535 f \n"
    for off in offsets:
        out += b"%010d 00000 n \n" % off
    out += b"trailer\n<< /Size %d /Root %d 0 R " % (len(objs) + 1, root) + trailer_extra + b">>\n"
    out += b"startxref\n%d\n%%%%EOF\n" % xref
    return bytes(out)


def stream(data, extra=b""):
    return b"<< /Length %d " % len(data) + extra + b">>\nstream\n" + data + b"\nendstream"


FONT = b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"


def fixtures():
    fx = {}

    # /Count -1 -> pdf_count_pages: "Invalid number of pages" (fz_count_pages throws)
    fx["malformed_negative_count.pdf"] = build([
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count -1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        stream(CONTENT),
        FONT,
    ])

    # /Count larger than the number of objects -> "Invalid number of pages"
    fx["malformed_huge_count.pdf"] = build([
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 2147483647 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        stream(CONTENT),
        FONT,
    ])

    # Page has no MediaBox and its /Parent chain is a cycle (6 -> 7 -> 6).
    # pdf_dict_get_inheritable(MediaBox) throws "cycle in resources" from
    # fz_bound_page (and from anything else that walks inherited attributes).
    fx["malformed_parent_cycle.pdf"] = build([
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 6 0 R /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        stream(CONTENT),
        FONT,
        b"<< /Type /Pages /Parent 7 0 R >>",
        b"<< /Type /Pages /Parent 6 0 R >>",
    ])

    # Info dictionary is an indirect ref to a stream / garbage instead of a dict,
    # and Root/Pages is missing entirely (page tree broken).
    fx["malformed_broken_info.pdf"] = build([
        b"<< /Type /Catalog /Pages 9 0 R >>",
        stream(b"\x00\x01garbage", b"/Filter /FlateDecode "),
        b"<< /Title 4 0 R /Author (x) /Parent 3 0 R >>",
        b"(unterminated",
    ], trailer_extra=b"/Info 3 0 R ")

    # Truncated real document (cut in the middle of the object stream / xref).
    src = os.path.join(os.path.dirname(__file__), "..", "..", "tests", "fixtures", "text_sample.pdf")
    with open(src, "rb") as f:
        data = f.read()
    fx["malformed_truncated.pdf"] = data[: len(data) // 2]

    # Corrupted xref: offsets point into the middle of other objects.
    good = build([
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        stream(CONTENT),
        FONT,
    ])
    bad = bytearray(good)
    xref_at = bad.rindex(b"xref\n")
    entries = bad[xref_at:].split(b"\n")
    for idx in range(3, len(entries)):
        if entries[idx].endswith(b" n "):
            entries[idx] = b"%010d 00000 n " % (7 + idx * 13)
    fx["malformed_bad_xref.pdf"] = bytes(bad[:xref_at] + b"\n".join(entries))
    return fx


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(__file__), "..", "..", "tests", "fixtures")
    os.makedirs(outdir, exist_ok=True)
    for name, data in fixtures().items():
        with open(os.path.join(outdir, name), "wb") as f:
            f.write(data)
        print(f"wrote {name} ({len(data)} bytes)")


if __name__ == "__main__":
    main()

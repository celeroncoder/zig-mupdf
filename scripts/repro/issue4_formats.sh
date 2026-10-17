#!/usr/bin/env bash
# Issue 4 repro: documented format support must match what the build can open.
#
# 1) Open one tiny sample per format with zig-out/bin/pdf-info.
# 2) README.md must have a "Supported formats" table row per format whose
#    yes/no marker matches (1).
# 3) No doc comment / README text may claim a compiled-out format
#    (e.g. "PDF/XPS/EPUB", "XPS, EPUB, HTML").
set -u
cd "$(dirname "$0")/../.."
python3 scripts/repro/make_format_fixtures.py >/dev/null
FAIL=0
declare -A NAME=([pdf]=PDF [xps]=XPS [svg]=SVG [cbz]=CBZ [png]=Images [epub]=EPUB [html]=HTML [txt]=TXT [fb2]=FB2 [docx]=Office)
for ext in pdf xps svg cbz png epub html txt fb2 docx; do
    f=tests/fixtures/formats/sample.$ext; [ $ext = pdf ] && f=tests/fixtures/text_sample.pdf
    if ./zig-out/bin/pdf-info "$f" 2>&1 | grep -q '^Pages:'; then actual=yes; else actual=no; fi
    row=$(grep -E "^\| *${NAME[$ext]}\b" README.md | head -1)
    if [ -z "$row" ]; then doc=missing
    elif grep -q '✅' <<<"$row"; then doc=yes
    elif grep -q '❌' <<<"$row"; then doc=no
    else doc=unclear; fi
    status=ok; [ "$actual" != "$doc" ] && { status=MISMATCH; FAIL=1; }
    printf '%-7s opens=%-3s README=%-8s %s\n' "${NAME[$ext]}" "$actual" "$doc" "$status"
done
echo "-- overclaiming phrases in docs --"
if grep -nE 'PDF/XPS/EPUB|XPS, EPUB|EPUB, HTML|\(XPS, EPUB' README.md src/*.zig examples/*.zig; then FAIL=1; else echo "(none)"; fi
echo "RESULT: $([ $FAIL -eq 0 ] && echo PASS || echo FAIL)"
exit $FAIL

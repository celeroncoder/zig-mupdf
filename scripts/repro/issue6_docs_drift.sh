#!/usr/bin/env bash
# Issue 6 check: docs must match reality.
#  - PROGRESS.md must not list Phase 4-7 as Next/Planned (they are implemented)
#  - every "N tests" figure in README.md / PROGRESS.md must equal the real count
#  - build.zig.zon minimum_zig_version must be 0.15.x (code uses 0.15 std APIs)
#  - README must document the new APIs and server flags
set -u
cd "$(dirname "$0")/../.."
FAIL=0
actual=$(zig build test --summary all 2>&1 | sed -n 's/.*; \([0-9]*\)\/\([0-9]*\) tests passed.*/\2/p' | head -1)
echo "actual test count: ${actual:-?}"

for n in 4 5 6 7; do
    line=$(grep -E "^\| Phase $n:" PROGRESS.md)
    if grep -qE 'Next|Planned' <<<"$line"; then echo "STALE  PROGRESS.md: $line"; FAIL=1; else echo "ok     Phase $n: $(cut -d'|' -f3 <<<"$line" | xargs)"; fi
done

while read -r hit; do
    n=$(grep -oE '[0-9]+' <<<"$(grep -oE '[0-9]+ tests|tests passing: \**[0-9]+' <<<"$hit")" | head -1)
    if [ "$n" != "$actual" ]; then echo "STALE  test count $n: $hit"; FAIL=1; else echo "ok     test count $n: ${hit:0:70}"; fi
done < <(grep -nHE '[0-9]+ tests|tests passing: \**[0-9]+' README.md PROGRESS.md)

zon=$(grep -oE 'minimum_zig_version = "[^"]+"' build.zig.zon)
if grep -q '"0\.15\.' <<<"$zon"; then echo "ok     $zon"; else echo "STALE  build.zig.zon $zon (code needs 0.15)"; FAIL=1; fi

for term in initThreadSafe --workers --read-timeout-ms --write-timeout-ms --max-header-bytes --shared-store sanitize-mupdf "zig build fuzz" "bench-engine" AGPL; do
    if grep -q -- "$term" README.md; then echo "ok     README documents $term"; else echo "MISSING README: $term"; FAIL=1; fi
done
echo "RESULT: $([ $FAIL -eq 0 ] && echo PASS || echo FAIL)"
exit $FAIL

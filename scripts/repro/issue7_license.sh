#!/usr/bin/env bash
# Issue 7 check: README must say clearly that running the HTTP server (or any
# network service linking MuPDF) is covered by AGPL-3.0 (section 13: offer the
# complete source to network users) unless an Artifex commercial licence is held.
set -u
cd "$(dirname "$0")/../.."
lic=$(sed -n '/^## License/,$p' README.md)
FAIL=0
check() { if grep -qiE "$2" <<<"$lic"; then echo "ok      $1"; else echo "MISSING $1"; FAIL=1; fi; }
check "AGPL-3.0 named"                         "AGPL-3\.0"
check "hosted/network service is covered"     "network|hosted"
check "applies to the bundled HTTP server"    "mupdf-server|HTTP server"
check "source must be offered to users (s.13)" "section 13|§ ?13|corresponding source|complete source"
check "commercial licence alternative"         "commercial licen[cs]e"
check "MIT applies only to the wrapper"        "MIT"
echo "RESULT: $([ $FAIL -eq 0 ] && echo PASS || echo FAIL)"
exit $FAIL

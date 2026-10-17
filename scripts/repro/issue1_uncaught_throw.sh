#!/usr/bin/env bash
# Issue 1 repro: MuPDF calls that throw outside fz_try abort the whole process
# ("aborting process from uncaught error!", exit(1)).
#
# Usage: scripts/repro/issue1_uncaught_throw.sh [port]
# Requires: zig-out/bin/pdf-info and zig-out/bin/mupdf-server (zig build).
# Exit status: 0 if no process died, 1 otherwise.
set -u
cd "$(dirname "$0")/../.."
PORT="${1:-8080}"
FAIL=0

python3 scripts/repro/make_malformed_fixtures.py >/dev/null

echo "== library (pdf-info example) on crafted fixtures =="
for f in tests/fixtures/malformed_*.pdf; do
    out=$(timeout 30 ./zig-out/bin/pdf-info "$f" 2>&1); rc=$?
    died=$(grep -c "aborting process from uncaught error" <<<"$out")
    printf '%-45s exit=%-3s uncaught_abort=%s\n' "$f" "$rc" "$died"
    [ "$died" -ne 0 ] && FAIL=1
done

echo "== server: POST crafted fixtures, then GET /health =="
./zig-out/bin/mupdf-server "$PORT" >/tmp/issue1_server.log 2>&1 &
SPID=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/health" && break; sleep 0.1; done
for f in malformed_negative_count malformed_huge_count malformed_parent_cycle; do
    for ep in info text render; do
        code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 -F "file=@tests/fixtures/$f.pdf" "http://127.0.0.1:$PORT/$ep")
        alive=$(kill -0 $SPID 2>/dev/null && echo yes || echo NO)
        printf '%-28s /%-7s http=%s server_alive=%s\n' "$f" "$ep" "$code" "$alive"
        if [ "$alive" = NO ]; then
            FAIL=1
            wait $SPID; echo "  server exit status: $?"
            tail -1 /tmp/issue1_server.log | sed 's/^/  server log: /'
            ./zig-out/bin/mupdf-server "$PORT" >/tmp/issue1_server.log 2>&1 &
            SPID=$!
            for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/health" && break; sleep 0.1; done
        fi
    done
done
kill $SPID 2>/dev/null; wait $SPID 2>/dev/null

echo "RESULT: $([ $FAIL -eq 0 ] && echo PASS || echo FAIL)"
exit $FAIL

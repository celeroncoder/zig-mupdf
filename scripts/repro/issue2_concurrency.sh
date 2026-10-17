#!/usr/bin/env bash
# Issue 2 repro: does the server process requests concurrently?
#
# 1) 16 x POST /render (page=1..16, scale=2) serially vs all 16 in parallel (curl & + wait).
#    A single-threaded server gives parallel ~= serial wall time.
# 2) Closed-loop load at concurrency 1/2/4/8 (benchmarks/loadgen.py): req/s, p50, p95.
#
# Usage: scripts/repro/issue2_concurrency.sh [port] [extra server args...]
# Build first with: zig build -Doptimize=ReleaseFast
# Needs a Python with httpx (PY=/tmp/venv/bin/python by default).
set -u
cd "$(dirname "$0")/../.."
PORT="${1:-8080}"; shift || true
PY="${PY:-/tmp/venv/bin/python}"
PDF=examples/example.pdf
URL="http://127.0.0.1:$PORT"

./zig-out/bin/mupdf-server "$PORT" "$@" >/tmp/issue2_server.log 2>&1 &
SPID=$!
trap 'kill $SPID 2>/dev/null; wait $SPID 2>/dev/null' EXIT
for _ in $(seq 100); do curl -s -o /dev/null "$URL/health" && break; sleep 0.1; done
echo "cpus: $(nproc)  server args: $PORT $*"
head -3 /tmp/issue2_server.log | sed -n '/workers/p'

one() { curl -s -o /dev/null -w '%{http_code}\n' -H 'Expect:' -F "file=@$PDF" -F "page=$1" -F scale=2 "$URL/render"; }
for p in 1 2 3; do one $p >/dev/null; done   # warm-up

t0=$(date +%s.%N)
for p in $(seq 1 16); do one $p; done > /tmp/issue2_serial.codes
t1=$(date +%s.%N)
: > /tmp/issue2_par.codes
pids=()
for p in $(seq 1 16); do one $p >> /tmp/issue2_par.codes & pids+=($!); done
wait "${pids[@]}"
t2=$(date +%s.%N)
awk -v t0="$t0" -v t1="$t1" -v t2="$t2" -v so="$(grep -c 200 /tmp/issue2_serial.codes)" -v po="$(grep -c 200 /tmp/issue2_par.codes)" \
    'BEGIN { s = t1 - t0; p = t2 - t1; printf "16x /render scale=2  serial: %.2fs (%d ok)   parallel: %.2fs (%d ok)   speedup: %.2fx\n", s, so, p, po, s / p }'

echo "-- closed-loop load (benchmarks/loadgen.py) --"
"$PY" benchmarks/loadgen.py "$URL" /render -c 1,2,4,8 -n 32 -f page=0 -f scale=2
"$PY" benchmarks/loadgen.py "$URL" /text -c 1,2,4,8 -n 64 -f page=0 | tail -4

#!/usr/bin/env bash
# Issue 1 fuzz check: run the in-process mutation fuzz loop for several seeds.
# An escaped MuPDF exception calls exit(1), which ends the loop early.
#
# Usage: scripts/repro/issue1_fuzz.sh [iterations] [seeds] [corpus_dir]
# Requires zig-out/bin/mupdf-fuzz (zig build).
set -u
cd "$(dirname "$0")/../.."
ITERS="${1:-3000}"; SEEDS="${2:-20}"; CORPUS="${3:-tests/fixtures}"
crashes=0; total=0
for seed in $(seq 1 "$SEEDS"); do
    log=$(mktemp)
    ./zig-out/bin/mupdf-fuzz "$ITERS" "$seed" "$CORPUS" 2>"$log"; rc=$?
    last=$(grep '^iter ' "$log" | tail -1 | cut -d' ' -f2)
    done_iters=$(( ${last:-0} + 1 ))
    if [ $rc -ne 0 ]; then
        crashes=$((crashes+1))
        mkdir -p zig-out/fuzz-crashes; cp zig-out/fuzz-current.pdf "zig-out/fuzz-crashes/seed${seed}_iter${last}.pdf"
        printf 'seed=%-3s exit=%s died_at_iter=%-5s %s\n' "$seed" "$rc" "$last" "$(grep FATAL "$log" | head -1)"
    else
        printf 'seed=%-3s exit=0 %s\n' "$seed" "$(tail -1 "$log")"
    fi
    total=$((total + done_iters))
    rm -f "$log"
done
echo "TOTAL: seeds=$SEEDS iterations_executed=$total process_aborts=$crashes"
[ $crashes -eq 0 ]

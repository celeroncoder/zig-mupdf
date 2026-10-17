#!/usr/bin/env bash
# Issue 5 check: does the benchmark suite measure concurrency and engine cost?
# Requires: throughput + p50/p95/p99 at concurrency 1/2/4/8 for /text and
# /render for both servers (PyMuPDF with multi-worker uvicorn), and an
# in-process engine comparison (open, text, render+PNG) for both libraries.
set -u
cd "$(dirname "$0")/../.."
FAIL=0
check() { if eval "$2" >/dev/null 2>&1; then echo "ok    $1"; else echo "MISSING $1"; FAIL=1; fi; }
check "concurrency benchmark script"            "test -f benchmarks/concurrency_benchmark.py"
check "  measures req/s and p50/p95/p99"        "grep -q p99 benchmarks/concurrency_benchmark.py && grep -q rps benchmarks/concurrency_benchmark.py"
check "  concurrency levels 1,2,4,8"            "grep -q '1, 2, 4, 8' benchmarks/concurrency_benchmark.py"
check "  /text and /render"                     "grep -q '/text' benchmarks/concurrency_benchmark.py && grep -q '/render' benchmarks/concurrency_benchmark.py"
check "  uvicorn --workers N (N = CPU count)"   "grep -q -- '--workers' benchmarks/concurrency_benchmark.py && grep -q cpu_count benchmarks/concurrency_benchmark.py"
check "in-process engine benchmark (Zig)"       "test -f benchmarks/engine_bench.zig"
check "in-process engine benchmark (PyMuPDF)"   "test -f benchmarks/engine_benchmark.py && grep -q get_pixmap benchmarks/engine_benchmark.py"
check "report has machine specs + concurrency"  "grep -qi 'concurrency' benchmarks/BENCHMARK_REPORT.md && grep -qi 'cpu' benchmarks/BENCHMARK_REPORT.md"
echo "RESULT: $([ $FAIL -eq 0 ] && echo PASS || echo FAIL)"
exit $FAIL

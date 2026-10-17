#!/usr/bin/env python3
"""Concurrency benchmark: zig-mupdf server vs PyMuPDF (FastAPI + uvicorn --workers N).

Starts both servers with N workers (N = CPU count by default), then for each
endpoint and each concurrency level in 1, 2, 4, 8 runs a closed-loop load
(benchmarks/loadgen.py) and reports throughput (req/s) and p50/p95/p99 latency.

Usage:
    zig build -Doptimize=ReleaseFast
    python3 benchmarks/concurrency_benchmark.py [-n 48] [--workers N] [--json out.json]
"""
import argparse
import json
import os
import subprocess
import sys
import time

import httpx

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from loadgen import run_load, warmup  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
LEVELS = [1, 2, 4, 8]
CASES = [
    ("/text", {"page": "0"}, 4),        # (endpoint, fields, request multiplier)
    ("/render", {"page": "0", "scale": "2"}, 1),
]


def wait_ready(url, proc, timeout=30):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if proc.poll() is not None:
            raise RuntimeError(f"server exited early ({proc.returncode})")
        try:
            if httpx.get(url + "/health", timeout=1).status_code == 200:
                return
        except Exception:  # noqa: BLE001
            time.sleep(0.2)
    raise RuntimeError("server did not become ready")


def start_servers(workers, zig_port, py_port):
    zig = subprocess.Popen([os.path.join(ROOT, "zig-out", "bin", "mupdf-server"), str(zig_port), "--workers", str(workers)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    py = subprocess.Popen([sys.executable, "-m", "uvicorn", "python_server:app", "--host", "127.0.0.1", "--port", str(py_port),
                           "--workers", str(workers), "--log-level", "warning"],
                          cwd=os.path.join(ROOT, "benchmarks"), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return zig, py


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", "--requests", type=int, default=48, help="requests per /render level (x4 for /text)")
    ap.add_argument("--workers", type=int, default=os.cpu_count())
    ap.add_argument("--pdf", default=os.path.join(ROOT, "examples", "example.pdf"))
    ap.add_argument("--zig-port", type=int, default=8080)
    ap.add_argument("--py-port", type=int, default=8081)
    ap.add_argument("--json")
    args = ap.parse_args()
    pdf = open(args.pdf, "rb").read()

    zig, py = start_servers(args.workers, args.zig_port, args.py_port)
    servers = [("zig", f"http://127.0.0.1:{args.zig_port}", zig), ("pymupdf", f"http://127.0.0.1:{args.py_port}", py)]
    results = []
    try:
        for _, url, proc in servers:
            wait_ready(url, proc)
        print(f"workers per server: {args.workers} (cpu_count={os.cpu_count()}), pdf={os.path.basename(args.pdf)}")
        print(f"{'endpoint':<9} {'conc':>4} {'server':<8} {'req/s':>8} {'p50 ms':>8} {'p95 ms':>8} {'p99 ms':>8} {'err':>4}")
        for endpoint, fields, mult in CASES:
            for name, url, _ in servers:
                warmup(url, endpoint, pdf, fields, n=8)
            for c in LEVELS:
                for name, url, _ in servers:
                    r = run_load(url, endpoint, pdf, fields, c, args.requests * mult)
                    r["server"] = name
                    results.append(r)
                    print(f"{endpoint:<9} {c:>4} {name:<8} {r['rps']:>8.2f} {r['p50_ms']:>8.1f} {r['p95_ms']:>8.1f} {r['p99_ms']:>8.1f} {r['errors']:>4}")
    finally:
        for _, _, proc in servers:
            proc.terminate()
            proc.wait(timeout=10)
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"workers": args.workers, "results": results}, f, indent=2)


if __name__ == "__main__":
    main()

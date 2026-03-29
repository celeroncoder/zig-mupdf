#!/usr/bin/env python3
"""
Benchmark: zig-mupdf vs PyMuPDF server comparison.

Usage:
    # Terminal 1: Start zig server
    zig build run-server

    # Terminal 2: Start python server
    cd benchmarks && pip install -r requirements.txt
    uvicorn python_server:app --host 0.0.0.0 --port 8081

    # Terminal 3: Run benchmark
    python3 benchmarks/benchmark.py
"""

import time
import json
import sys
import os
import statistics
import subprocess

# Use httpx for sync HTTP
try:
    import httpx
except ImportError:
    print("Installing httpx...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "httpx", "-q"])
    import httpx

# Configuration
ZIG_URL = "http://localhost:8080"
PY_URL = "http://localhost:8081"
PDF_PATH = os.path.join(os.path.dirname(os.path.dirname(__file__)), "examples", "example.pdf")
ITERATIONS = 20  # per test
WARMUP = 3


def check_server(name: str, url: str) -> bool:
    try:
        r = httpx.get(f"{url}/health", timeout=2)
        return r.status_code == 200
    except Exception:
        print(f"  [SKIP] {name} server not running at {url}")
        return False


def benchmark_endpoint(
    client: httpx.Client,
    url: str,
    endpoint: str,
    pdf_data: bytes,
    extra_fields=None,
    iterations: int = ITERATIONS,
) -> dict:
    """Benchmark a single endpoint, return timing stats."""
    times = []
    response_size = 0
    status_ok = True

    for i in range(WARMUP + iterations):
        files = {"file": ("test.pdf", pdf_data, "application/pdf")}
        data = extra_fields or {}

        start = time.perf_counter()
        try:
            r = client.post(f"{url}{endpoint}", files=files, data=data, timeout=60)
        except Exception as e:
            if i >= WARMUP:
                times.append(float("inf"))
            continue
        elapsed = time.perf_counter() - start

        if i >= WARMUP:
            times.append(elapsed * 1000)  # ms
            response_size = len(r.content)
            if r.status_code != 200:
                status_ok = False

    if not times:
        return {"error": "No successful requests"}

    # Remove inf values for stats
    valid = [t for t in times if t != float("inf")]
    if not valid:
        return {"error": "All requests failed"}

    return {
        "min_ms": round(min(valid), 2),
        "max_ms": round(max(valid), 2),
        "avg_ms": round(statistics.mean(valid), 2),
        "median_ms": round(statistics.median(valid), 2),
        "p95_ms": round(sorted(valid)[int(len(valid) * 0.95)], 2),
        "stddev_ms": round(statistics.stdev(valid), 2) if len(valid) > 1 else 0,
        "response_bytes": response_size,
        "success": status_ok,
        "samples": len(valid),
    }


def run_benchmarks():
    print("=" * 70)
    print("  zig-mupdf vs PyMuPDF Benchmark")
    print("=" * 70)
    print()

    # Check servers
    zig_ok = check_server("zig-mupdf", ZIG_URL)
    py_ok = check_server("PyMuPDF", PY_URL)

    if not zig_ok and not py_ok:
        print("\nNo servers running. Start them first:")
        print("  Terminal 1: zig build run-server")
        print("  Terminal 2: cd benchmarks && uvicorn python_server:app --port 8081")
        sys.exit(1)

    # Load PDF
    if not os.path.exists(PDF_PATH):
        print(f"PDF not found: {PDF_PATH}")
        sys.exit(1)

    with open(PDF_PATH, "rb") as f:
        pdf_data = f.read()

    print(f"  PDF: {os.path.basename(PDF_PATH)} ({len(pdf_data) / 1024:.0f} KB)")
    print(f"  Iterations: {ITERATIONS} (+ {WARMUP} warmup)")
    print(f"  Zig server: {'OK' if zig_ok else 'OFFLINE'}")
    print(f"  Python server: {'OK' if py_ok else 'OFFLINE'}")
    print()

    # Define test cases
    tests = [
        ("GET /health", "/health", None, None),
        ("POST /info", "/info", None, None),
        ("POST /text (page 0)", "/text", None, {"page": "0"}),
        ("POST /text (page 35)", "/text", None, {"page": "35"}),
        ("POST /search (common word)", "/search", None, {"page": "0", "query": "the"}),
        ("POST /search (rare word)", "/search", None, {"page": "0", "query": "algorithm"}),
        ("POST /render (1x)", "/render", None, {"page": "0", "scale": "1"}),
        ("POST /render (2x)", "/render", None, {"page": "0", "scale": "2"}),
    ]

    results = {}

    for test_name, endpoint, _, extra in tests:
        print(f"  Testing: {test_name}")
        results[test_name] = {}

        for server_name, url, ok in [("zig", ZIG_URL, zig_ok), ("python", PY_URL, py_ok)]:
            if not ok:
                results[test_name][server_name] = {"error": "offline"}
                continue

            with httpx.Client() as client:
                if endpoint == "/health":
                    # Special case: GET, no file upload
                    times = []
                    for i in range(WARMUP + ITERATIONS):
                        start = time.perf_counter()
                        try:
                            r = client.get(f"{url}{endpoint}", timeout=10)
                        except Exception:
                            if i >= WARMUP:
                                times.append(float("inf"))
                            continue
                        elapsed = time.perf_counter() - start
                        if i >= WARMUP:
                            times.append(elapsed * 1000)

                    valid = [t for t in times if t != float("inf")]
                    if valid:
                        results[test_name][server_name] = {
                            "min_ms": round(min(valid), 2),
                            "max_ms": round(max(valid), 2),
                            "avg_ms": round(statistics.mean(valid), 2),
                            "median_ms": round(statistics.median(valid), 2),
                            "p95_ms": round(sorted(valid)[int(len(valid) * 0.95)], 2),
                            "stddev_ms": round(statistics.stdev(valid), 2) if len(valid) > 1 else 0,
                            "samples": len(valid),
                            "success": True,
                        }
                    else:
                        results[test_name][server_name] = {"error": "all failed"}
                else:
                    stats = benchmark_endpoint(client, url, endpoint, pdf_data, extra)
                    results[test_name][server_name] = stats

            # Print inline
            s = results[test_name][server_name]
            if "error" in s:
                print(f"    {server_name:>8}: {s['error']}")
            else:
                print(f"    {server_name:>8}: avg={s['avg_ms']:>8.2f}ms  median={s['median_ms']:>8.2f}ms  p95={s['p95_ms']:>8.2f}ms")

        print()

    # Generate report
    print()
    print("=" * 70)
    print("  RESULTS")
    print("=" * 70)
    print()
    print(f"  {'Endpoint':<30} {'Zig (ms)':>10} {'Python (ms)':>12} {'Speedup':>10}")
    print(f"  {'-' * 30} {'-' * 10} {'-' * 12} {'-' * 10}")

    speedups = []

    for test_name in results:
        zig_data = results[test_name].get("zig", {})
        py_data = results[test_name].get("python", {})

        zig_avg = zig_data.get("avg_ms", None) if "error" not in zig_data else None
        py_avg = py_data.get("avg_ms", None) if "error" not in py_data else None

        zig_str = f"{zig_avg:.2f}" if zig_avg is not None else "N/A"
        py_str = f"{py_avg:.2f}" if py_avg is not None else "N/A"

        if zig_avg and py_avg and zig_avg > 0:
            speedup = py_avg / zig_avg
            speedups.append(speedup)
            speedup_str = f"{speedup:.1f}x"
        else:
            speedup_str = "N/A"

        print(f"  {test_name:<30} {zig_str:>10} {py_str:>12} {speedup_str:>10}")

    print()
    if speedups:
        geo_mean = 1
        for s in speedups:
            geo_mean *= s
        geo_mean = geo_mean ** (1 / len(speedups))
        print(f"  Geometric mean speedup: {geo_mean:.1f}x faster (zig-mupdf vs PyMuPDF)")
    print()

    # Save JSON results
    results_dir = os.path.join(os.path.dirname(__file__), "results")
    os.makedirs(results_dir, exist_ok=True)

    timestamp = time.strftime("%Y%m%d_%H%M%S")
    report_path = os.path.join(results_dir, f"benchmark_{timestamp}.json")

    report = {
        "timestamp": timestamp,
        "pdf": os.path.basename(PDF_PATH),
        "pdf_size_bytes": len(pdf_data),
        "iterations": ITERATIONS,
        "warmup": WARMUP,
        "results": results,
        "geometric_mean_speedup": round(geo_mean, 2) if speedups else None,
    }

    with open(report_path, "w") as f:
        json.dump(report, f, indent=2)

    print(f"  Full results saved to: {report_path}")
    print()


if __name__ == "__main__":
    run_benchmarks()

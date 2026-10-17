#!/usr/bin/env python3
"""Closed-loop HTTP load generator used by the concurrency benchmark and repro scripts.

`concurrency` worker threads each keep exactly one request in flight against
the server until `requests` requests have completed. The multipart body is
encoded once up front, so the client spends as little CPU as possible per
request (it shares the machine with the server).

CLI:
    python3 benchmarks/loadgen.py URL ENDPOINT [-c 1,2,4,8] [-n 64] [-f page=0 -f scale=2]
"""
import argparse
import json
import os
import statistics
import threading
import time
import uuid

import httpx

DEFAULT_PDF = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "examples", "example.pdf")


def encode_multipart(pdf_bytes, fields):
    boundary = uuid.uuid4().hex
    parts = []
    for k, v in fields.items():
        parts.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode()
        )
    parts.append(
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="doc.pdf"\r\n'
        f"Content-Type: application/pdf\r\n\r\n".encode() + pdf_bytes + b"\r\n"
    )
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def percentile(sorted_vals, p):
    if not sorted_vals:
        return float("nan")
    k = (len(sorted_vals) - 1) * p / 100.0
    lo, hi = int(k), min(int(k) + 1, len(sorted_vals) - 1)
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (k - lo)


def run_load(url, endpoint, pdf_bytes, fields, concurrency, requests, timeout=120.0, field_fn=None):
    """Return dict with throughput and latency stats.

    field_fn(i) -> dict lets each request vary its form fields (e.g. page=i).
    """
    bodies = {}

    def body_for(i):
        f = field_fn(i) if field_fn else fields
        key = json.dumps(f, sort_keys=True)
        if key not in bodies:
            bodies[key] = encode_multipart(pdf_bytes, f)
        return bodies[key]

    for i in range(requests):  # pre-encode outside the timed region
        body_for(i)

    lock = threading.Lock()
    next_idx = [0]
    latencies, errors = [], []

    def worker():
        with httpx.Client(timeout=timeout, headers={"Connection": "close"}) as client:
            while True:
                with lock:
                    i = next_idx[0]
                    if i >= requests:
                        return
                    next_idx[0] += 1
                content, ctype = body_for(i)
                t0 = time.perf_counter()
                try:
                    r = client.post(url + endpoint, content=content, headers={"Content-Type": ctype})
                    ok = r.status_code == 200
                    _ = r.content
                except Exception as e:  # noqa: BLE001
                    ok = False
                    r = e
                dt = (time.perf_counter() - t0) * 1000
                with lock:
                    if ok:
                        latencies.append(dt)
                    else:
                        errors.append(str(getattr(r, "status_code", r)))

    threads = [threading.Thread(target=worker) for _ in range(concurrency)]
    t0 = time.perf_counter()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    wall = time.perf_counter() - t0
    lat = sorted(latencies)
    return {
        "endpoint": endpoint,
        "concurrency": concurrency,
        "requests": requests,
        "ok": len(lat),
        "errors": len(errors),
        "error_samples": errors[:3],
        "wall_s": round(wall, 3),
        "rps": round(len(lat) / wall, 2) if wall > 0 else 0,
        "p50_ms": round(percentile(lat, 50), 1),
        "p95_ms": round(percentile(lat, 95), 1),
        "p99_ms": round(percentile(lat, 99), 1),
        "mean_ms": round(statistics.mean(lat), 1) if lat else float("nan"),
    }


def warmup(url, endpoint, pdf_bytes, fields, n=4):
    run_load(url, endpoint, pdf_bytes, fields, concurrency=min(n, 4), requests=n)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("url")
    ap.add_argument("endpoint")
    ap.add_argument("-c", "--concurrency", default="1,2,4,8")
    ap.add_argument("-n", "--requests", type=int, default=64)
    ap.add_argument("-f", "--field", action="append", default=[])
    ap.add_argument("--pdf", default=DEFAULT_PDF)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    fields = dict(kv.split("=", 1) for kv in args.field)
    pdf = open(args.pdf, "rb").read()
    warmup(args.url, args.endpoint, pdf, fields)
    print(f"{'endpoint':<10} {'conc':>4} {'ok':>5} {'err':>4} {'req/s':>8} {'p50 ms':>8} {'p95 ms':>8} {'p99 ms':>8}")
    for c in [int(x) for x in args.concurrency.split(",")]:
        r = run_load(args.url, args.endpoint, pdf, fields, c, args.requests)
        if args.json:
            print(json.dumps(r))
        print(f"{r['endpoint']:<10} {c:>4} {r['ok']:>5} {r['errors']:>4} {r['rps']:>8.2f} {r['p50_ms']:>8.1f} {r['p95_ms']:>8.1f} {r['p99_ms']:>8.1f}")


if __name__ == "__main__":
    main()

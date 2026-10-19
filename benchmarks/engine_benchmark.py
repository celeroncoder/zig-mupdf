#!/usr/bin/env python3
"""In-process engine comparison: zig-mupdf library vs PyMuPDF library (no HTTP).

Each operation is timed identically in both (see benchmarks/engine_bench.zig):
  open           open from memory + page count
  text           open + load page + plain text
  render_1x_png  open + load page + render scale 1 + PNG encode
  render_2x_png  open + load page + render scale 2 + PNG encode

Usage:
    zig build -Doptimize=ReleaseFast
    python3 benchmarks/engine_benchmark.py [--pdf examples/example.pdf] [-n 30] [--page 0]
"""
import argparse
import json
import os
import statistics
import subprocess
import time

import pymupdf

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def py_open(data, page):
    doc = pymupdf.open(stream=data, filetype="pdf")
    _ = doc.page_count
    doc.close()


def py_text(data, page):
    doc = pymupdf.open(stream=data, filetype="pdf")
    doc.load_page(page).get_text("text")
    doc.close()


def py_render(scale):
    def f(data, page):
        doc = pymupdf.open(stream=data, filetype="pdf")
        doc.load_page(page).get_pixmap(matrix=pymupdf.Matrix(scale, scale)).tobytes("png")
        doc.close()
    return f


def bench(fn, data, page, n):
    for _ in range(3):
        fn(data, page)
    samples = []
    for _ in range(n):
        t0 = time.perf_counter()
        fn(data, page)
        samples.append((time.perf_counter() - t0) * 1000)
    samples.sort()
    return {"median_ms": round(samples[n // 2], 3), "mean_ms": round(statistics.mean(samples), 3),
            "p95_ms": round(samples[(n * 95) // 100], 3), "min_ms": round(samples[0], 3)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pdf", default=os.path.join(ROOT, "examples", "example.pdf"))
    ap.add_argument("-n", type=int, default=30)
    ap.add_argument("--page", type=int, default=0)
    ap.add_argument("--zig-bin", default=os.path.join(ROOT, "zig-out", "bin", "mupdf-engine-bench"))
    ap.add_argument("--json", help="write results to this file")
    args = ap.parse_args()
    data = open(args.pdf, "rb").read()
    pymupdf.TOOLS.mupdf_display_errors(False)
    pymupdf.TOOLS.mupdf_display_warnings(False)

    out = subprocess.run([args.zig_bin, args.pdf, str(args.n), str(args.page)], check=True,
                         capture_output=True, text=True, cwd=ROOT).stdout
    zig = {r["op"]: r for r in map(json.loads, out.strip().splitlines())}
    py = {
        "open": bench(py_open, data, args.page, args.n),
        "text": bench(py_text, data, args.page, args.n),
        "render_1x_png": bench(py_render(1), data, args.page, args.n),
        "render_2x_png": bench(py_render(2), data, args.page, args.n),
    }
    print(f"PDF: {os.path.basename(args.pdf)} page {args.page}, {args.n} iterations, PyMuPDF {pymupdf.VersionBind} (MuPDF {pymupdf.VersionFitz})")
    print(f"{'operation':<16} {'zig median':>11} {'py median':>10} {'zig p95':>9} {'py p95':>9} {'py/zig':>7}")
    for op in py:
        z, p = zig[op], py[op]
        print(f"{op:<16} {z['median_ms']:>9.2f}ms {p['median_ms']:>8.2f}ms {z['p95_ms']:>7.2f}ms {p['p95_ms']:>7.2f}ms {p['median_ms'] / z['median_ms']:>6.2f}x")
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"zig": zig, "pymupdf": py, "pymupdf_version": pymupdf.VersionBind}, f, indent=2)


if __name__ == "__main__":
    main()

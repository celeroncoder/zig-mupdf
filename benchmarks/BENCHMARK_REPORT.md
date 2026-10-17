# zig-mupdf vs PyMuPDF Benchmark Report

**Date:** 2026-10-17
**PDF:** `examples/example.pdf` (1,338 KB, 72 pages). The file has an HTML page appended after `%%EOF`, so **both** engines run MuPDF's xref repair on every open.

## Machine

| | |
|---|---|
| CPU | Intel Xeon @ 2.60 GHz, **2 vCPUs** (`Thread(s) per core: 2`, so most likely one physical core with SMT) |
| RAM | 7.8 GiB |
| OS | Linux 6.1 (cloud VM) |
| Zig | 0.15.2, `-Doptimize=ReleaseFast`, MuPDF 1.28.0 vendored |
| Python | 3.12.3, PyMuPDF 1.28.2 (MuPDF 1.28.2), FastAPI 0.143.3, uvicorn 0.54.0 |

The load generator (Python) runs on the same 2 vCPUs as the servers and competes with them for CPU. Absolute numbers are about 2× slower than the March report, which was run on a different (faster, unspecified) machine. Compare the columns within this report, not with the old one.

## 1. Sequential HTTP latency (original methodology)

`python3 benchmarks/benchmark.py`: 20 iterations + 3 warm-up, one request at a time. Zig server with its defaults (2 workers); uvicorn with 1 worker, as in the original report.

| Endpoint | zig-mupdf (ms) | PyMuPDF (ms) | Speedup | March report (zig / py) |
|---|---:|---:|---:|---:|
| GET /health | 0.70 | 0.89 | 1.3× | 0.55 / 0.41 |
| POST /info | **5.17** | 9.73 | 1.9× | 2.62 / 4.72 |
| POST /text (page 0) | **18.34** | 23.75 | 1.3× | 9.80 / 13.51 |
| POST /text (page 35) | **18.36** | 23.61 | 1.3× | 9.98 / 12.75 |
| POST /search (common) | **19.06** | 28.69 | 1.5× | 9.91 / 14.70 |
| POST /search (rare) | **19.82** | 25.22 | 1.3× | 9.85 / 12.88 |
| POST /render 1× | **45.79** | 48.17 | 1.1× | 23.12 / 25.27 |
| POST /render 2× | **89.24** | 93.93 | 1.1× | 44.00 / 49.47 |

Geometric mean: zig-mupdf is **1.3×** faster (March: 1.2×). The relative picture is unchanged.

## 2. Concurrency: throughput and latency

`python3 benchmarks/concurrency_benchmark.py -n 48`. Both servers run **N = 2 workers (= CPU count)**: `mupdf-server --workers 2` versus `uvicorn python_server:app --workers 2`. A closed-loop load keeps *c* requests in flight (`benchmarks/loadgen.py`, multipart body pre-encoded). There are 192 requests per level for `/text` (page 0) and 48 for `/render` (page 0, scale 2).

| Endpoint | c | zig req/s | py req/s | zig p50 / p95 / p99 ms | py p50 / p95 / p99 ms |
|---|---:|---:|---:|---:|---:|
| /text | 1 | **54.3** | 40.1 | 18.0 / 20.6 / 22.9 | 24.4 / 27.8 / 30.9 |
| /text | 2 | **100.6** | 64.3 | 18.3 / 23.1 / 42.0 | 25.9 / 47.8 / 61.3 |
| /text | 4 | **95.2** | 72.7 | 37.2 / 59.4 / 72.1 | 50.8 / 91.4 / 99.1 |
| /text | 8 | **89.4** | 72.0 | 75.0 / 121.5 / 131.4 | 100.2 / 159.6 / 170.7 |
| /render 2× | 1 | **11.5** | 10.5 | 85.5 / 94.1 / 102.7 | 94.6 / 100.5 / 111.7 |
| /render 2× | 2 | **20.5** | 16.8 | 85.8 / 134.7 / 147.4 | 97.4 / 185.6 / 187.5 |
| /render 2× | 4 | **20.2** | 18.5 | 171.5 / 248.5 / 255.7 | 187.6 / 369.6 / 397.1 |
| /render 2× | 8 | **19.9** | 17.9 | 348.6 / 488.0 / 499.6 | 386.5 / 599.3 / 721.8 |

* Both servers scale from c=1 to c=2 and then plateau, since 2 vCPUs are saturated. Zig gets 1.85× on `/text` and 1.78× on `/render`; PyMuPDF gets 1.60× on both.
* Zig's throughput edge is **1.24–1.56× on /text** and **1.09–1.22× on /render**. The gap is per-request overhead (Python HTTP, multipart parsing, ASGI); rendering is engine-bound on both sides.
* The tail latency gap is larger than the median gap: at c=8 on `/render`, p99 is 500 vs 722 ms.
* **Where Zig doesn't win:** in a short exploratory run (`-n 16`), PyMuPDF had the *lower* `/render` p50 at c=8 (271 vs 329 ms), though with a much worse p95/p99. The Zig server queues requests strictly FIFO across 2 workers, which evens out latency rather than minimizing the median. In the full run above, Zig won p50 as well, but the medians are within ~10%.

Before this PR, the Zig server was single-threaded: `/render` was flat at ~11.5 req/s for every c, and `/text` at ~52 req/s (see VERIFICATION.md, Issue 2). Against `uvicorn --workers 2`, it would have **lost** on throughput at c ≥ 2.

## 3. In-process engine comparison (no HTTP)

`python3 benchmarks/engine_benchmark.py -n 50`. It runs `zig-out/bin/mupdf-engine-bench` (`benchmarks/engine_bench.zig`) and the same operations through PyMuPDF in-process. Every operation starts from the in-memory PDF bytes.

| Operation | zig median | PyMuPDF median | zig p95 | PyMuPDF p95 | PyMuPDF / zig |
|---|---:|---:|---:|---:|---:|
| open + page count | 2.45 ms | **2.37 ms** | 3.10 | 2.71 | 0.97× |
| open + load + text | **16.12 ms** | 18.34 ms | 17.85 | 19.23 | 1.14× |
| open + load + render 1× + PNG | 40.01 ms | 40.08 ms | 46.12 | 51.30 | 1.00× |
| open + load + render 2× + PNG | **81.56 ms** | 85.15 ms | 88.33 | 93.37 | 1.04× |

**The engines are effectively equal**, since both are MuPDF 1.28. PyMuPDF is slightly faster at open (it avoids a buffer copy that `Document.openFromMemory` makes). Zig is 14% faster at text, which includes PyMuPDF's conversion to a Python `str`. Render and PNG encoding are identical within noise. So the HTTP-level speedups above come from the server and framework layer, not from the PDF engine.

Earlier review figures for comparison (different methodology: Zig over HTTP vs PyMuPDF in-process): Zig over HTTP 26 ms text / 106 ms render 2×, PyMuPDF in-process 20 / 96 ms. Here, Zig over HTTP at c=1 is 18.0 ms text / 85.5 ms render 2×, and PyMuPDF in-process is 18.3 / 85.2 ms. HTTP overhead in the Zig server is now ~2 ms for text and ~4 ms for render (upload + response).

## How to reproduce

```bash
zig build -Doptimize=ReleaseFast
python3 -m venv /tmp/venv && /tmp/venv/bin/pip install -r benchmarks/requirements.txt

# 1. sequential (start both servers first)
./zig-out/bin/mupdf-server 8080 &
(cd benchmarks && /tmp/venv/bin/python -m uvicorn python_server:app --port 8081) &
/tmp/venv/bin/python benchmarks/benchmark.py

# 2. concurrency (starts and stops both servers itself; stop the ones above first)
/tmp/venv/bin/python benchmarks/concurrency_benchmark.py -n 48 --json /tmp/concurrency.json

# 3. in-process engine
/tmp/venv/bin/python benchmarks/engine_benchmark.py -n 50
```

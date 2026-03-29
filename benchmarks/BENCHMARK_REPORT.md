# zig-mupdf vs PyMuPDF Benchmark Report

**Date:** 2026-03-29
**PDF:** example.pdf (1,338 KB, 72 pages)
**Iterations:** 20 per test (+ 3 warmup)
**Zig build:** ReleaseFast
**Python:** uvicorn + FastAPI + PyMuPDF 1.25.5

## Results

| Endpoint | zig-mupdf (ms) | PyMuPDF (ms) | Speedup |
|---|---:|---:|---:|
| GET /health | 0.55 | 0.41 | 0.7x |
| POST /info | **2.62** | 4.72 | **1.8x** |
| POST /text (page 0) | **9.80** | 13.51 | **1.4x** |
| POST /text (page 35) | **9.98** | 12.75 | **1.3x** |
| POST /search (common) | **9.91** | 14.70 | **1.5x** |
| POST /search (rare) | **9.85** | 12.88 | **1.3x** |
| POST /render 1x | **23.12** | 25.27 | **1.1x** |
| POST /render 2x | **44.00** | 49.47 | **1.1x** |

**Geometric mean: zig-mupdf is 1.2x faster than PyMuPDF.**

zig-mupdf wins on every PDF processing endpoint. PyMuPDF only wins on the health check (no PDF work) by 0.14ms.

## Key Optimizations

The initial version was **~5x slower** than PyMuPDF. Three changes brought it to **1.2x faster**:

1. **HTTP 100-Continue handling** — The biggest win. curl sends `Expect: 100-continue` for large uploads and waits 1 second if the server doesn't respond. Adding a `100 Continue` response eliminated a 1-second delay per request.

2. **In-memory PNG encoding** — Replaced disk write + read with `fz_new_buffer_from_pixmap_as_png()` for in-memory PNG generation.

3. **Global MuPDF context** — Reuse a single context across requests instead of creating/destroying per request.

## Direct library benchmark (no HTTP)

Tested MuPDF operations directly, bypassing HTTP:

| Operation | Time |
|---|---:|
| Full pipeline (open+render+PNG) | 21.6ms |
| Document open from memory | 1.2ms |
| Page load | 0.3ms |
| Page render to pixmap | 8.3ms |
| PNG encode | 8.3ms |

This confirms that MuPDF itself is fast — the server overhead is minimal after optimization.

## How to reproduce

```bash
# Terminal 1: Zig server (ReleaseFast)
zig build run-server -Doptimize=ReleaseFast

# Terminal 2: Python server
cd benchmarks && source .venv/bin/activate
uvicorn python_server:app --host 0.0.0.0 --port 8081

# Terminal 3: Run benchmark
source benchmarks/.venv/bin/activate
python3 benchmarks/benchmark.py
```

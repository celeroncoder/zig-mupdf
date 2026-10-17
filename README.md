# zig-mupdf

High-performance PDF processing library for Zig, wrapping the [MuPDF](https://mupdf.com/) C library. Faster than PyMuPDF with zero-cost abstractions and predictable memory management.

## Features

- **Document handling** -- open from file or memory, metadata read/write, save with options
- **Page rendering** -- render pages to PNG at any scale via `Pixmap`
- **Text extraction** -- plain text, structured (block/line/char with positions, fonts, sizes)
- **Search** -- find text on pages with hit rectangles
- **Image extraction** -- enumerate and extract embedded images
- **Transformations** -- full `Matrix` API (scale, rotate, translate, concat)
- **Links & rotation** -- iterate page links, read page rotation
- **Thread safety** -- `Context.initThreadSafe()` + `clone()` for multi-threaded use
- **Crash-safe on malformed input** -- every throwing MuPDF call is wrapped in `fz_try`; fuzzed with `zig build fuzz`
- **HTTP server** -- multi-threaded server with `/info`, `/text`, `/search`, `/render` endpoints, request timeouts and size limits

## Quick Start

```bash
git clone --recurse-submodules https://github.com/celeroncoder/zig-mupdf.git
cd zig-mupdf
zig build test          # Run 109 tests
zig build run -- examples/example.pdf   # Run pdf-info example
```

## Supported formats

The build compiles a trimmed MuPDF (see the `mupdf_cflags` in `build.zig`):

| Format | Supported | Notes |
|---|:---:|---|
| PDF | ✅ | Full read support; write/edit via `save`, pages, annotations, metadata |
| XPS | ✅ | OpenXPS / XPS |
| SVG | ✅ | |
| CBZ | ✅ | Also CBT, ZIP and TAR archives of images (no CBR/RAR) |
| Images | ✅ | PNG, JPEG, JPEG 2000, TIFF, BMP, GIF, PNM, PSD, JBIG2 (JPEG XR is not available) |
| EPUB | ❌ | Compiled out (`FZ_ENABLE_EPUB=0`, needs the HTML engine + HarfBuzz) |
| HTML | ❌ | HTML/XHTML compiled out (`FZ_ENABLE_HTML=0`) |
| TXT | ❌ | Compiled out (`FZ_ENABLE_TXT=0`) |
| FB2 | ❌ | FictionBook compiled out (`FZ_ENABLE_FB2=0`); MOBI likewise (`FZ_ENABLE_MOBI=0`) |
| Office | ❌ | DOCX/XLSX/PPTX/ODT compiled out (`FZ_ENABLE_OFFICE=0`) |

Unsupported formats fail in `Document.open` / `openFromMemory` with `error.OpenFailed`.

Other trimmed features:

- **Fonts:** only the 14 standard PDF fonts (URW Base14 clones) are built in. The Noto fallback fonts and the CJK fonts are compiled out (`-DTOFU -DTOFU_CJK`). PDFs that *embed* their fonts (the common case) render and extract correctly in any script. Text drawn with a **non-embedded** CJK, Arabic, Devanagari or other non-Latin font has no fallback font, so it renders as blank/missing glyphs. Text extraction still returns the Unicode if the PDF maps it.
- **HarfBuzz text shaping:** not compiled. It is only needed for laying out reflowable formats (HTML/EPUB) and some annotation/form appearance generation, not for rendering existing PDF content.
- **OCR** (Tesseract/Leptonica) and **JavaScript** (MuJS, PDF form scripts) are compiled out (`FZ_ENABLE_OCR=0`, `FZ_ENABLE_JS=0`).

## Usage

```zig
const mupdf = @import("mupdf");

pub fn main() !void {
    var ctx = try mupdf.Context.init();
    defer ctx.deinit();

    var doc = try mupdf.Document.open(&ctx, "document.pdf");
    defer doc.deinit();

    // Metadata
    const allocator = std.heap.page_allocator;
    var metadata = try doc.getAllMetadata(allocator);
    defer metadata.deinit();

    // Render page 0 to PNG
    var page = try doc.loadPage(0);
    defer page.deinit();

    var pixmap = try page.toPixmap(2.0, 0.0); // 2x scale
    defer pixmap.deinit();
    try pixmap.savePng("page0.png");

    // Extract text
    const text = try page.getText(allocator);
    defer allocator.free(text);

    // Search
    const hits = try page.search("keyword", allocator);
    defer allocator.free(hits);

    // Extract images
    const images = try page.getImages(allocator);
    defer allocator.free(images);
    for (images) |img_info| {
        var img = try page.loadImage(img_info.xref);
        defer img.deinit();
        var img_pix = try img.toPixmap();
        defer img_pix.deinit();
        try img_pix.savePng("extracted.png");
    }
}
```

## Thread safety

A `Context` must never be used by two threads at once. Either give each thread an independent context:

```zig
var ctx = try mupdf.Context.init(); // per thread, shares nothing
defer ctx.deinit();
```

or create one lock-enabled base context and clone it per thread. Clones share the resource store and font/glyph caches:

```zig
var base = try mupdf.Context.initThreadSafe(); // mutexes for FZ_LOCK_MAX
defer base.deinit();                            // after every clone is gone

// in each thread:
var ctx = try base.clone();
defer ctx.deinit();
```

Documents and pages belong to the context that opened them. With clones, prefer independent contexts when threads process unrelated, untrusted documents. MuPDF 1.28's shared store compares keys across documents, and `VERIFICATION.md` (Issue 3) describes the race this causes. `Document.deinit` closes the drop-time part of that race.

## HTTP Server

```bash
zig build run-server -Doptimize=ReleaseFast -- 8080 --workers 4
```

The main thread reads requests with a non-blocking `poll()` loop and hands only complete requests to a fixed pool of worker threads. Each worker has its own MuPDF context. Idle or slow clients never occupy a worker.

| Flag | Default | Meaning |
|---|---|---|
| `[port]` | `8080` | TCP port (positional) |
| `--workers N`, `-w N` | CPU count | Worker threads |
| `--queue N` | `1024` | Complete requests waiting for a worker; `503` beyond |
| `--max-connections N` | `1024` | Connections being read at once; `503` beyond |
| `--read-timeout-ms N` | `10000` | Request head must arrive within N ms of accept; body must progress every N ms (`408`). Also `SO_RCVTIMEO` |
| `--write-timeout-ms N` | `10000` | `SO_SNDTIMEO` for responses |
| `--max-header-bytes N` | `16384` | Request line + headers limit (`431`) |
| `--max-body-bytes N` | `52428800` | `Content-Length` limit (`413`) |
| `--store-mb N` | `256` | Total MuPDF resource store budget, split across workers |
| `--shared-store` | off | Clone all worker contexts from one `initThreadSafe()` base (shared store and caches) instead of independent contexts |

Malformed requests get `400` (bad or conflicting `Content-Length`, or a body shorter than `Content-Length`). Chunked uploads get `411`. PDFs with a broken page tree get `422`.

```bash
# PDF metadata
curl -X POST -F "file=@doc.pdf" http://localhost:8080/info

# Extract text from page 0
curl -X POST -F "file=@doc.pdf" -F "page=0" http://localhost:8080/text

# Search
curl -X POST -F "file=@doc.pdf" -F "page=0" -F "query=hello" http://localhost:8080/search

# Render page to PNG
curl -X POST -F "file=@doc.pdf" -F "page=0" -F "scale=2" -o page.png http://localhost:8080/render
```

## Benchmarks

Tested against PyMuPDF 1.28 (FastAPI + uvicorn) with a 72-page, 1.3 MB PDF on a 2-vCPU VM (2026-10-17).

Throughput with both servers at 2 workers (`uvicorn --workers 2`):

| Endpoint | concurrency | zig-mupdf req/s | PyMuPDF req/s | zig p95 | PyMuPDF p95 |
|---|---:|---:|---:|---:|---:|
| `/text` | 1 | 54.3 | 40.1 | 20.6 ms | 27.8 ms |
| `/text` | 8 | 89.4 | 72.0 | 121.5 ms | 159.6 ms |
| `/render` 2x | 1 | 11.5 | 10.5 | 94.1 ms | 100.5 ms |
| `/render` 2x | 8 | 19.9 | 17.9 | 488.0 ms | 599.3 ms |

In-process the engines are equal (both are MuPDF 1.28). Text extraction is 1.14× faster in Zig, render+PNG is 1.00–1.04×, and open is 0.97× (PyMuPDF slightly faster). The HTTP-level gains come from lower server overhead, not from the engine.

See [benchmarks/BENCHMARK_REPORT.md](benchmarks/BENCHMARK_REPORT.md) for methodology and full results. To reproduce: `benchmarks/benchmark.py` (sequential), `benchmarks/concurrency_benchmark.py` (c=1/2/4/8), and `benchmarks/engine_benchmark.py` (in-process; uses `zig build bench-engine`).

## API Reference

### Core Types

| Type | Description |
|---|---|
| `Context` | MuPDF context (one per thread; `init()`, `initThreadSafe()`, `clone()`) |
| `Document` | Opened document (PDF, XPS, SVG, CBZ, or image; see [Supported formats](#supported-formats)) |
| `Page` | Single page with render/text/search/images |
| `Pixmap` | Rendered pixel buffer with PNG export |
| `Matrix` | 2D affine transformation |
| `TextPage` | Structured text with block/line/char iteration |
| `SearchHit` | Search result with bounding quad |
| `ImageInfo` | Embedded image metadata |
| `Image` | Loaded image for extraction |
| `Link` | Hyperlink with URI and rect |

### Document Methods

```zig
Document.open(ctx, path)                    // Open from file
Document.openFromMemory(ctx, data, magic)   // Open from memory
doc.pageCount()                             // Number of pages (Error!i32: fails on broken page trees)
doc.loadPage(n)                             // Load page by index
doc.getMetadata(key, allocator)             // Single metadata value
doc.getAllMetadata(allocator)                // All metadata
doc.save(path, options)                     // Save with options
doc.isPdf()                                 // Document properties
doc.needsPassword() / doc.authenticate(pw)  // Error!bool
```

### Page Methods

```zig
page.bounds() / page.width() / page.height()   // Dimensions (Error!Rect / Error!f32)
page.rotation()                                  // Rotation (0/90/180/270)
page.toPixmap(scale, rotation)                   // Render to pixmap
page.toPixmapWithMatrix(matrix)                  // Render with matrix
page.getText(allocator)                          // Plain text
page.extractText(options)                        // Structured TextPage
page.search(needle, allocator)                   // Search hits
page.getImages(allocator)                        // Image list
page.loadImage(xref)                             // Load image by xref
page.loadLinks()                                 // Link list
```

## Building from Source

Requirements: [Zig 0.15.2+](https://ziglang.org/download/)

```bash
git clone --recurse-submodules https://github.com/celeroncoder/zig-mupdf.git
cd zig-mupdf
zig build                           # Debug build
zig build -Doptimize=ReleaseFast    # Release build
zig build test                      # Run tests
zig build fuzz -- 3000 1            # Mutation fuzz loop (iterations, seed[, corpus dir])
zig build bench-engine -Doptimize=ReleaseFast -- examples/example.pdf 30   # In-process engine timings
```

Build options:

| Option | Default | Meaning |
|---|---|---|
| `-Doptimize=` | `Debug` | Use `ReleaseFast` for serving and benchmarks |
| `-Dsanitize-mupdf=true` | `false` | Compile the vendored MuPDF C code with UBSan. Off by default because upstream MuPDF trips UBSan on ordinary input (misaligned XML allocator, signed overflows). Zig code always keeps its safety checks |

MuPDF and all its dependencies (freetype, zlib, libjpeg, openjpeg, jbig2dec, lcms2, etc.) are compiled from source -- no system libraries required.

## Project Structure

```
src/
  root.zig          Public API exports
  document.zig      Document, Page, Pixmap, Matrix, TextPage, Image, etc.
  context.zig       MuPDF context wrapper
  error.zig         Error types
  c.zig             Low-level C bindings
  mupdf_shim.h/c    C shim for bitfields and safe error handling
examples/
  pdf_info.zig      CLI example
  server.zig        HTTP server
  example.pdf       Sample PDF for testing
tests/
  fuzz.zig          Mutation fuzz loop (zig build fuzz)
  fixtures/         Test PDFs, crafted malformed PDFs, one sample per format
scripts/repro/      Reproduction scripts for VERIFICATION.md
benchmarks/
  python_server.py  PyMuPDF comparison server
  benchmark.py      Sequential benchmark runner
  concurrency_benchmark.py  Throughput/latency at concurrency 1/2/4/8
  engine_bench.zig, engine_benchmark.py  In-process engine comparison
  loadgen.py        Closed-loop load generator
generated/
  fonts/            Base14 font data (URW CFF fonts as C arrays)
```

## License

This wrapper is [MIT licensed](LICENSE). MuPDF itself is [AGPL-3.0](https://www.gnu.org/licenses/agpl-3.0.html) or available under a [commercial license](https://mupdf.com/licensing/) from Artifex Software. Binaries linking MuPDF must comply with MuPDF's license.

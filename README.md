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
- **HTTP server** -- ready-to-use server with `/info`, `/text`, `/search`, `/render` endpoints

## Quick Start

```bash
git clone --recurse-submodules https://github.com/celeroncoder/zig-mupdf.git
cd zig-mupdf
zig build test          # Run 76 tests
zig build run -- examples/example.pdf   # Run pdf-info example
```

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

## HTTP Server

```bash
zig build run-server -Doptimize=ReleaseFast
```

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

Tested against PyMuPDF (FastAPI + uvicorn) with a 72-page, 1.3MB PDF:

| Endpoint | zig-mupdf | PyMuPDF | Speedup |
|---|---:|---:|---:|
| `/info` | 2.6ms | 4.7ms | **1.8x** |
| `/text` | 9.8ms | 13.5ms | **1.4x** |
| `/search` | 9.9ms | 14.7ms | **1.5x** |
| `/render` (1x) | 23ms | 25ms | **1.1x** |
| `/render` (2x) | 44ms | 50ms | **1.1x** |

See [benchmarks/BENCHMARK_REPORT.md](benchmarks/BENCHMARK_REPORT.md) for methodology and full results.

## API Reference

### Core Types

| Type | Description |
|---|---|
| `Context` | MuPDF context (one per thread) |
| `Document` | Opened PDF/XPS/EPUB document |
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
doc.pageCount()                             // Number of pages
doc.loadPage(n)                             // Load page by index
doc.getMetadata(key, allocator)             // Single metadata value
doc.getAllMetadata(allocator)                // All metadata
doc.save(path, options)                     // Save with options
doc.isPdf() / doc.needsPassword()           // Document properties
```

### Page Methods

```zig
page.bounds() / page.width() / page.height()   // Dimensions
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

Requirements: [Zig 0.15+](https://ziglang.org/download/)

```bash
git clone --recurse-submodules https://github.com/celeroncoder/zig-mupdf.git
cd zig-mupdf
zig build                           # Debug build
zig build -Doptimize=ReleaseFast    # Release build
zig build test                      # Run tests
```

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
benchmarks/
  python_server.py  PyMuPDF comparison server
  benchmark.py      Benchmark runner
generated/
  fonts/            Base14 font data (URW CFF fonts as C arrays)
```

## License

This wrapper is [MIT licensed](LICENSE). MuPDF itself is [AGPL-3.0](https://www.gnu.org/licenses/agpl-3.0.html) or available under a [commercial license](https://mupdf.com/licensing/) from Artifex Software. Binaries linking MuPDF must comply with MuPDF's license.

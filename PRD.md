# zig-mupdf: Product Requirements Document

## Executive Summary

**zig-mupdf** is a high-performance, idiomatic Zig wrapper around the MuPDF C library, designed to provide PyMuPDF-like functionality with Zig's performance benefits (no GC, predictable memory, first-class C interop). The project aims to enable building high-performance PDF processing servers and tools.

## Goals

1. **Performance**: Leverage Zig's zero-cost abstractions and direct C interop for maximum throughput
2. **Safety**: Provide memory-safe wrappers with proper resource management (RAII via `defer`)
3. **Ergonomics**: Idiomatic Zig API inspired by PyMuPDF's design patterns
4. **Portability**: Cross-platform support (Linux, macOS, Windows)
5. **Extensibility**: Modular architecture that allows incremental feature additions

## Non-Goals (Initial Phases)

- JavaScript/annotation scripting support
- GUI rendering (focus is server-side)
- PDF creation from scratch (focus on manipulation of existing PDFs first)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Application Layer                              │
│                    (HTTP Server / CLI Tool / etc.)                       │
├─────────────────────────────────────────────────────────────────────────┤
│                          zig-mupdf Public API                            │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌───────────┐  │
│  │ Document │  │   Page   │  │  Pixmap  │  │ TextPage │  │ Annot/Link│  │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘  └───────────┘  │
├─────────────────────────────────────────────────────────────────────────┤
│                       Internal Bindings Layer                            │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │  Low-level Zig bindings: @cImport of mupdf headers              │    │
│  │  Memory management wrappers, error handling translation         │    │
│  └─────────────────────────────────────────────────────────────────┘    │
├─────────────────────────────────────────────────────────────────────────┤
│                           MuPDF C Library                                │
│  (fitz core + pdf module, built from source via build.zig)              │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## MuPDF Core Concepts (Context)

Based on the MuPDF source code analysis:

### Key Data Structures

| C Type | Purpose | Zig Wrapper |
|--------|---------|-------------|
| `fz_context` | Global state, memory allocator, error handling | `Context` |
| `fz_document` | Open document (PDF, XPS, EPUB, etc.) | `Document` |
| `fz_page` | Single page from a document | `Page` |
| `fz_pixmap` | Raster image with pixels | `Pixmap` |
| `fz_stext_page` | Structured text extraction results | `TextPage` |
| `fz_matrix` | 2D transformation matrix | `Matrix` |
| `fz_rect` / `fz_irect` | Bounding rectangles | `Rect` / `IRect` |
| `fz_colorspace` | Color space definitions | `Colorspace` |
| `pdf_document` | PDF-specific document handle | `PdfDocument` |
| `pdf_annot` | PDF annotation | `Annotation` |

### Memory Management Pattern

MuPDF uses a reference-counting pattern with `fz_keep_*` and `fz_drop_*` functions:

```c
// MuPDF C pattern
fz_document *doc = fz_open_document(ctx, filename);
// ... use doc ...
fz_drop_document(ctx, doc);
```

In Zig, this maps naturally to:

```zig
// Zig wrapper pattern
var doc = try Document.open(ctx, filename);
defer doc.deinit();
// ... use doc ...
```

### Error Handling

MuPDF uses setjmp/longjmp for exceptions (`fz_try`/`fz_catch`). The Zig wrapper must:
1. Wrap C calls that can throw
2. Convert C exceptions to Zig errors
3. Provide meaningful error types

---

## PyMuPDF API Reference (Design Inspiration)

Based on PyMuPDF analysis, key patterns to mirror:

### Document Class (~3000 lines in PyMuPDF)
```python
# PyMuPDF patterns to adapt
doc = fitz.open("file.pdf")           # Open document
doc.page_count                        # Property: page count
doc.metadata                          # Dict: title, author, etc.
page = doc.load_page(0)               # Load specific page
doc.insert_pdf(other_doc)             # Merge PDFs
doc.save("output.pdf")                # Save with options
```

### Page Class (~3000 lines in PyMuPDF)
```python
page.rect                             # Page dimensions
page.get_text("text")                 # Plain text extraction
page.get_text("dict")                 # Structured text (fonts, positions)
page.get_pixmap(matrix=scale)         # Render to image
page.get_images()                     # List embedded images
page.insert_text(point, "Hello")      # Add text
page.add_highlight_annot(quads)       # Add annotation
```

### Key Method Naming Patterns
- `get_*()` - Retrieval methods
- `set_*()` - Mutation methods
- `add_*()` - Creation methods
- `insert_*()` - Insertion methods
- `extract_*()` - Extraction methods
- `delete_*()` - Deletion methods

---

## Implementation Phases

### Phase 0: Foundation & Build System (Week 1-2) ✅ COMPLETED

**Objective**: Get MuPDF building with Zig and establish project structure

**Deliverables**:
1. `build.zig` that compiles MuPDF from source
2. Basic project structure
3. Smoke test: open a PDF, get page count

**Tasks**:
- [x] Add MuPDF as git submodule in `.context/mupdf`
- [x] Create `build.zig` with C compilation
- [x] Handle MuPDF's third-party dependencies (freetype, zlib, libjpeg, etc.)
- [x] Create `src/c.zig` with `@cImport` of MuPDF headers
- [x] Implement basic `Context` wrapper
- [x] Write first test: open PDF, assert page count
- [x] Create C shim to handle bitfields and fz_try/fz_catch error handling
- [x] Implement `Document`, `Page`, `Pixmap`, `Rect` wrappers
- [x] 32 comprehensive unit tests passing

**Directory Structure**:
```
zig-mupdf/
├── build.zig              # Zig build system
├── build.zig.zon          # Package manifest
├── src/
│   ├── root.zig           # Public API exports
│   ├── c.zig              # @cImport bindings
│   ├── context.zig        # fz_context wrapper
│   └── ...
├── examples/
│   └── simple.zig
├── tests/
│   └── basic_test.zig
├── .context/
│   ├── mupdf/             # MuPDF submodule
│   └── PyMuPDF/           # Reference (not compiled)
└── README.md
```

---

### Phase 1: Core Document Operations (Week 3-4) ✅ COMPLETED

**Objective**: Basic document opening, page access, metadata

**Deliverables**:
1. `Document` struct with open/close/save
2. `Page` struct with basic properties
3. Metadata access
4. Memory buffer support (not just files)

**API Design**:

```zig
const mupdf = @import("zig-mupdf");

pub fn main() !void {
    // Initialize context (thread-safe via arena allocator)
    var ctx = try mupdf.Context.init(.{});
    defer ctx.deinit();

    // Open document from file
    var doc = try mupdf.Document.openFile(ctx, "input.pdf");
    defer doc.deinit();

    // Or from memory buffer
    // var doc = try mupdf.Document.openBuffer(ctx, buffer, "pdf");

    // Properties
    const page_count = doc.pageCount();
    const metadata = doc.getMetadata();
    
    // Load a page
    var page = try doc.loadPage(0);
    defer page.deinit();

    // Page properties
    const rect = page.bounds();
    const rotation = page.rotation();
}
```

---

### Phase 2: Rendering & Pixmaps (Week 5-6) ✅ COMPLETED (early, in Phase 0)

**Objective**: Render pages to images

**Deliverables**:
1. `Pixmap` struct with creation and export
2. `Matrix` for transformations
3. PNG/JPEG export
4. Render page to pixmap

**API Design**:

```zig
// Render page to pixmap
const matrix = mupdf.Matrix.scale(2.0, 2.0); // 2x zoom
var pixmap = try page.toPixmap(ctx, .{
    .matrix = matrix,
    .colorspace = .rgb,
    .alpha = false,
});
defer pixmap.deinit();

// Export
try pixmap.saveAsPng("output.png");
// Or get raw bytes
const png_bytes = try pixmap.toPng(allocator);
defer allocator.free(png_bytes);

// Direct pixel access
const width = pixmap.width();
const height = pixmap.height();
const samples = pixmap.samples(); // []u8 slice
```

---

### Phase 3: Text Extraction (Week 7-8) ✅ COMPLETED

**Objective**: Extract text from pages with position info

**Deliverables**:
1. `TextPage` with structured text access
2. Plain text extraction
3. Word/block-level extraction with bounding boxes
4. Search functionality

**API Design**:

```zig
// Simple text extraction
const text = try page.getText(.plain);
defer allocator.free(text);

// Structured extraction
var text_page = try page.getTextPage(.{
    .preserve_ligatures = true,
    .preserve_whitespace = true,
});
defer text_page.deinit();

// Iterate blocks
var block_iter = text_page.blocks();
while (block_iter.next()) |block| {
    switch (block.type) {
        .text => {
            for (block.lines()) |line| {
                for (line.chars()) |char| {
                    // char.unicode, char.origin, char.quad, char.font_size
                }
            }
        },
        .image => {
            // block.image_transform, block.image
        },
    }
}

// Search
const results = try page.search("needle", .{ .max_results = 100 });
for (results) |hit| {
    // hit.quads - quadrilateral covering the match
}
```

---

### Phase 4: Image Extraction (Week 9-10) ✅ COMPLETED

**Objective**: Extract embedded images from PDFs

**Deliverables**:
1. List images on a page
2. Extract image by reference (xref)
3. Get image metadata (dimensions, colorspace)

---

### Phase 5: PDF Manipulation (Week 11-13) ✅ COMPLETED

**Objective**: Modify PDFs (merge, split, pages)

**Deliverables**:
1. Insert/delete/reorder pages
2. Merge multiple PDFs
3. Save with options (compression, encryption)
4. Copy pages between documents

---

### Phase 6: Annotations & Links (Week 14-15) ✅ COMPLETED

**Objective**: Read and create annotations

**Deliverables**:
1. Iterate existing annotations
2. Create text/highlight/underline annotations
3. Read and create links
4. Redaction support

---

### Phase 7: Advanced Features (Week 16-18) ✅ COMPLETED

**Objective**: Forms, outlines (TOC), and advanced operations

**Deliverables**:
1. Table of Contents (outline) read/write
2. Form field reading (PDF forms)
3. Document structure/tagging
4. OCR integration (optional, via Tesseract)

---

### Phase 8: PDF Processing Server (Week 19-20)

**Objective**: Build a production-ready HTTP server for PDF operations

**API Endpoints**:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check |
| `/render` | POST | Render page(s) to image(s) |
| `/text` | POST | Extract text from PDF |
| `/merge` | POST | Merge multiple PDFs |
| `/split` | POST | Split PDF into pages |
| `/info` | POST | Get PDF metadata |
| `/search` | POST | Search text in PDF |

---

## Technical Considerations

### Thread Safety

MuPDF requires one `fz_context` per thread. The pattern:

```zig
pub const Context = struct {
    inner: *c.fz_context,
    
    // Clone context for use in another thread
    pub fn clone(self: *Context) !Context {
        const cloned = c.fz_clone_context(self.inner) orelse return error.OutOfMemory;
        return Context{ .inner = cloned };
    }
};
```

### Memory Management

1. **Arena Allocators**: Use for temporary operations
2. **Reference Counting**: Mirror MuPDF's `keep/drop` pattern
3. **Defer Pattern**: All resources cleaned up via `defer`

---

## Timeline Summary

| Phase | Duration | Key Deliverable |
|-------|----------|-----------------|
| Phase 0 | 2 weeks | Build system, basic smoke test |
| Phase 1 | 2 weeks | Document/Page basics, metadata |
| Phase 2 | 2 weeks | Rendering to images |
| Phase 3 | 2 weeks | Text extraction |
| Phase 4 | 2 weeks | Image extraction |
| Phase 5 | 3 weeks | PDF manipulation |
| Phase 6 | 2 weeks | Annotations & links |
| Phase 7 | 3 weeks | Advanced features |
| Phase 8 | 2 weeks | HTTP server |

**Total: ~20 weeks**

---

## Appendix A: MuPDF Header Organization

```
include/mupdf/
├── fitz.h              # Main header (includes all below)
├── fitz/
│   ├── context.h       # fz_context, memory, errors
│   ├── document.h      # fz_document, fz_page
│   ├── pixmap.h        # fz_pixmap, rendering
│   ├── geometry.h      # fz_rect, fz_matrix, fz_point
│   ├── structured-text.h # fz_stext_page, text extraction
│   ├── color.h         # fz_colorspace
│   ├── font.h          # fz_font
│   ├── image.h         # fz_image
│   ├── device.h        # fz_device (render target)
│   └── ...
├── pdf.h               # PDF-specific (includes all below)
└── pdf/
    ├── document.h      # pdf_document
    ├── page.h          # pdf_page
    ├── annot.h         # pdf_annot (annotations)
    ├── object.h        # pdf_obj (PDF objects)
    └── ...
```

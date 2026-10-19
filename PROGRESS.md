# zig-mupdf Progress Log

## Overall Status

| Phase | Status | Tests |
|-------|--------|-------|
| Phase 0: Foundation & Build System | **Complete** | 32 |
| Phase 1: Core Document Operations | **Complete** | 25+ |
| Phase 2: Rendering & Pixmaps | **Complete** (early, in Phase 0) | included above |
| Phase 3: Text Extraction & Search | **Complete** | 13 |
| Phase 4: Image Extraction | **Complete** | included in total |
| Phase 5: PDF Manipulation | **Complete** | included in total |
| Phase 6: Annotations & Links | **Complete** | included in total |
| Phase 7: Advanced Features (TOC, forms) | **Complete** | included in total |
| Phase 8: PDF Processing Server | **Partial**: `/health`, `/info`, `/text`, `/search`, `/render` done (multi-threaded, hardened); `/merge`, `/split` not implemented | - |
| Verification hardening (see `VERIFICATION.md`) | **Complete** | 10 new |

**Total tests passing: 109** (`zig build test --summary all`)

---

## Completed Phases

### Phase 0: Foundation & Build System

- MuPDF compiles from source via `build.zig` (all thirdparty deps included)
- C shim handles bitfields (`fz_font_flags_t`) and `fz_try/fz_catch` error handling
- Core wrappers: `Context`, `Document`, `Page`, `Pixmap`, `Rect`
- Error handling module with meaningful types
- Working example (`pdf_info.zig`)
- Test fixture PDF with metadata

**Key Technical Solutions:**
1. `fz_font` made opaque via C shim to avoid bitfield issues in `@cImport`
2. Safe C wrapper functions use `fz_try/fz_catch`, return NULL on error (avoids longjmp crash in Zig)
3. TOFU font mode to avoid HarfBuzz dependency

### Phase 1: Core Document Operations

**Metadata:**
- `MetadataKey` enum (format, title, author, subject, keywords, creator, producer, dates)
- `getMetadata()`, `getMetadataRaw()`, `getAllMetadata()` → `Metadata` struct
- `setMetadata()`, `setMetadataRaw()` for modification

**Saving:**
- `SaveOptions` struct (compress, garbage, linearize, incremental, clean, etc.)
- `save()`, `saveIncremental()` with safe C shim

**Page Rotation:**
- `Page.rotation()` → degrees (0, 90, 180, 270)
- Uses `pdf_dict_get_inheritable(page->obj, PDF_NAME(Rotate))` via C shim

**Matrix Wrapper:**
- `Matrix` struct wrapping `fz_matrix`
- Constructors: `identity`, `scale()`, `rotate()`, `translate()`, `shear()`
- Composition: `concat()`, `preScale()`, `preRotate()`, `preTranslate()`
- Utilities: `invert()`, `isRectilinear()`, `expansion()`, `transformPoint()`, `transformRect()`
- `toC()` / `fromC()` for C interop
- `Page.toPixmapWithMatrix(matrix)` for Matrix-based rendering

**Links Iteration:**
- `Link` struct (`rect: Rect`, `uri: []const u8`)
- `LinkIterator` walks the `fz_link` linked list
- `LinkList` (owned handle) from `Page.loadLinks()` with `deinit()`

### Phase 2: Rendering & Pixmaps (completed early)

Rendering was implemented during Phase 0:
- `Page.toPixmap(scale, rotation)` → `Pixmap`
- `Pixmap` with `width()`, `height()`, `components()`, `stride()`, `samples()`, `savePng()`

### Phase 3: Text Extraction & Search

**Build System Fix:**
- Removed `-DTOFU_BASE14` flag to enable Base14 fonts (Helvetica, Courier, Times)
- Generated C files from URW CFF fonts in `generated/fonts/` via `hexdump.sh`
- Added 14 generated font C files to `build.zig`

**Structured Text Extraction:**
- `TextPage` wrapping `fz_stext_page` with `deinit()`, `mediabox()`, `blocks()`, `getText()`
- `TextBlock` with `bbox`, `block_type` (.text/.image), `lines()` iterator
- `TextLine` with `bbox`, `wmode`, `chars()` iterator, `getText()` for line text
- `TextChar` with `codepoint`, `origin`, `quad`, `size`, `flags`, `argb`
- `TextBlockIterator`, `TextLineIterator`, `TextCharIterator` for linked-list traversal
- `TextOptions` (preserve_ligatures, preserve_whitespace, preserve_images, inhibit_spaces, dehyphenate)

**Plain Text Extraction:**
- `Page.getText(allocator)` — shorthand: extract + flatten to plain string
- `TextPage.getText(allocator)` — uses `fz_new_buffer_from_stext_page` for MuPDF-native flattening
- `TextLine.getText(allocator)` — collect chars into UTF-8 string

**Search:**
- `Page.search(needle, allocator)` → `[]SearchHit`
- `SearchHit` with `quad: Quad` and `mark: bool` (multi-line hit continuation)
- Uses `fz_search_page()` via safe C shim (handles fz_try/fz_catch)
- Supports up to 512 hit quads per search

**Supporting Types:**
- `Quad` (ul, ur, ll, lr Points) with `toRect()` for bounding box
- `Point` (x, y)

**C Shim Additions:**
- `mupdf_shim_new_stext_page()` — safe structured text extraction
- `mupdf_shim_stext_to_buffer()` — safe text-to-buffer conversion
- `mupdf_shim_search_page()` — safe page search

---

### Phase 4: Image Extraction

- `Page.getImages()` → `[]ImageInfo` (xref, size, bpc, components, colorspace, filter, name)
- `Page.loadImage(xref)` → `Image`, `Image.toPixmap()` for decoding/PNG export

### Phase 5: PDF Manipulation

- `Document.deletePage()`, `deletePageRange()`, `insertPageFrom()` (merge), `rearrangePages()`
- `Document.createPdf()` for new empty PDFs

### Phase 6: Annotations

- `Page.getAnnotations()` iterator, `Page.createAnnotation(type)`
- `Annotation` getters/setters (type, rect, contents, author, color, opacity, quad points), `update()`, `delete()`

### Phase 7: Advanced Features

- `Document.loadOutline()` → `Outline.toList()` (TOC entries with depth/page/URI)
- `Page.getWidgets()` → form field type, label, value, read-only flag, rect

### Verification hardening

See `VERIFICATION.md` for repro commands and before/after evidence:

- Every throwing MuPDF call now goes through an `fz_try` shim. `pageCount()`, `needsPassword()`, `authenticate()`, `Page.bounds()`, `width()` and `height()` return error unions.
- `Context.initThreadSafe()` (mutex-backed `fz_locks_context`), so `clone()` works.
- The server uses a worker pool, a poll-based request reader with timeouts and size limits, and per-worker contexts.
- Mutation fuzz loop (`zig build fuzz`), engine benchmark (`zig build bench-engine`), concurrency benchmark.
- `-Dsanitize-mupdf` build option (default off).

### Phase 8 (remaining)

- `/merge` and `/split` endpoints from PRD.md are not implemented yet.

## Project Structure

```
zig-mupdf/
├── build.zig              # Zig build system
├── build.zig.zon          # Package manifest
├── PRD.md                 # Product requirements (8-phase plan)
├── PROGRESS.md            # This file
├── generated/
│   └── fonts/             # Generated C files for Base14 font embedding
├── src/
│   ├── root.zig           # Public API exports
│   ├── c.zig              # @cImport bindings
│   ├── context.zig        # Context wrapper
│   ├── document.zig       # Document, Page, Pixmap, Rect, Matrix, Link, TextPage, etc.
│   ├── error.zig          # Error types
│   ├── mupdf_shim.h       # C shim header
│   └── mupdf_shim.c       # C shim implementation
├── examples/
│   └── pdf_info.zig       # Working example
├── tests/
│   └── fixtures/
│       ├── sample.pdf     # Test PDF with metadata (no text)
│       └── text_sample.pdf # Test PDF with text content
└── .context/
    ├── mupdf/             # MuPDF C library (submodule)
    └── PyMuPDF/           # API reference (submodule)
```

## Build & Test

```bash
zig build          # Build the library
zig build test     # Run all tests (109 tests)
zig build run-pdf-info -- path/to/file.pdf  # Run example
```

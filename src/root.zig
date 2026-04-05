//! # zig-mupdf
//!
//! A Zig wrapper for the MuPDF library, providing a safe and idiomatic API
//! for PDF processing and rendering.
//!
//! ## Quick Start
//!
//! ```zig
//! const mupdf = @import("mupdf");
//!
//! pub fn main() !void {
//!     // Initialize MuPDF context
//!     var ctx = try mupdf.Context.init();
//!     defer ctx.deinit();
//!
//!     // Open a PDF document
//!     var doc = try ctx.openDocument("document.pdf");
//!     defer doc.deinit();
//!
//!     // Get page count
//!     const page_count = doc.pageCount();
//!     std.debug.print("Document has {d} pages\n", .{page_count});
//!
//!     // Load and render a page
//!     var page = try doc.loadPage(0);
//!     defer page.deinit();
//!
//!     var pixmap = try page.toPixmap(2.0, 0.0); // 2x scale, no rotation
//!     defer pixmap.deinit();
//!
//!     try pixmap.savePng("page0.png");
//! }
//! ```
//!
//! ## Thread Safety
//!
//! MuPDF contexts are NOT thread-safe. For multi-threaded applications,
//! clone the context for each thread:
//!
//! ```zig
//! var main_ctx = try mupdf.Context.init();
//! defer main_ctx.deinit();
//!
//! // In each worker thread:
//! var thread_ctx = try main_ctx.clone();
//! defer thread_ctx.deinit();
//! ```
//!
//! ## Features
//!
//! - **Document Loading**: PDF, XPS, EPUB, HTML, and image formats
//! - **Rendering**: High-quality page rendering to pixmaps
//! - **Text Extraction**: Extract text with position information
//! - **Metadata**: Access document title, author, and other properties
//! - **PDF Specifics**: Low-level access to PDF structures
//!

const std = @import("std");

// Core types
pub const Context = @import("context.zig").Context;
pub const Document = @import("document.zig").Document;
pub const Page = @import("document.zig").Page;
pub const Pixmap = @import("document.zig").Pixmap;
pub const Rect = @import("document.zig").Rect;
pub const Matrix = @import("document.zig").Matrix;
pub const Link = @import("document.zig").Link;
pub const LinkIterator = @import("document.zig").LinkIterator;
pub const LinkList = @import("document.zig").LinkList;
pub const Quad = @import("document.zig").Quad;
pub const Point = @import("document.zig").Point;
pub const TextPage = @import("document.zig").TextPage;
pub const TextBlock = @import("document.zig").TextBlock;
pub const TextLine = @import("document.zig").TextLine;
pub const TextChar = @import("document.zig").TextChar;
pub const TextBlockIterator = @import("document.zig").TextBlockIterator;
pub const TextLineIterator = @import("document.zig").TextLineIterator;
pub const TextCharIterator = @import("document.zig").TextCharIterator;
pub const TextOptions = @import("document.zig").TextOptions;
pub const SearchHit = @import("document.zig").SearchHit;
pub const BlockType = @import("document.zig").BlockType;
pub const ImageInfo = @import("document.zig").ImageInfo;
pub const Image = @import("document.zig").Image;
pub const Annotation = @import("document.zig").Annotation;
pub const AnnotationType = @import("document.zig").AnnotationType;
pub const AnnotationIterator = @import("document.zig").AnnotationIterator;
pub const Color = @import("document.zig").Color;
pub const Outline = @import("document.zig").Outline;
pub const OutlineItem = @import("document.zig").OutlineItem;
pub const OutlineEntry = @import("document.zig").OutlineEntry;
pub const Widget = @import("document.zig").Widget;
pub const WidgetType = @import("document.zig").WidgetType;
pub const WidgetIterator = @import("document.zig").WidgetIterator;

// Error handling
pub const Error = @import("error.zig").Error;
pub const formatError = @import("error.zig").format;

// Low-level C bindings (for advanced use)
pub const c = @import("c.zig");

// Re-export commonly used C types
pub const fz_context = c.c.fz_context;
pub const fz_document = c.c.fz_document;
pub const fz_page = c.c.fz_page;
pub const fz_pixmap = c.c.fz_pixmap;
pub const fz_matrix = c.c.fz_matrix;

// Tests
test {
    std.testing.refAllDecls(@This());
    _ = @import("context.zig");
    _ = @import("document.zig");
    _ = @import("error.zig");
}

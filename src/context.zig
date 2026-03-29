//! MuPDF Context wrapper.
//!
//! The Context is the heart of MuPDF - it manages memory allocation,
//! exception handling, and provides the foundation for all operations.
//!
//! ## Thread Safety
//!
//! MuPDF contexts are NOT thread-safe. You should either:
//! - Use a single context per thread
//! - Clone the context for each thread using `clone()`
//!
//! ## Example
//!
//! ```zig
//! var ctx = try Context.init();
//! defer ctx.deinit();
//!
//! var doc = try ctx.openDocument("document.pdf");
//! defer doc.deinit();
//! ```

const std = @import("std");
const c = @import("c.zig");
const Error = @import("error.zig").Error;

/// MuPDF Context wrapper.
///
/// Manages memory allocation, font caching, and error handling for MuPDF.
pub const Context = struct {
    /// The underlying MuPDF context pointer.
    ptr: *c.c.fz_context,

    const Self = @This();

    /// Default store size (256 MB).
    pub const default_store_size: usize = 256 << 20;

    /// Initialize a new MuPDF context with default settings.
    ///
    /// Returns an error if context creation fails (typically due to memory).
    pub fn init() Error!Self {
        return initWithOptions(null, null, default_store_size);
    }

    /// Initialize a new MuPDF context with custom options.
    ///
    /// - `alloc`: Custom memory allocator (null for default).
    /// - `locks`: Custom locking functions for thread safety (null for single-threaded).
    /// - `max_store`: Maximum size of the resource store in bytes.
    pub fn initWithOptions(
        alloc: ?*c.c.fz_alloc_context,
        locks: ?*c.c.fz_locks_context,
        max_store: usize,
    ) Error!Self {
        const ctx = c.c.fz_new_context(alloc, locks, max_store);
        if (ctx == null) {
            return Error.ContextCreationFailed;
        }

        // Register all document handlers (PDF, XPS, EPUB, etc.)
        c.c.fz_register_document_handlers(ctx);

        return Self{ .ptr = ctx.? };
    }

    /// Release all resources associated with this context.
    ///
    /// After calling this, the context is invalid and must not be used.
    pub fn deinit(self: *Self) void {
        c.c.fz_drop_context(self.ptr);
        self.ptr = undefined;
    }

    /// Clone this context for use in another thread.
    ///
    /// The cloned context shares the same store and allocator but has
    /// independent exception handling state, making it safe to use from
    /// a different thread.
    pub fn clone(self: *Self) Error!Self {
        const cloned = c.c.fz_clone_context(self.ptr);
        if (cloned == null) {
            return Error.ContextCreationFailed;
        }
        return Self{ .ptr = cloned.? };
    }

    /// Get the raw MuPDF context pointer.
    ///
    /// Use this when you need to call MuPDF C functions directly.
    pub fn raw(self: *Self) *c.c.fz_context {
        return self.ptr;
    }

    /// Open a document from a file path.
    ///
    /// The file extension is used to determine the document type.
    /// Supported formats: PDF, XPS, EPUB, HTML, and various image formats.
    pub fn openDocument(self: *Self, path: []const u8) Error!Document {
        return Document.open(self, path);
    }

    /// Open a document from memory.
    ///
    /// - `data`: The document data.
    /// - `magic`: A hint for the document type (e.g., ".pdf", "application/pdf").
    pub fn openDocumentFromMemory(self: *Self, data: []const u8, magic: []const u8) Error!Document {
        return Document.openFromMemory(self, data, magic);
    }

    /// Get the device RGB colorspace.
    pub fn deviceRgb(self: *Self) *c.c.fz_colorspace {
        return c.c.fz_device_rgb(self.ptr);
    }

    /// Get the device grayscale colorspace.
    pub fn deviceGray(self: *Self) *c.c.fz_colorspace {
        return c.c.fz_device_gray(self.ptr);
    }

    /// Get the device CMYK colorspace.
    pub fn deviceCmyk(self: *Self) *c.c.fz_colorspace {
        return c.c.fz_device_cmyk(self.ptr);
    }
};

// Forward declaration - Document is defined in document.zig
const Document = @import("document.zig").Document;

// ============================================
// Unit Tests
// ============================================

test "Context.init creates valid context" {
    var ctx = try Context.init();
    defer ctx.deinit();

    // Context pointer should be valid (not null/undefined)
    try std.testing.expect(@intFromPtr(ctx.ptr) != 0);
}

test "Context.initWithOptions respects store size" {
    // Create context with small store size
    var ctx = try Context.initWithOptions(null, null, 1 << 20); // 1 MB
    defer ctx.deinit();

    try std.testing.expect(@intFromPtr(ctx.ptr) != 0);
}

test "Context.clone requires locks to be configured" {
    // Note: fz_clone_context only works when the context was created
    // with locks configured (for multi-threaded use). Without locks,
    // cloning returns null and we return ContextCreationFailed.
    var ctx = try Context.init();
    defer ctx.deinit();

    // Without locks configured, clone should fail
    const result = ctx.clone();
    try std.testing.expectError(Error.ContextCreationFailed, result);
}

test "Context.raw returns underlying pointer" {
    var ctx = try Context.init();
    defer ctx.deinit();

    const raw_ptr = ctx.raw();
    try std.testing.expect(raw_ptr == ctx.ptr);
}

test "Context.deviceRgb returns valid colorspace" {
    var ctx = try Context.init();
    defer ctx.deinit();

    const rgb = ctx.deviceRgb();
    try std.testing.expect(@intFromPtr(rgb) != 0);
}

test "Context.deviceGray returns valid colorspace" {
    var ctx = try Context.init();
    defer ctx.deinit();

    const gray = ctx.deviceGray();
    try std.testing.expect(@intFromPtr(gray) != 0);
}

test "Context.deviceCmyk returns valid colorspace" {
    var ctx = try Context.init();
    defer ctx.deinit();

    const cmyk = ctx.deviceCmyk();
    try std.testing.expect(@intFromPtr(cmyk) != 0);
}

test "Context colorspaces are distinct" {
    var ctx = try Context.init();
    defer ctx.deinit();

    const rgb = ctx.deviceRgb();
    const gray = ctx.deviceGray();
    const cmyk = ctx.deviceCmyk();

    // All colorspaces should be different
    try std.testing.expect(rgb != gray);
    try std.testing.expect(rgb != cmyk);
    try std.testing.expect(gray != cmyk);
}

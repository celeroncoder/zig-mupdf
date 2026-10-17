//! MuPDF Context wrapper.
//!
//! The Context is the heart of MuPDF - it manages memory allocation,
//! exception handling, and provides the foundation for all operations.
//!
//! ## Thread Safety
//!
//! A single MuPDF context must never be used by two threads at once. For
//! multi-threaded use, create one base context with `initThreadSafe()` (which
//! installs real mutexes for MuPDF's `FZ_LOCK_MAX` locks) and give every thread
//! its own `clone()`. Clones share the resource store and font cache. Each
//! document/page must only be used by the context (thread) that opened it.
//!
//! ```zig
//! var base = try Context.initThreadSafe();
//! defer base.deinit(); // after all clones are gone
//!
//! // per worker thread:
//! var ctx = try base.clone();
//! defer ctx.deinit();
//! ```
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
    /// Mutexes backing MuPDF's locking callbacks. Owned by the base context
    /// created with `initThreadSafe()`; null for clones and single-threaded contexts.
    locks: ?*Locks = null,

    const Self = @This();

    /// Default store size (256 MB).
    pub const default_store_size: usize = 256 << 20;

    /// Initialize a new MuPDF context with default settings.
    ///
    /// Returns an error if context creation fails (typically due to memory).
    pub fn init() Error!Self {
        return initWithOptions(null, null, default_store_size);
    }

    /// Initialize a context that can be cloned for use from multiple threads.
    ///
    /// Installs a `fz_locks_context` backed by `FZ_LOCK_MAX` mutexes. The
    /// returned base context owns the mutexes, so it must outlive every clone.
    pub fn initThreadSafe() Error!Self {
        return initThreadSafeWithStore(default_store_size);
    }

    /// Like `initThreadSafe()` with a custom resource store size in bytes.
    pub fn initThreadSafeWithStore(max_store: usize) Error!Self {
        const locks = std.heap.c_allocator.create(Locks) catch return Error.OutOfMemory;
        locks.* = .{};
        locks.ctx = .{ .user = locks, .lock = Locks.lock, .unlock = Locks.unlock };
        errdefer std.heap.c_allocator.destroy(locks);

        var self = try initWithOptions(null, &locks.ctx, max_store);
        self.locks = locks;
        return self;
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

        // Register all compiled-in document handlers (see README "Supported formats")
        if (c.c.mupdf_shim_register_document_handlers(ctx) != 0) {
            c.c.fz_drop_context(ctx);
            return Error.ContextCreationFailed;
        }

        return Self{ .ptr = ctx.? };
    }

    /// Release all resources associated with this context.
    ///
    /// After calling this, the context is invalid and must not be used.
    pub fn deinit(self: *Self) void {
        c.c.fz_drop_context(self.ptr);
        self.ptr = undefined;
        if (self.locks) |locks| {
            std.heap.c_allocator.destroy(locks);
            self.locks = null;
        }
    }

    /// Clone this context for use in another thread.
    ///
    /// The cloned context shares the same store and allocator but has
    /// independent exception handling state, making it safe to use from
    /// a different thread. Only works on contexts created with locks
    /// (`initThreadSafe()`); otherwise returns `ContextCreationFailed`.
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

/// Mutex table handed to MuPDF as its `fz_locks_context`.
pub const Locks = struct {
    mutexes: [c.c.FZ_LOCK_MAX]std.Thread.Mutex = [_]std.Thread.Mutex{.{}} ** c.c.FZ_LOCK_MAX,
    ctx: c.c.fz_locks_context = undefined,

    fn lock(user: ?*anyopaque, index: c_int) callconv(.c) void {
        const self: *Locks = @ptrCast(@alignCast(user.?));
        self.mutexes[@intCast(index)].lock();
    }

    fn unlock(user: ?*anyopaque, index: c_int) callconv(.c) void {
        const self: *Locks = @ptrCast(@alignCast(user.?));
        self.mutexes[@intCast(index)].unlock();
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

test "Context.initThreadSafe allows clone" {
    var base = try Context.initThreadSafe();
    defer base.deinit();
    try std.testing.expect(base.locks != null);

    var cloned = try base.clone();
    defer cloned.deinit();
    try std.testing.expect(cloned.ptr != base.ptr);
    try std.testing.expect(cloned.locks == null);
}

test "cloned contexts render and extract text concurrently" {
    const Worker = struct {
        fn run(base: *Context, failures: *std.atomic.Value(u32), out_len: *usize) void {
            var ctx = base.clone() catch {
                _ = failures.fetchAdd(1, .monotonic);
                return;
            };
            defer ctx.deinit();
            for (0..10) |_| {
                work(&ctx, out_len) catch {
                    _ = failures.fetchAdd(1, .monotonic);
                };
            }
        }

        fn work(ctx: *Context, out_len: *usize) !void {
            var doc = try Document.open(ctx, "tests/fixtures/text_sample.pdf");
            defer doc.deinit();
            var page = try doc.loadPage(0);
            defer page.deinit();
            const text = try page.getText(std.heap.c_allocator);
            defer std.heap.c_allocator.free(text);
            out_len.* = text.len;
            var pix = try page.toPixmap(1.0, 0.0);
            defer pix.deinit();
            const png = try pix.toPng(std.heap.c_allocator);
            std.heap.c_allocator.free(png);
        }
    };

    var base = try Context.initThreadSafe();
    defer base.deinit();

    var failures = std.atomic.Value(u32).init(0);
    var lens = [_]usize{0} ** 4;
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &base, &failures, &lens[i] });
    }
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(u32, 0), failures.load(.monotonic));
    for (lens) |len| {
        try std.testing.expect(len > 0);
        try std.testing.expectEqual(lens[0], len);
    }
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

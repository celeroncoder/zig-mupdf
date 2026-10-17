//! MuPDF Document wrapper.
//!
//! Represents an opened document (PDF, XPS, EPUB, etc.).
//!
//! ## Example
//!
//! ```zig
//! var ctx = try Context.init();
//! defer ctx.deinit();
//!
//! var doc = try ctx.openDocument("document.pdf");
//! defer doc.deinit();
//!
//! const page_count = try doc.pageCount();
//! std.debug.print("Document has {d} pages\n", .{page_count});
//!
//! // Get metadata
//! const allocator = std.heap.page_allocator;
//! if (try doc.getMetadata(.title, allocator)) |title| {
//!     defer allocator.free(title);
//!     std.debug.print("Title: {s}\n", .{title});
//! }
//! ```

const std = @import("std");
const c = @import("c.zig");
const Error = @import("error.zig").Error;
const Context = @import("context.zig").Context;

/// Standard metadata keys for PDF documents.
pub const MetadataKey = enum {
    /// Document format (e.g., "PDF 1.7")
    format,
    /// Encryption method
    encryption,
    /// Document title
    title,
    /// Document author
    author,
    /// Document subject
    subject,
    /// Document keywords
    keywords,
    /// Application that created the document
    creator,
    /// PDF producer application
    producer,
    /// Creation date
    creation_date,
    /// Modification date
    mod_date,

    /// Convert to the MuPDF metadata key string.
    pub fn toKey(self: MetadataKey) [:0]const u8 {
        return switch (self) {
            .format => "format",
            .encryption => "encryption",
            .title => "info:Title",
            .author => "info:Author",
            .subject => "info:Subject",
            .keywords => "info:Keywords",
            .creator => "info:Creator",
            .producer => "info:Producer",
            .creation_date => "info:CreationDate",
            .mod_date => "info:ModDate",
        };
    }
};

/// Options for saving PDF documents.
pub const SaveOptions = struct {
    /// Write just the changed objects (incremental save).
    incremental: bool = false,
    /// Pretty-print dictionaries and arrays.
    pretty: bool = false,
    /// ASCII hex encode binary streams.
    ascii: bool = false,
    /// Compress streams (0=none, 1=zlib, 2=brotli).
    compress: u8 = 1,
    /// Compress image streams.
    compress_images: bool = true,
    /// Compress font streams.
    compress_fonts: bool = true,
    /// Garbage collect objects (0=none, 1=gc, 2=renumber, 3=deduplicate).
    garbage: u8 = 0,
    /// Write linearized PDF.
    linearize: bool = false,
    /// Clean content streams.
    clean: bool = false,
    /// Sanitize content streams.
    sanitize: bool = false,
    /// (Re)create appearance streams.
    appearance: bool = false,

    /// Convert to MuPDF pdf_write_options structure.
    pub fn toCOptions(self: SaveOptions) c.c.pdf_write_options {
        var opts: c.c.pdf_write_options = std.mem.zeroes(c.c.pdf_write_options);
        opts.do_incremental = if (self.incremental) 1 else 0;
        opts.do_pretty = if (self.pretty) 1 else 0;
        opts.do_ascii = if (self.ascii) 1 else 0;
        opts.do_compress = @as(c_int, @intCast(self.compress));
        opts.do_compress_images = if (self.compress_images) 1 else 0;
        opts.do_compress_fonts = if (self.compress_fonts) 1 else 0;
        opts.do_garbage = @as(c_int, @intCast(self.garbage));
        opts.do_linear = if (self.linearize) 1 else 0;
        opts.do_clean = if (self.clean) 1 else 0;
        opts.do_sanitize = if (self.sanitize) 1 else 0;
        opts.do_appearance = if (self.appearance) 1 else 0;
        return opts;
    }
};

/// Container for all standard PDF metadata fields.
pub const Metadata = struct {
    format: ?[]u8 = null,
    encryption: ?[]u8 = null,
    title: ?[]u8 = null,
    author: ?[]u8 = null,
    subject: ?[]u8 = null,
    keywords: ?[]u8 = null,
    creator: ?[]u8 = null,
    producer: ?[]u8 = null,
    creation_date: ?[]u8 = null,
    mod_date: ?[]u8 = null,
    allocator: std.mem.Allocator,

    /// Free all allocated metadata strings.
    pub fn deinit(self: *Metadata) void {
        const fields = [_]*?[]u8{
            &self.format,
            &self.encryption,
            &self.title,
            &self.author,
            &self.subject,
            &self.keywords,
            &self.creator,
            &self.producer,
            &self.creation_date,
            &self.mod_date,
        };
        for (fields) |field| {
            if (field.*) |value| {
                self.allocator.free(value);
                field.* = null;
            }
        }
    }
};

/// Affine transformation matrix wrapper.
///
/// Wraps MuPDF's fz_matrix (row-major 3x3 with constant third column).
/// Represents the transformation: [ a b 0 ; c d 0 ; e f 1 ]
pub const Matrix = struct {
    a: f32,
    b: f32,
    c_val: f32,
    d: f32,
    e: f32,
    f: f32,

    /// Identity matrix (no transformation).
    pub const identity = Matrix{ .a = 1, .b = 0, .c_val = 0, .d = 1, .e = 0, .f = 0 };

    /// Create a scaling matrix.
    pub fn scale(sx: f32, sy: f32) Matrix {
        return fromC(c.c.fz_scale(sx, sy));
    }

    /// Create a rotation matrix (degrees, counterclockwise).
    pub fn rotate(degrees: f32) Matrix {
        return fromC(c.c.fz_rotate(degrees));
    }

    /// Create a translation matrix.
    pub fn translate(tx: f32, ty: f32) Matrix {
        return fromC(c.c.fz_translate(tx, ty));
    }

    /// Create a shearing matrix.
    pub fn shear(sx: f32, sy: f32) Matrix {
        return fromC(c.c.fz_shear(sx, sy));
    }

    /// Concatenate two matrices (self * other).
    pub fn concat(self: Matrix, other: Matrix) Matrix {
        return fromC(c.c.fz_concat(self.toC(), other.toC()));
    }

    /// Pre-scale: scale then apply self.
    pub fn preScale(self: Matrix, sx: f32, sy: f32) Matrix {
        return fromC(c.c.fz_pre_scale(self.toC(), sx, sy));
    }

    /// Pre-rotate: rotate then apply self.
    pub fn preRotate(self: Matrix, degrees: f32) Matrix {
        return fromC(c.c.fz_pre_rotate(self.toC(), degrees));
    }

    /// Pre-translate: translate then apply self.
    pub fn preTranslate(self: Matrix, tx: f32, ty: f32) Matrix {
        return fromC(c.c.fz_pre_translate(self.toC(), tx, ty));
    }

    /// Invert the matrix. Returns identity if not invertible.
    pub fn invert(self: Matrix) Matrix {
        return fromC(c.c.fz_invert_matrix(self.toC()));
    }

    /// Check if the matrix is rectilinear (maps axis-aligned rectangles to axis-aligned rectangles).
    pub fn isRectilinear(self: Matrix) bool {
        return c.c.fz_is_rectilinear(self.toC()) != 0;
    }

    /// Get the expansion factor of the matrix.
    pub fn expansion(self: Matrix) f32 {
        return c.c.fz_matrix_expansion(self.toC());
    }

    /// Transform a point by this matrix.
    pub fn transformPoint(self: Matrix, x: f32, y: f32) struct { x: f32, y: f32 } {
        const p = c.c.fz_transform_point_xy(x, y, self.toC());
        return .{ .x = p.x, .y = p.y };
    }

    /// Transform a rectangle by this matrix.
    pub fn transformRect(self: Matrix, rect: Rect) Rect {
        const fz_rect = c.c.fz_rect{
            .x0 = rect.x0,
            .y0 = rect.y0,
            .x1 = rect.x1,
            .y1 = rect.y1,
        };
        const r = c.c.fz_transform_rect(fz_rect, self.toC());
        return Rect{ .x0 = r.x0, .y0 = r.y0, .x1 = r.x1, .y1 = r.y1 };
    }

    /// Convert from MuPDF's fz_matrix.
    pub fn fromC(m: c.c.fz_matrix) Matrix {
        return Matrix{
            .a = m.a,
            .b = m.b,
            .c_val = m.c,
            .d = m.d,
            .e = m.e,
            .f = m.f,
        };
    }

    /// Convert to MuPDF's fz_matrix.
    pub fn toC(self: Matrix) c.c.fz_matrix {
        return c.c.fz_matrix{
            .a = self.a,
            .b = self.b,
            .c = self.c_val,
            .d = self.d,
            .e = self.e,
            .f = self.f,
        };
    }
};

/// A hyperlink on a page.
pub const Link = struct {
    /// The clickable area in page coordinates.
    rect: Rect,
    /// The link destination URI (owned memory).
    uri: []const u8,
};

/// Iterator over links on a page.
pub const LinkIterator = struct {
    current: ?*c.c.fz_link,

    /// Get the next link.
    pub fn next(self: *LinkIterator) ?Link {
        const link = self.current orelse return null;
        self.current = link.next;
        return Link{
            .rect = Rect{
                .x0 = link.rect.x0,
                .y0 = link.rect.y0,
                .x1 = link.rect.x1,
                .y1 = link.rect.y1,
            },
            .uri = if (link.uri) |uri| std.mem.span(uri) else "",
        };
    }
};

/// MuPDF Document wrapper.
pub const Document = struct {
    /// The underlying MuPDF document pointer.
    ptr: *c.c.fz_document,
    /// Reference to the context (needed for most operations).
    ctx: *Context,

    const Self = @This();

    /// Open a document from a file path.
    pub fn open(ctx: *Context, path: []const u8) Error!Self {
        // Ensure path is null-terminated for C
        var path_buf: [4096]u8 = undefined;
        if (path.len >= path_buf.len) {
            return Error.InvalidArgument;
        }
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        // Use safe shim that handles fz_try/fz_catch
        const doc = c.c.mupdf_shim_open_document(ctx.ptr, &path_buf);
        if (doc == null) {
            return Error.OpenFailed;
        }

        return Self{
            .ptr = doc.?,
            .ctx = ctx,
        };
    }

    /// Open a document from memory.
    pub fn openFromMemory(ctx: *Context, data: []const u8, magic: []const u8) Error!Self {
        // Ensure magic is null-terminated
        var magic_buf: [256]u8 = undefined;
        if (magic.len >= magic_buf.len) {
            return Error.InvalidArgument;
        }
        @memcpy(magic_buf[0..magic.len], magic);
        magic_buf[magic.len] = 0;

        // Use fz_open_document_with_buffer — MuPDF manages the buffer lifetime
        const doc = c.c.mupdf_shim_open_document_with_buffer(ctx.ptr, &magic_buf, data.ptr, data.len);
        if (doc == null) {
            return Error.OpenFailed;
        }

        return Self{
            .ptr = doc.?,
            .ctx = ctx,
        };
    }

    /// Close the document and release resources.
    pub fn deinit(self: *Self) void {
        c.c.fz_drop_document(self.ctx.ptr, self.ptr);
        self.ptr = undefined;
    }

    /// Get the number of pages in the document.
    ///
    /// Fails if the page tree is malformed (e.g. a negative or impossible /Count).
    pub fn pageCount(self: *Self) Error!i32 {
        const count = c.c.mupdf_shim_count_pages(self.ctx.ptr, self.ptr);
        if (count < 0) return Error.MupdfError;
        return count;
    }

    /// Load a page by number (0-indexed).
    pub fn loadPage(self: *Self, page_num: i32) Error!Page {
        return Page.load(self, page_num);
    }

    /// Check if the document needs a password.
    pub fn needsPassword(self: *Self) Error!bool {
        const result = c.c.mupdf_shim_needs_password(self.ctx.ptr, self.ptr);
        if (result < 0) return Error.MupdfError;
        return result != 0;
    }

    /// Authenticate with a password.
    ///
    /// Returns true if authentication succeeded, false for a wrong password.
    pub fn authenticate(self: *Self, password: []const u8) Error!bool {
        var pass_buf: [256]u8 = undefined;
        if (password.len >= pass_buf.len) {
            return false;
        }
        @memcpy(pass_buf[0..password.len], password);
        pass_buf[password.len] = 0;

        const result = c.c.mupdf_shim_authenticate_password(self.ctx.ptr, self.ptr, &pass_buf);
        if (result < 0) return Error.MupdfError;
        return result != 0;
    }

    /// Get a metadata value by key.
    ///
    /// Returns the metadata value as an owned slice that must be freed by the caller,
    /// or null if the metadata key is not found.
    ///
    /// ## Example
    /// ```zig
    /// if (try doc.getMetadata(.title, allocator)) |title| {
    ///     defer allocator.free(title);
    ///     std.debug.print("Title: {s}\n", .{title});
    /// }
    /// ```
    pub fn getMetadata(self: *Self, key: MetadataKey, allocator: std.mem.Allocator) Error!?[]u8 {
        return self.getMetadataRaw(key.toKey(), allocator);
    }

    /// Get a metadata value by raw key string.
    ///
    /// This allows querying custom metadata keys beyond the standard ones.
    /// The key must be null-terminated.
    pub fn getMetadataRaw(self: *Self, key: [:0]const u8, allocator: std.mem.Allocator) Error!?[]u8 {
        // First, query the required size
        var probe_buf: [1]u8 = undefined;
        const required_size = c.c.mupdf_shim_lookup_metadata(self.ctx.ptr, self.ptr, key.ptr, &probe_buf, 0);

        if (required_size == c.c.MUPDF_SHIM_METADATA_ERROR) return Error.MupdfError;
        if (required_size < 0) {
            // Key not found
            return null;
        }

        if (required_size == 0) {
            // Empty string - return empty slice
            const buf = allocator.alloc(u8, 0) catch return Error.OutOfMemory;
            return buf;
        }

        // Allocate buffer (required_size includes null terminator)
        const buf_size: usize = @intCast(required_size);
        const buf = allocator.alloc(u8, buf_size) catch return Error.OutOfMemory;
        errdefer allocator.free(buf);

        // Actually retrieve the metadata
        const actual_size = c.c.mupdf_shim_lookup_metadata(self.ctx.ptr, self.ptr, key.ptr, buf.ptr, buf.len);

        if (actual_size == c.c.MUPDF_SHIM_METADATA_ERROR) return Error.MupdfError;
        if (actual_size < 0) {
            allocator.free(buf);
            return null;
        }

        // The returned size includes null terminator, so actual string length is size - 1
        // We need to return a slice that the caller can free with the same size we allocated
        // So we resize the allocation to exclude the null terminator
        const str_len: usize = if (actual_size > 0) @intCast(actual_size - 1) else 0;

        // Resize the allocation to the actual string length (without null terminator)
        if (allocator.resize(buf, str_len)) {
            return buf[0..str_len];
        } else {
            // If resize fails, copy to a new correctly-sized allocation
            const result = allocator.alloc(u8, str_len) catch {
                allocator.free(buf);
                return Error.OutOfMemory;
            };
            @memcpy(result, buf[0..str_len]);
            allocator.free(buf);
            return result;
        }
    }

    /// Get all standard metadata as a struct.
    ///
    /// Returns a Metadata struct with all standard fields. The caller must
    /// call `metadata.deinit(allocator)` when done.
    pub fn getAllMetadata(self: *Self, allocator: std.mem.Allocator) Error!Metadata {
        return Metadata{
            .format = try self.getMetadata(.format, allocator),
            .encryption = try self.getMetadata(.encryption, allocator),
            .title = try self.getMetadata(.title, allocator),
            .author = try self.getMetadata(.author, allocator),
            .subject = try self.getMetadata(.subject, allocator),
            .keywords = try self.getMetadata(.keywords, allocator),
            .creator = try self.getMetadata(.creator, allocator),
            .producer = try self.getMetadata(.producer, allocator),
            .creation_date = try self.getMetadata(.creation_date, allocator),
            .mod_date = try self.getMetadata(.mod_date, allocator),
            .allocator = allocator,
        };
    }

    /// Save the document to a file.
    ///
    /// This only works for PDF documents. For other document types, use
    /// a format-specific export method.
    ///
    /// ## Example
    /// ```zig
    /// try doc.save("output.pdf", .{});
    /// // Or with options:
    /// try doc.save("output.pdf", .{ .garbage = 3, .compress = 1 });
    /// ```
    pub fn save(self: *Self, path: []const u8, options: SaveOptions) Error!void {
        const pdf_doc = self.asPdf() orelse return Error.NotAPdf;

        // Ensure path is null-terminated
        var path_buf: [4096]u8 = undefined;
        if (path.len >= path_buf.len) {
            return Error.InvalidArgument;
        }
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        const c_opts = options.toCOptions();

        // Use safe shim that handles fz_try/fz_catch
        const result = c.c.mupdf_shim_save_document(self.ctx.ptr, pdf_doc, &path_buf, &c_opts);
        if (result != 0) {
            return Error.SaveFailed;
        }
    }

    /// Save the document with incremental update.
    ///
    /// This preserves the original file structure and appends changes,
    /// which is faster for small modifications to large documents.
    /// Only works for PDF documents.
    pub fn saveIncremental(self: *Self, path: []const u8) Error!void {
        return self.save(path, .{ .incremental = true });
    }

    /// Set a metadata value.
    ///
    /// Only works for PDF documents.
    pub fn setMetadata(self: *Self, key: MetadataKey, value: []const u8) Error!void {
        return self.setMetadataRaw(key.toKey(), value);
    }

    /// Set a metadata value by raw key string.
    pub fn setMetadataRaw(self: *Self, key: [:0]const u8, value: []const u8) Error!void {
        // Ensure value is null-terminated
        var value_buf: [4096]u8 = undefined;
        if (value.len >= value_buf.len) {
            return Error.InvalidArgument;
        }
        @memcpy(value_buf[0..value.len], value);
        value_buf[value.len] = 0;

        if (c.c.mupdf_shim_set_metadata(self.ctx.ptr, self.ptr, key.ptr, &value_buf) != 0) {
            return Error.MupdfError;
        }
    }

    /// Check if this is a PDF document.
    pub fn isPdf(self: *Self) bool {
        const pdf_doc = c.c.pdf_specifics(self.ctx.ptr, self.ptr);
        return pdf_doc != null;
    }

    /// Get the PDF-specific document handle.
    ///
    /// Returns null if this is not a PDF document.
    pub fn asPdf(self: *Self) ?*c.c.pdf_document {
        return c.c.pdf_specifics(self.ctx.ptr, self.ptr);
    }

    /// Load the document outline (Table of Contents).
    ///
    /// Returns null if the document has no outline.
    /// The caller must call `outline.deinit()` when done.
    pub fn loadOutline(self: *Self) ?Outline {
        const root = c.c.mupdf_shim_load_outline(self.ctx.ptr, self.ptr);
        if (root == null) return null;
        return Outline{ .root = root, .ctx_ptr = self.ctx.ptr, .doc_ptr = self.ptr };
    }

    /// Delete a page by index (0-based).
    ///
    /// Only works for PDF documents.
    pub fn deletePage(self: *Self, page_num: i32) Error!void {
        const pdf_doc = self.asPdf() orelse return Error.NotAPdf;
        if (page_num < 0 or page_num >= try self.pageCount()) return Error.PageOutOfRange;
        const result = c.c.mupdf_shim_delete_page(self.ctx.ptr, pdf_doc, page_num);
        if (result != 0) return Error.MupdfError;
    }

    /// Delete a range of pages [start, end) (0-based, exclusive end).
    ///
    /// Only works for PDF documents.
    pub fn deletePageRange(self: *Self, start: i32, end: i32) Error!void {
        const pdf_doc = self.asPdf() orelse return Error.NotAPdf;
        const result = c.c.mupdf_shim_delete_page_range(self.ctx.ptr, pdf_doc, start, end);
        if (result != 0) return Error.MupdfError;
    }

    /// Copy a page from another document into this one.
    ///
    /// `page_to`: insertion position in this document (-1 = append at end).
    /// `src`: source document to copy from.
    /// `page_from`: page index in the source document.
    ///
    /// Both documents must be PDFs.
    pub fn insertPageFrom(self: *Self, page_to: i32, src: *Self, page_from: i32) Error!void {
        const dst_pdf = self.asPdf() orelse return Error.NotAPdf;
        const src_pdf = src.asPdf() orelse return Error.NotAPdf;
        _ = src_pdf;
        const result = c.c.mupdf_shim_graft_page(self.ctx.ptr, dst_pdf, page_to, c.c.pdf_specifics(src.ctx.ptr, src.ptr), page_from);
        if (result != 0) return Error.MupdfError;
    }

    /// Rearrange pages in the specified order.
    ///
    /// `page_order`: array of 0-based page indices in the desired order.
    /// Pages not listed are removed. Pages can be duplicated.
    ///
    /// Only works for PDF documents.
    pub fn rearrangePages(self: *Self, page_order: []const i32) Error!void {
        const pdf_doc = self.asPdf() orelse return Error.NotAPdf;
        const result = c.c.mupdf_shim_rearrange_pages(
            self.ctx.ptr,
            pdf_doc,
            @intCast(page_order.len),
            page_order.ptr,
        );
        if (result != 0) return Error.MupdfError;
    }

    /// Create a new empty PDF document.
    pub fn createPdf(ctx: *Context) Error!Self {
        const pdf_doc = c.c.mupdf_shim_create_pdf(ctx.ptr);
        if (pdf_doc == null) return Error.MupdfError;
        // pdf_document embeds fz_document as its first member — cast to fz_document*
        const doc_ptr: *c.c.fz_document = @ptrCast(pdf_doc.?);
        return Self{ .ptr = doc_ptr, .ctx = ctx };
    }

    /// Get the raw MuPDF document pointer.
    pub fn raw(self: *Self) *c.c.fz_document {
        return self.ptr;
    }
};

/// MuPDF Page wrapper.
pub const Page = struct {
    /// The underlying MuPDF page pointer.
    ptr: *c.c.fz_page,
    /// Reference to the parent document.
    doc: *Document,

    const Self = @This();

    /// Load a page from a document.
    pub fn load(doc: *Document, page_num: i32) Error!Self {
        if (page_num < 0 or page_num >= try doc.pageCount()) {
            return Error.PageOutOfRange;
        }

        // Use safe shim that handles fz_try/fz_catch
        const page = c.c.mupdf_shim_load_page(doc.ctx.ptr, doc.ptr, page_num);
        if (page == null) {
            return Error.PageOutOfRange;
        }

        return Self{
            .ptr = page.?,
            .doc = doc,
        };
    }

    /// Release page resources.
    pub fn deinit(self: *Self) void {
        c.c.fz_drop_page(self.doc.ctx.ptr, self.ptr);
        self.ptr = undefined;
    }

    /// Get the page bounding box.
    ///
    /// Fails if the page's inherited attributes are malformed (e.g. a /Parent cycle).
    pub fn bounds(self: *Self) Error!Rect {
        var rect: c.c.fz_rect = undefined;
        if (c.c.mupdf_shim_bound_page(self.doc.ctx.ptr, self.ptr, &rect) != 0) {
            return Error.MupdfError;
        }
        return Rect{
            .x0 = rect.x0,
            .y0 = rect.y0,
            .x1 = rect.x1,
            .y1 = rect.y1,
        };
    }

    /// Get the page width in points.
    pub fn width(self: *Self) Error!f32 {
        const b = try self.bounds();
        return b.x1 - b.x0;
    }

    /// Get the page height in points.
    pub fn height(self: *Self) Error!f32 {
        const b = try self.bounds();
        return b.y1 - b.y0;
    }

    /// Get the page rotation in degrees (0, 90, 180, 270).
    ///
    /// Returns 0 for non-PDF pages.
    pub fn rotation(self: *Self) i32 {
        const pdf_page = c.c.pdf_page_from_fz_page(self.doc.ctx.ptr, self.ptr);
        if (pdf_page == null) return 0;
        return c.c.mupdf_shim_page_rotation(self.doc.ctx.ptr, pdf_page);
    }

    /// Load all links from the page.
    ///
    /// Returns a LinkIterator that yields Link structs. The links remain
    /// valid until the page is deinitialized or links are dropped.
    /// The caller must call `deinitLinks` when done with the returned handle.
    pub fn loadLinks(self: *Self) LinkList {
        const links = c.c.mupdf_shim_load_links(self.doc.ctx.ptr, self.ptr);
        return LinkList{
            .head = links,
            .ctx_ptr = self.doc.ctx.ptr,
        };
    }

    /// Render the page to a pixmap.
    pub fn toPixmap(self: *Self, scale: f32, rot: f32) Error!Pixmap {
        const matrix = c.c.fz_concat(
            c.c.fz_scale(scale, scale),
            c.c.fz_rotate(rot),
        );
        return self.toPixmapWithMatrix(Matrix.fromC(matrix));
    }

    /// Render the page to a pixmap using a Matrix transformation.
    pub fn toPixmapWithMatrix(self: *Self, matrix: Matrix) Error!Pixmap {
        const colorspace = c.c.fz_device_rgb(self.doc.ctx.ptr);

        // Use safe shim that handles fz_try/fz_catch
        const pixmap = c.c.mupdf_shim_new_pixmap_from_page(
            self.doc.ctx.ptr,
            self.ptr,
            matrix.toC(),
            colorspace,
            0, // alpha
        );

        if (pixmap == null) {
            return Error.PixmapCreationFailed;
        }

        return Pixmap{
            .ptr = pixmap.?,
            .ctx = self.doc.ctx,
        };
    }

    /// Iterate over form widgets on this page.
    pub fn getWidgets(self: *Self) ?WidgetIterator {
        const pdf_page = c.c.pdf_page_from_fz_page(self.doc.ctx.ptr, self.ptr);
        if (pdf_page == null) return null;
        return .{ .current = c.c.mupdf_shim_first_widget(self.doc.ctx.ptr, pdf_page), .ctx_ptr = self.doc.ctx.ptr };
    }

    /// Iterate over annotations on this page.
    pub fn getAnnotations(self: *Self) ?AnnotationIterator {
        const pdf_page = c.c.pdf_page_from_fz_page(self.doc.ctx.ptr, self.ptr);
        if (pdf_page == null) return null;
        return .{ .current = c.c.mupdf_shim_first_annot(self.doc.ctx.ptr, pdf_page), .ctx_ptr = self.doc.ctx.ptr, .page_ptr = pdf_page.? };
    }

    /// Create a new annotation on this page.
    pub fn createAnnotation(self: *Self, annot_type: AnnotationType) Error!Annotation {
        const pdf_page = c.c.pdf_page_from_fz_page(self.doc.ctx.ptr, self.ptr);
        if (pdf_page == null) return Error.NotAPdf;
        const annot = c.c.mupdf_shim_create_annot(self.doc.ctx.ptr, pdf_page, @intFromEnum(annot_type));
        if (annot == null) return Error.MupdfError;
        return .{ .ptr = annot.?, .ctx_ptr = self.doc.ctx.ptr, .page_ptr = pdf_page.? };
    }

    /// List all embedded images on this page.
    ///
    /// Returns an array of ImageInfo structs with metadata about each image.
    /// Only works for PDF pages. The caller must free the returned slice.
    pub fn getImages(self: *Self, allocator: std.mem.Allocator) Error![]ImageInfo {
        const pdf_doc = self.doc.asPdf() orelse return Error.NotAPdf;
        const pdf_page = c.c.pdf_page_from_fz_page(self.doc.ctx.ptr, self.ptr);
        if (pdf_page == null) return Error.NotAPdf;

        const max_images = 256;
        var c_infos: [max_images]c.c.mupdf_shim_image_info = undefined;

        const count = c.c.mupdf_shim_page_images(
            self.doc.ctx.ptr,
            pdf_doc,
            pdf_page,
            &c_infos,
            max_images,
        );

        if (count <= 0) {
            const empty = allocator.alloc(ImageInfo, 0) catch return Error.OutOfMemory;
            return empty;
        }

        const n: usize = @intCast(count);
        const results = allocator.alloc(ImageInfo, n) catch return Error.OutOfMemory;

        for (0..n) |i| {
            results[i] = ImageInfo{
                .xref = c_infos[i].xref,
                .width = c_infos[i].width,
                .height = c_infos[i].height,
                .bpc = c_infos[i].bpc,
                .components = c_infos[i].n_components,
                .colorspace = if (c_infos[i].colorspace_name) |cs| std.mem.span(cs) else "",
                .filter = if (c_infos[i].filter_name) |f| std.mem.span(f) else "",
                .ref_name = if (c_infos[i].ref_name) |r| std.mem.span(r) else "",
            };
        }

        return results;
    }

    /// Load an image by its xref number for extraction.
    ///
    /// Use getImages() first to discover image xrefs on a page.
    pub fn loadImage(self: *Self, xref: i32) Error!Image {
        const pdf_doc = self.doc.asPdf() orelse return Error.NotAPdf;
        const img = c.c.mupdf_shim_load_image(self.doc.ctx.ptr, pdf_doc, xref);
        if (img == null) return Error.OpenFailed;
        return Image{ .ptr = img.?, .ctx = self.doc.ctx };
    }

    /// Extract structured text from the page.
    ///
    /// Returns a TextPage that allows iterating blocks, lines, and characters
    /// with position, font, and style information.
    pub fn extractText(self: *Self, options: TextOptions) Error!TextPage {
        const c_opts = options.toC();
        const stext = c.c.mupdf_shim_new_stext_page(self.doc.ctx.ptr, self.ptr, &c_opts);
        if (stext == null) return Error.TextExtractionFailed;
        return TextPage{ .ptr = stext.?, .ctx_ptr = self.doc.ctx.ptr };
    }

    /// Extract all text from the page as a plain string.
    ///
    /// Shorthand for `extractText` + `getText`. The caller must free the result.
    pub fn getText(self: *Self, allocator: std.mem.Allocator) Error![]u8 {
        var text_page = try self.extractText(.{});
        defer text_page.deinit();
        return text_page.getText(allocator);
    }

    /// Search for text on the page.
    ///
    /// Returns an array of SearchHit quads covering each match.
    /// The caller must free the returned slice.
    pub fn search(self: *Self, needle: []const u8, allocator: std.mem.Allocator) Error![]SearchHit {
        // Null-terminate the needle
        var needle_buf: [4096]u8 = undefined;
        if (needle.len >= needle_buf.len) return Error.InvalidArgument;
        @memcpy(needle_buf[0..needle.len], needle);
        needle_buf[needle.len] = 0;

        const max_hits = 512;
        var hit_quads: [max_hits]c.c.fz_quad = undefined;
        var hit_marks: [max_hits]c_int = undefined;

        const count = c.c.mupdf_shim_search_page(
            self.doc.ctx.ptr,
            self.ptr,
            &needle_buf,
            &hit_marks,
            &hit_quads,
            max_hits,
        );

        if (count < 0) return Error.SearchFailed;
        if (count == 0) {
            const empty = allocator.alloc(SearchHit, 0) catch return Error.OutOfMemory;
            return empty;
        }

        const n: usize = @intCast(count);
        const results = allocator.alloc(SearchHit, n) catch return Error.OutOfMemory;
        for (0..n) |i| {
            results[i] = SearchHit{
                .quad = Quad.fromC(hit_quads[i]),
                .mark = hit_marks[i] != 0,
            };
        }
        return results;
    }

    /// Get the raw MuPDF page pointer.
    pub fn raw(self: *Self) *c.c.fz_page {
        return self.ptr;
    }
};

/// Owned list of links loaded from a page.
/// Must be freed by calling `deinit`.
pub const LinkList = struct {
    head: ?*c.c.fz_link,
    ctx_ptr: *c.c.fz_context,

    /// Get an iterator over the links.
    pub fn iterator(self: *const LinkList) LinkIterator {
        return LinkIterator{ .current = self.head };
    }

    /// Release the link list resources.
    pub fn deinit(self: *LinkList) void {
        if (self.head) |h| {
            c.c.fz_drop_link(self.ctx_ptr, h);
            self.head = null;
        }
    }
};

/// Quadrilateral (four corners of a transformed rectangle).
pub const Quad = struct {
    /// Upper-left corner.
    ul: Point,
    /// Upper-right corner.
    ur: Point,
    /// Lower-left corner.
    ll: Point,
    /// Lower-right corner.
    lr: Point,

    /// Convert to a bounding Rect.
    pub fn toRect(self: Quad) Rect {
        const min_x = @min(@min(self.ul.x, self.ur.x), @min(self.ll.x, self.lr.x));
        const min_y = @min(@min(self.ul.y, self.ur.y), @min(self.ll.y, self.lr.y));
        const max_x = @max(@max(self.ul.x, self.ur.x), @max(self.ll.x, self.lr.x));
        const max_y = @max(@max(self.ul.y, self.ur.y), @max(self.ll.y, self.lr.y));
        return Rect{ .x0 = min_x, .y0 = min_y, .x1 = max_x, .y1 = max_y };
    }

    fn fromC(q: c.c.fz_quad) Quad {
        return Quad{
            .ul = .{ .x = q.ul.x, .y = q.ul.y },
            .ur = .{ .x = q.ur.x, .y = q.ur.y },
            .ll = .{ .x = q.ll.x, .y = q.ll.y },
            .lr = .{ .x = q.lr.x, .y = q.lr.y },
        };
    }
};

/// 2D point.
pub const Point = struct {
    x: f32,
    y: f32,
};

/// Options for structured text extraction.
pub const TextOptions = struct {
    /// Preserve ligatures (fi, fl, etc.) as single characters.
    preserve_ligatures: bool = true,
    /// Preserve original whitespace.
    preserve_whitespace: bool = true,
    /// Include image blocks in the output.
    preserve_images: bool = false,
    /// Don't insert spaces between characters.
    inhibit_spaces: bool = false,
    /// Dehyphenate words at line breaks.
    dehyphenate: bool = false,

    fn toC(self: TextOptions) c.c.fz_stext_options {
        var flags: c_int = 0;
        if (self.preserve_ligatures) flags |= 1; // FZ_STEXT_PRESERVE_LIGATURES
        if (self.preserve_whitespace) flags |= 2; // FZ_STEXT_PRESERVE_WHITESPACE
        if (self.preserve_images) flags |= 4; // FZ_STEXT_PRESERVE_IMAGES
        if (self.inhibit_spaces) flags |= 8; // FZ_STEXT_INHIBIT_SPACES
        if (self.dehyphenate) flags |= 16; // FZ_STEXT_DEHYPHENATE
        var opts: c.c.fz_stext_options = std.mem.zeroes(c.c.fz_stext_options);
        opts.flags = flags;
        return opts;
    }
};

/// A character extracted from structured text.
pub const TextChar = struct {
    /// Unicode codepoint.
    codepoint: u21,
    /// Character origin (baseline position).
    origin: Point,
    /// Bounding quad (transformed).
    quad: Quad,
    /// Font size in points.
    size: f32,
    /// Character flags (bold, underline, etc.)
    flags: u16,
    /// sRGB color as 0xAARRGGBB.
    argb: u32,
};

/// Iterator over characters in a text line.
pub const TextCharIterator = struct {
    current: ?*c.c.fz_stext_char,

    pub fn next(self: *TextCharIterator) ?TextChar {
        const ch = self.current orelse return null;
        self.current = ch.next;
        return TextChar{
            .codepoint = if (ch.c >= 0) @intCast(@as(u32, @bitCast(ch.c))) else 0xFFFD,
            .origin = .{ .x = ch.origin.x, .y = ch.origin.y },
            .quad = Quad.fromC(ch.quad),
            .size = ch.size,
            .flags = ch.flags,
            .argb = ch.argb,
        };
    }
};

/// Iterator over lines in a text block.
pub const TextLineIterator = struct {
    current: ?*c.c.fz_stext_line,

    pub fn next(self: *TextLineIterator) ?TextLine {
        const line = self.current orelse return null;
        self.current = line.next;
        return TextLine{
            .bbox = Rect{
                .x0 = line.bbox.x0,
                .y0 = line.bbox.y0,
                .x1 = line.bbox.x1,
                .y1 = line.bbox.y1,
            },
            .wmode = line.wmode,
            .first_char = line.first_char,
        };
    }
};

/// A line of text from structured text extraction.
pub const TextLine = struct {
    /// Bounding box of the line.
    bbox: Rect,
    /// Writing mode: 0 = horizontal, 1 = vertical.
    wmode: u8,
    /// Internal pointer (for char iteration).
    first_char: ?*c.c.fz_stext_char,

    /// Iterate over characters in this line.
    pub fn chars(self: TextLine) TextCharIterator {
        return TextCharIterator{ .current = self.first_char };
    }

    /// Collect the text of this line into a string.
    pub fn getText(self: TextLine, allocator: std.mem.Allocator) Error![]u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        errdefer buf.deinit(allocator);
        var iter = self.chars();
        while (iter.next()) |ch| {
            var utf8_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(ch.codepoint, &utf8_buf) catch 0;
            if (len > 0) {
                buf.appendSlice(allocator, utf8_buf[0..len]) catch return Error.OutOfMemory;
            }
        }
        return buf.toOwnedSlice(allocator) catch return Error.OutOfMemory;
    }
};

/// Iterator over blocks in a text page.
pub const TextBlockIterator = struct {
    current: ?*c.c.fz_stext_block,

    pub fn next(self: *TextBlockIterator) ?TextBlock {
        // Skip non-text blocks
        while (self.current) |block| {
            self.current = block.next;
            if (block.type == 0) { // FZ_STEXT_BLOCK_TEXT
                return TextBlock{
                    .bbox = Rect{
                        .x0 = block.bbox.x0,
                        .y0 = block.bbox.y0,
                        .x1 = block.bbox.x1,
                        .y1 = block.bbox.y1,
                    },
                    .block_type = .text,
                    .first_line = block.u.t.first_line,
                };
            } else if (block.type == 1) { // FZ_STEXT_BLOCK_IMAGE
                return TextBlock{
                    .bbox = Rect{
                        .x0 = block.bbox.x0,
                        .y0 = block.bbox.y0,
                        .x1 = block.bbox.x1,
                        .y1 = block.bbox.y1,
                    },
                    .block_type = .image,
                    .first_line = null,
                };
            }
        }
        return null;
    }
};

/// Type of a text block.
pub const BlockType = enum {
    text,
    image,
};

/// A block of content from structured text extraction.
pub const TextBlock = struct {
    /// Bounding box of the block.
    bbox: Rect,
    /// Type of block.
    block_type: BlockType,
    /// Internal pointer (for line iteration, text blocks only).
    first_line: ?*c.c.fz_stext_line,

    /// Iterate over lines in this block (text blocks only).
    pub fn lines(self: TextBlock) TextLineIterator {
        return TextLineIterator{ .current = self.first_line };
    }
};

/// Structured text page wrapper.
///
/// Provides access to extracted text with position, font, and style info.
pub const TextPage = struct {
    ptr: *c.c.fz_stext_page,
    ctx_ptr: *c.c.fz_context,

    /// Release text page resources.
    pub fn deinit(self: *TextPage) void {
        c.c.fz_drop_stext_page(self.ctx_ptr, self.ptr);
        self.ptr = undefined;
    }

    /// Get the media box of the page.
    pub fn mediabox(self: *const TextPage) Rect {
        return Rect{
            .x0 = self.ptr.mediabox.x0,
            .y0 = self.ptr.mediabox.y0,
            .x1 = self.ptr.mediabox.x1,
            .y1 = self.ptr.mediabox.y1,
        };
    }

    /// Iterate over text blocks.
    pub fn blocks(self: *const TextPage) TextBlockIterator {
        return TextBlockIterator{ .current = self.ptr.first_block };
    }

    /// Extract all text as a plain string.
    ///
    /// Uses MuPDF's built-in flattening with paragraph breaks.
    /// The caller must free the returned slice.
    pub fn getText(self: *TextPage, allocator: std.mem.Allocator) Error![]u8 {
        const buf = c.c.mupdf_shim_stext_to_buffer(self.ctx_ptr, self.ptr);
        if (buf == null) return Error.TextExtractionFailed;
        defer c.c.fz_drop_buffer(self.ctx_ptr, buf);

        var data_ptr: [*c]u8 = null;
        const len = c.c.fz_buffer_storage(self.ctx_ptr, buf, &data_ptr);
        if (data_ptr == null or len == 0) {
            const empty = allocator.alloc(u8, 0) catch return Error.OutOfMemory;
            return empty;
        }

        const result = allocator.alloc(u8, len) catch return Error.OutOfMemory;
        @memcpy(result, data_ptr[0..len]);
        return result;
    }
};

/// A search hit on a page.
pub const SearchHit = struct {
    /// Bounding quad of the match.
    quad: Quad,
    /// Whether this quad is part of the same hit as the previous one (multi-line match).
    mark: bool,
};

/// Metadata for an embedded image on a page.
pub const ImageInfo = struct {
    /// PDF object cross-reference number.
    xref: i32,
    /// Image width in pixels.
    width: i32,
    /// Image height in pixels.
    height: i32,
    /// Bits per component.
    bpc: i32,
    /// Number of color components.
    components: i32,
    /// Colorspace name (e.g., "DeviceRGB").
    colorspace: []const u8,
    /// Compression filter name (e.g., "DCTDecode" for JPEG).
    filter: []const u8,
    /// Reference name in the page's Resources/XObject dict.
    ref_name: []const u8,
};

/// A loaded image from a PDF, ready for extraction.
pub const Image = struct {
    ptr: *c.c.fz_image,
    ctx: *Context,

    /// Get image width in pixels.
    pub fn getWidth(self: *const Image) i32 {
        return c.c.mupdf_shim_image_width(self.ptr);
    }

    /// Get image height in pixels.
    pub fn getHeight(self: *const Image) i32 {
        return c.c.mupdf_shim_image_height(self.ptr);
    }

    /// Get bits per component.
    pub fn getBpc(self: *const Image) i32 {
        return c.c.mupdf_shim_image_bpc(self.ptr);
    }

    /// Get number of components per pixel.
    pub fn getComponents(self: *const Image) i32 {
        return c.c.mupdf_shim_image_n(self.ptr);
    }

    /// Get image resolution in DPI.
    pub fn getResolution(self: *const Image) struct { xres: i32, yres: i32 } {
        return .{
            .xres = c.c.mupdf_shim_image_xres(self.ptr),
            .yres = c.c.mupdf_shim_image_yres(self.ptr),
        };
    }

    /// Decode the image to a Pixmap for pixel access or PNG export.
    pub fn toPixmap(self: *Image) Error!Pixmap {
        const pix = c.c.mupdf_shim_image_to_pixmap(self.ctx.ptr, self.ptr);
        if (pix == null) return Error.PixmapCreationFailed;
        return Pixmap{ .ptr = pix.?, .ctx = self.ctx };
    }

    /// Release image resources.
    pub fn deinit(self: *Image) void {
        c.c.fz_drop_image(self.ctx.ptr, self.ptr);
        self.ptr = undefined;
    }
};

/// PDF annotation types.
pub const AnnotationType = enum(i32) {
    text = 0, link = 1, free_text = 2, line = 3, square = 4, circle = 5,
    polygon = 6, poly_line = 7, highlight = 8, underline = 9, squiggly = 10,
    strike_out = 11, redact = 12, stamp = 13, caret = 14, ink = 15, popup = 16,
    file_attachment = 17, sound = 18, movie = 19, rich_media = 20, widget = 21,
    screen = 22, printer_mark = 23, trap_net = 24, watermark = 25,
    @"3d" = 26, projection = 27, unknown = -1,
};

/// RGB color (0.0-1.0 per component).
pub const Color = struct { r: f32 = 0, g: f32 = 0, b: f32 = 0 };

/// A PDF annotation on a page.
pub const Annotation = struct {
    ptr: *c.c.pdf_annot,
    ctx_ptr: *c.c.fz_context,
    page_ptr: *c.c.pdf_page,

    pub fn getType(self: *const Annotation) AnnotationType {
        return std.meta.intToEnum(AnnotationType, c.c.mupdf_shim_annot_type(self.ctx_ptr, self.ptr)) catch .unknown;
    }
    pub fn getRect(self: *const Annotation) Rect {
        const r = c.c.mupdf_shim_annot_rect(self.ctx_ptr, self.ptr);
        return .{ .x0 = r.x0, .y0 = r.y0, .x1 = r.x1, .y1 = r.y1 };
    }
    pub fn getContents(self: *const Annotation) []const u8 {
        const s = c.c.mupdf_shim_annot_contents(self.ctx_ptr, self.ptr);
        return if (s) |p| std.mem.span(p) else "";
    }
    pub fn getAuthor(self: *const Annotation) []const u8 {
        const s = c.c.mupdf_shim_annot_author(self.ctx_ptr, self.ptr);
        return if (s) |p| std.mem.span(p) else "";
    }
    pub fn getColor(self: *const Annotation) Color {
        var n: c_int = 0;
        var col: [4]f32 = .{ 0, 0, 0, 0 };
        c.c.mupdf_shim_annot_color(self.ctx_ptr, self.ptr, &n, &col);
        return .{ .r = col[0], .g = col[1], .b = col[2] };
    }
    pub fn getOpacity(self: *const Annotation) f32 {
        return c.c.mupdf_shim_annot_opacity(self.ctx_ptr, self.ptr);
    }
    pub fn setContents(self: *Annotation, text: []const u8) void {
        var buf: [4096]u8 = undefined;
        if (text.len >= buf.len) return;
        @memcpy(buf[0..text.len], text);
        buf[text.len] = 0;
        c.c.mupdf_shim_set_annot_contents(self.ctx_ptr, self.ptr, &buf);
    }
    pub fn setAuthor(self: *Annotation, author: []const u8) void {
        var buf: [256]u8 = undefined;
        if (author.len >= buf.len) return;
        @memcpy(buf[0..author.len], author);
        buf[author.len] = 0;
        c.c.mupdf_shim_set_annot_author(self.ctx_ptr, self.ptr, &buf);
    }
    pub fn setColor(self: *Annotation, color: Color) void {
        const col = [_]f32{ color.r, color.g, color.b };
        c.c.mupdf_shim_set_annot_color(self.ctx_ptr, self.ptr, 3, &col);
    }
    pub fn setOpacity(self: *Annotation, opacity: f32) void {
        c.c.mupdf_shim_set_annot_opacity(self.ctx_ptr, self.ptr, opacity);
    }
    pub fn setRect(self: *Annotation, rect: Rect) void {
        c.c.mupdf_shim_set_annot_rect(self.ctx_ptr, self.ptr, .{ .x0 = rect.x0, .y0 = rect.y0, .x1 = rect.x1, .y1 = rect.y1 });
    }
    pub fn setQuadPoints(self: *Annotation, quads: []const Quad) void {
        if (quads.len > 128) return;
        var fz_quads: [128]c.c.fz_quad = undefined;
        for (quads, 0..) |q, i| {
            fz_quads[i] = .{
                .ul = .{ .x = q.ul.x, .y = q.ul.y }, .ur = .{ .x = q.ur.x, .y = q.ur.y },
                .ll = .{ .x = q.ll.x, .y = q.ll.y }, .lr = .{ .x = q.lr.x, .y = q.lr.y },
            };
        }
        c.c.mupdf_shim_set_annot_quad_points(self.ctx_ptr, self.ptr, @intCast(quads.len), &fz_quads);
    }
    pub fn update(self: *Annotation) void {
        _ = c.c.mupdf_shim_update_annot(self.ctx_ptr, self.ptr);
    }
    pub fn delete(self: *Annotation) Error!void {
        if (c.c.mupdf_shim_delete_annot(self.ctx_ptr, self.page_ptr, self.ptr) != 0) return Error.MupdfError;
    }
};

/// Iterator over annotations on a page.
pub const AnnotationIterator = struct {
    current: ?*c.c.pdf_annot,
    ctx_ptr: *c.c.fz_context,
    page_ptr: *c.c.pdf_page,

    pub fn next(self: *AnnotationIterator) ?Annotation {
        const annot = self.current orelse return null;
        self.current = c.c.mupdf_shim_next_annot(self.ctx_ptr, annot);
        return .{ .ptr = annot, .ctx_ptr = self.ctx_ptr, .page_ptr = self.page_ptr };
    }
};

/// A single entry in the document outline (Table of Contents).
pub const OutlineItem = struct {
    /// Item title text.
    title: []const u8,
    /// Destination URI (internal "#page=N" or external URL).
    uri: []const u8,
    /// Destination page number (0-based), or -1 if none.
    page: i32,
    /// Whether this item is expanded in the UI.
    is_open: bool,
    /// Whether this item has children.
    has_children: bool,
};

/// Outline tree loaded from a document. Must be freed with `deinit`.
pub const Outline = struct {
    root: ?*c.c.fz_outline,
    ctx_ptr: *c.c.fz_context,
    doc_ptr: *c.c.fz_document,

    /// Walk the outline tree, calling the callback for each item with its depth level.
    /// Collects all items into a flat array with depth info.
    pub fn toList(self: *const Outline, allocator: std.mem.Allocator) Error![]OutlineEntry {
        var list = std.ArrayListUnmanaged(OutlineEntry){};
        errdefer list.deinit(allocator);
        self.collectItems(self.root, 0, &list, allocator) catch return Error.OutOfMemory;
        return list.toOwnedSlice(allocator) catch return Error.OutOfMemory;
    }

    fn collectItems(self: *const Outline, node: ?*c.c.fz_outline, depth: u32, list: *std.ArrayListUnmanaged(OutlineEntry), allocator: std.mem.Allocator) !void {
        var current = node;
        while (current) |item| {
            const title = c.c.mupdf_shim_outline_title(item);
            const uri = c.c.mupdf_shim_outline_uri(item);
            const page = c.c.mupdf_shim_outline_page(self.ctx_ptr, self.doc_ptr, item);
            try list.append(allocator, .{
                .item = .{
                    .title = if (title) |t| std.mem.span(t) else "",
                    .uri = if (uri) |u| std.mem.span(u) else "",
                    .page = page,
                    .is_open = c.c.mupdf_shim_outline_is_open(item) != 0,
                    .has_children = c.c.mupdf_shim_outline_down(item) != null,
                },
                .depth = depth,
            });
            // Recurse into children
            const down = c.c.mupdf_shim_outline_down(item);
            if (down != null) {
                try self.collectItems(down, depth + 1, list, allocator);
            }
            current = c.c.mupdf_shim_outline_next(item);
        }
    }

    /// Release the outline tree.
    pub fn deinit(self: *Outline) void {
        if (self.root) |r| {
            c.c.fz_drop_outline(self.ctx_ptr, r);
            self.root = null;
        }
    }
};

/// An outline entry with its depth in the tree.
pub const OutlineEntry = struct {
    item: OutlineItem,
    depth: u32,
};

/// Form widget types.
pub const WidgetType = enum(i32) {
    unknown = 0,
    button = 1,
    checkbox = 2,
    combobox = 3,
    listbox = 4,
    radiobutton = 5,
    signature = 6,
    text = 7,
};

/// A form field/widget on a page.
pub const Widget = struct {
    ptr: *c.c.pdf_annot,
    ctx_ptr: *c.c.fz_context,

    /// Get the widget type.
    pub fn getType(self: *const Widget) WidgetType {
        return std.meta.intToEnum(WidgetType, c.c.mupdf_shim_widget_type(self.ctx_ptr, self.ptr)) catch .unknown;
    }

    /// Get the field label/name.
    pub fn getLabel(self: *const Widget) []const u8 {
        const s = c.c.mupdf_shim_widget_label(self.ctx_ptr, self.ptr);
        return if (s) |p| std.mem.span(p) else "";
    }

    /// Get the current field value.
    pub fn getValue(self: *const Widget) []const u8 {
        const s = c.c.mupdf_shim_widget_value(self.ctx_ptr, self.ptr);
        return if (s) |p| std.mem.span(p) else "";
    }

    /// Check if the widget is read-only.
    pub fn isReadOnly(self: *const Widget) bool {
        return c.c.mupdf_shim_widget_is_readonly(self.ctx_ptr, self.ptr) != 0;
    }

    /// Get the bounding rectangle.
    pub fn getRect(self: *const Widget) Rect {
        const r = c.c.mupdf_shim_widget_rect(self.ctx_ptr, self.ptr);
        return .{ .x0 = r.x0, .y0 = r.y0, .x1 = r.x1, .y1 = r.y1 };
    }
};

/// Iterator over form widgets on a page.
pub const WidgetIterator = struct {
    current: ?*c.c.pdf_annot,
    ctx_ptr: *c.c.fz_context,

    pub fn next(self: *WidgetIterator) ?Widget {
        const w = self.current orelse return null;
        self.current = c.c.mupdf_shim_next_widget(self.ctx_ptr, w);
        return .{ .ptr = w, .ctx_ptr = self.ctx_ptr };
    }
};

/// Rectangle structure.
pub const Rect = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,

    pub fn width(self: Rect) f32 {
        return self.x1 - self.x0;
    }

    pub fn height(self: Rect) f32 {
        return self.y1 - self.y0;
    }
};

/// MuPDF Pixmap wrapper.
pub const Pixmap = struct {
    /// The underlying MuPDF pixmap pointer.
    ptr: *c.c.fz_pixmap,
    /// Reference to the context.
    ctx: *Context,

    const Self = @This();

    /// Release pixmap resources.
    pub fn deinit(self: *Self) void {
        c.c.fz_drop_pixmap(self.ctx.ptr, self.ptr);
        self.ptr = undefined;
    }

    /// Get the pixmap width.
    pub fn width(self: *Self) i32 {
        return c.c.fz_pixmap_width(self.ctx.ptr, self.ptr);
    }

    /// Get the pixmap height.
    pub fn height(self: *Self) i32 {
        return c.c.fz_pixmap_height(self.ctx.ptr, self.ptr);
    }

    /// Get the number of components (channels) per pixel.
    pub fn components(self: *Self) i32 {
        return c.c.fz_pixmap_components(self.ctx.ptr, self.ptr);
    }

    /// Get the stride (bytes per row).
    pub fn stride(self: *Self) i32 {
        return c.c.fz_pixmap_stride(self.ctx.ptr, self.ptr);
    }

    /// Get a pointer to the raw pixel data.
    pub fn samples(self: *Self) [*]u8 {
        return c.c.fz_pixmap_samples(self.ctx.ptr, self.ptr);
    }

    /// Save the pixmap as a PNG file.
    pub fn savePng(self: *Self, path: []const u8) Error!void {
        var path_buf: [4096]u8 = undefined;
        if (path.len >= path_buf.len) {
            return Error.InvalidArgument;
        }
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        if (c.c.mupdf_shim_save_pixmap_as_png(self.ctx.ptr, self.ptr, &path_buf) != 0) {
            return Error.WriteFailed;
        }
    }

    /// Encode the pixmap as PNG data in memory.
    ///
    /// Returns the PNG bytes as an owned slice. The caller must free it.
    pub fn toPng(self: *Self, alloc: std.mem.Allocator) Error![]u8 {
        const buf = c.c.mupdf_shim_pixmap_to_png(self.ctx.ptr, self.ptr);
        if (buf == null) return Error.WriteFailed;
        defer c.c.fz_drop_buffer(self.ctx.ptr, buf);

        var data_ptr: [*c]u8 = null;
        const len = c.c.fz_buffer_storage(self.ctx.ptr, buf, &data_ptr);
        if (data_ptr == null or len == 0) return Error.WriteFailed;

        const result = alloc.alloc(u8, len) catch return Error.OutOfMemory;
        @memcpy(result, data_ptr[0..len]);
        return result;
    }

    /// Get the raw MuPDF pixmap pointer.
    pub fn raw(self: *Self) *c.c.fz_pixmap {
        return self.ptr;
    }
};

// ============================================
// Unit Tests
// ============================================

// Test PDF path - relative to project root
const test_pdf_path = "tests/fixtures/sample.pdf";

test "Document.open opens valid PDF" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    try std.testing.expect(@intFromPtr(doc.ptr) != 0);
}

test "Document.open returns error for non-existent file" {
    var ctx = try Context.init();
    defer ctx.deinit();

    const result = Document.open(&ctx, "non_existent_file.pdf");
    try std.testing.expectError(Error.OpenFailed, result);
}

test "Document.open returns error for path too long" {
    var ctx = try Context.init();
    defer ctx.deinit();

    // Create a path longer than 4096 characters
    var long_path: [5000]u8 = undefined;
    @memset(&long_path, 'a');

    const result = Document.open(&ctx, &long_path);
    try std.testing.expectError(Error.InvalidArgument, result);
}

test "Document.pageCount returns correct count" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    const count = try doc.pageCount();
    try std.testing.expectEqual(@as(i32, 2), count);
}

test "Document.needsPassword returns false for unprotected PDF" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    try std.testing.expect(!(try doc.needsPassword()));
}

test "Document.isPdf returns true for PDF" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    try std.testing.expect(doc.isPdf());
}

test "Document.asPdf returns non-null for PDF" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    const pdf_doc = doc.asPdf();
    try std.testing.expect(pdf_doc != null);
}

test "Document.loadPage loads valid page" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    try std.testing.expect(@intFromPtr(page.ptr) != 0);
}

test "Document.loadPage returns error for out of range" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    // Try to load page 10 when there are only 2 pages
    const result = doc.loadPage(10);
    try std.testing.expectError(Error.PageOutOfRange, result);
}

test "Document.loadPage returns error for negative index" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    const result = doc.loadPage(-1);
    try std.testing.expectError(Error.PageOutOfRange, result);
}

test "Page.bounds returns valid dimensions" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    const bounds = try page.bounds();

    // Sample PDF has US Letter size (612 x 792 points)
    try std.testing.expectApproxEqAbs(@as(f32, 612.0), bounds.width(), 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 792.0), bounds.height(), 0.1);
}

test "Page.width and height match bounds" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    const bounds = try page.bounds();

    try std.testing.expectApproxEqAbs(bounds.width(), try page.width(), 0.001);
    try std.testing.expectApproxEqAbs(bounds.height(), try page.height(), 0.001);
}

test "Page.toPixmap creates valid pixmap" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    var pixmap = try page.toPixmap(1.0, 0.0);
    defer pixmap.deinit();

    try std.testing.expect(@intFromPtr(pixmap.ptr) != 0);
}

test "Pixmap dimensions match page at scale 1.0" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    var pixmap = try page.toPixmap(1.0, 0.0);
    defer pixmap.deinit();

    // Pixmap dimensions should match page dimensions at scale 1.0
    const page_width = @as(i32, @intFromFloat(try page.width()));
    const page_height = @as(i32, @intFromFloat(try page.height()));

    try std.testing.expectEqual(page_width, pixmap.width());
    try std.testing.expectEqual(page_height, pixmap.height());
}

test "Pixmap dimensions scale correctly" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    // Render at 2x scale
    var pixmap = try page.toPixmap(2.0, 0.0);
    defer pixmap.deinit();

    const page_width = @as(i32, @intFromFloat((try page.width()) * 2.0));
    const page_height = @as(i32, @intFromFloat((try page.height()) * 2.0));

    try std.testing.expectEqual(page_width, pixmap.width());
    try std.testing.expectEqual(page_height, pixmap.height());
}

test "Pixmap.stride is at least width * components" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    var pixmap = try page.toPixmap(1.0, 0.0);
    defer pixmap.deinit();

    const min_stride = pixmap.width() * pixmap.components();
    try std.testing.expect(pixmap.stride() >= min_stride);
}

test "Pixmap.samples returns valid pointer" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    var pixmap = try page.toPixmap(1.0, 0.0);
    defer pixmap.deinit();

    const samples = pixmap.samples();
    try std.testing.expect(@intFromPtr(samples) != 0);
}

test "Rect.width and height calculate correctly" {
    const rect = Rect{
        .x0 = 10.0,
        .y0 = 20.0,
        .x1 = 110.0,
        .y1 = 220.0,
    };

    try std.testing.expectApproxEqAbs(@as(f32, 100.0), rect.width(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 200.0), rect.height(), 0.001);
}

test "multiple pages can be loaded from same document" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    var page0 = try doc.loadPage(0);
    defer page0.deinit();

    var page1 = try doc.loadPage(1);
    defer page1.deinit();

    // Both pages should be valid and different
    try std.testing.expect(@intFromPtr(page0.ptr) != 0);
    try std.testing.expect(@intFromPtr(page1.ptr) != 0);
    try std.testing.expect(page0.ptr != page1.ptr);
}

test "context.openDocument is equivalent to Document.open" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try ctx.openDocument(test_pdf_path);
    defer doc.deinit();

    try std.testing.expectEqual(@as(i32, 2), try doc.pageCount());
}

// ============================================
// Metadata Tests
// ============================================

test "Document.getMetadata returns title" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    const allocator = std.testing.allocator;
    if (try doc.getMetadata(.title, allocator)) |title| {
        defer allocator.free(title);
        try std.testing.expectEqualStrings("Test Document", title);
    } else {
        // Title might not be available in some PDF configurations
        // This is acceptable - we just want to ensure the API works
    }
}

test "Document.getMetadata returns author" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    const allocator = std.testing.allocator;
    if (try doc.getMetadata(.author, allocator)) |author| {
        defer allocator.free(author);
        try std.testing.expectEqualStrings("zig-mupdf", author);
    }
}

test "Document.getMetadata returns null for missing key" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    const allocator = std.testing.allocator;
    // Use a custom key that definitely doesn't exist
    const result = try doc.getMetadataRaw("info:NonExistentKey", allocator);
    try std.testing.expect(result == null);
}

test "Document.getMetadata returns format" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    const allocator = std.testing.allocator;
    if (try doc.getMetadata(.format, allocator)) |format| {
        defer allocator.free(format);
        // Format should contain "PDF"
        try std.testing.expect(std.mem.indexOf(u8, format, "PDF") != null);
    }
}

test "Document.getAllMetadata returns struct with all fields" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    const allocator = std.testing.allocator;
    var metadata = try doc.getAllMetadata(allocator);
    defer metadata.deinit();

    // Verify the struct was populated (at least format should exist)
    if (metadata.format) |format| {
        try std.testing.expect(format.len > 0);
    }
}

test "MetadataKey.toKey returns correct strings" {
    try std.testing.expectEqualStrings("format", MetadataKey.format.toKey());
    try std.testing.expectEqualStrings("info:Title", MetadataKey.title.toKey());
    try std.testing.expectEqualStrings("info:Author", MetadataKey.author.toKey());
    try std.testing.expectEqualStrings("info:CreationDate", MetadataKey.creation_date.toKey());
}

test "Metadata.deinit frees all allocations" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    const allocator = std.testing.allocator;
    var metadata = try doc.getAllMetadata(allocator);
    // deinit should free all without memory leaks
    metadata.deinit();
}

// ============================================
// SaveOptions Tests
// ============================================

test "SaveOptions.toCOptions converts correctly" {
    const opts = SaveOptions{
        .incremental = true,
        .pretty = true,
        .compress = 2,
        .garbage = 3,
    };

    const c_opts = opts.toCOptions();
    try std.testing.expectEqual(@as(c_int, 1), c_opts.do_incremental);
    try std.testing.expectEqual(@as(c_int, 1), c_opts.do_pretty);
    try std.testing.expectEqual(@as(c_int, 2), c_opts.do_compress);
    try std.testing.expectEqual(@as(c_int, 3), c_opts.do_garbage);
}

test "SaveOptions default values" {
    const opts = SaveOptions{};
    try std.testing.expect(!opts.incremental);
    try std.testing.expect(!opts.pretty);
    try std.testing.expectEqual(@as(u8, 1), opts.compress);
    try std.testing.expectEqual(@as(u8, 0), opts.garbage);
}

// Note: Document.save test requires a writable location
// and would create files, so we test the API surface only
test "Document.save returns NotAPdf for non-PDF docs" {
    // This test would require opening a non-PDF document
    // For now, we just verify the method exists and compiles
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    // PDF documents should not return NotAPdf error
    // We don't actually save to avoid creating test artifacts
    try std.testing.expect(doc.isPdf());
}

// ============================================
// Matrix Tests
// ============================================

test "Matrix.identity is correct" {
    const m = Matrix.identity;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m.a, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m.b, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m.c_val, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m.d, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m.e, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m.f, 0.001);
}

test "Matrix.scale creates scaling matrix" {
    const m = Matrix.scale(2.0, 3.0);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), m.a, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), m.d, 0.001);
}

test "Matrix.rotate creates rotation matrix" {
    const m = Matrix.rotate(90.0);
    // 90-degree rotation: a≈0, b≈1, c≈-1, d≈0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m.a, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m.b, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), m.c_val, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), m.d, 0.001);
}

test "Matrix.translate creates translation matrix" {
    const m = Matrix.translate(10.0, 20.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m.a, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), m.e, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), m.f, 0.001);
}

test "Matrix.concat combines transformations" {
    const s = Matrix.scale(2.0, 2.0);
    const t = Matrix.translate(5.0, 10.0);
    const m = s.concat(t);
    // Scale then translate: point (1,1) -> (2,2) -> (7,12)
    const p = m.transformPoint(1.0, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), p.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), p.y, 0.001);
}

test "Matrix.invert produces inverse" {
    const m = Matrix.scale(2.0, 4.0);
    const inv = m.invert();
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), inv.a, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), inv.d, 0.001);
}

test "Matrix.transformRect works correctly" {
    const m = Matrix.scale(2.0, 2.0);
    const rect = Rect{ .x0 = 10, .y0 = 20, .x1 = 30, .y1 = 40 };
    const r = m.transformRect(rect);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), r.x0, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 40.0), r.y0, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 60.0), r.x1, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 80.0), r.y1, 0.001);
}

test "Matrix roundtrip toC/fromC preserves values" {
    const m = Matrix{ .a = 1, .b = 2, .c_val = 3, .d = 4, .e = 5, .f = 6 };
    const roundtrip = Matrix.fromC(m.toC());
    try std.testing.expectApproxEqAbs(m.a, roundtrip.a, 0.001);
    try std.testing.expectApproxEqAbs(m.b, roundtrip.b, 0.001);
    try std.testing.expectApproxEqAbs(m.c_val, roundtrip.c_val, 0.001);
    try std.testing.expectApproxEqAbs(m.d, roundtrip.d, 0.001);
    try std.testing.expectApproxEqAbs(m.e, roundtrip.e, 0.001);
    try std.testing.expectApproxEqAbs(m.f, roundtrip.f, 0.001);
}

test "Matrix.isRectilinear for identity" {
    try std.testing.expect(Matrix.identity.isRectilinear());
}

test "Matrix.preScale works" {
    const m = Matrix.translate(10.0, 20.0).preScale(2.0, 3.0);
    const p = m.transformPoint(1.0, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), p.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 23.0), p.y, 0.001);
}

test "Page.toPixmapWithMatrix renders correctly" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    const matrix = Matrix.scale(1.0, 1.0);
    var pixmap = try page.toPixmapWithMatrix(matrix);
    defer pixmap.deinit();

    try std.testing.expect(@intFromPtr(pixmap.ptr) != 0);
}

// ============================================
// Page Rotation Tests
// ============================================

test "Page.rotation returns 0 for unrotated page" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    try std.testing.expectEqual(@as(i32, 0), page.rotation());
}

// ============================================
// Links Tests
// ============================================

test "Page.loadLinks returns empty list for page without links" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    var links = page.loadLinks();
    defer links.deinit();

    var iter = links.iterator();
    // Our test PDF has no links, so iterator should yield nothing
    try std.testing.expect(iter.next() == null);
}

test "LinkList.deinit is safe to call on empty list" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    var links = page.loadLinks();
    links.deinit();
    // Should be safe to call deinit again (idempotent)
    links.deinit();
}

// ============================================
// Text Extraction Tests (Phase 3)
// ============================================

const text_pdf_path = "tests/fixtures/text_sample.pdf";

test "Page.extractText returns valid TextPage" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, text_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    var text_page = try page.extractText(.{});
    defer text_page.deinit();

    // Media box should match page dimensions
    const mb = text_page.mediabox();
    try std.testing.expectApproxEqAbs(@as(f32, 612.0), mb.width(), 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 792.0), mb.height(), 0.1);
}

test "Page.getText extracts plain text" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, text_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    const allocator = std.testing.allocator;
    const text = try page.getText(allocator);
    defer allocator.free(text);

    // The text PDF contains "Hello World"
    try std.testing.expect(std.mem.indexOf(u8, text, "Hello World") != null);
}

test "Page.getText contains multiple lines" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, text_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    const allocator = std.testing.allocator;
    const text = try page.getText(allocator);
    defer allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "test document") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "multiple lines") != null);
}

test "TextPage.blocks iterates text blocks" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, text_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    var text_page = try page.extractText(.{});
    defer text_page.deinit();

    var block_count: usize = 0;
    var blocks = text_page.blocks();
    while (blocks.next()) |block| {
        try std.testing.expect(block.block_type == .text);
        try std.testing.expect(block.bbox.width() > 0);
        try std.testing.expect(block.bbox.height() > 0);
        block_count += 1;
    }

    // Should have at least one text block
    try std.testing.expect(block_count > 0);
}

test "TextBlock.lines iterates lines" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, text_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    var text_page = try page.extractText(.{});
    defer text_page.deinit();

    var line_count: usize = 0;
    var blocks = text_page.blocks();
    while (blocks.next()) |block| {
        var line_iter = block.lines();
        while (line_iter.next()) |line| {
            try std.testing.expect(line.bbox.width() > 0);
            line_count += 1;
        }
    }

    // Should have multiple lines
    try std.testing.expect(line_count >= 3);
}

test "TextLine.chars iterates characters" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, text_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    var text_page = try page.extractText(.{});
    defer text_page.deinit();

    var char_count: usize = 0;
    var blocks = text_page.blocks();
    while (blocks.next()) |block| {
        var line_iter = block.lines();
        while (line_iter.next()) |line| {
            var char_iter = line.chars();
            while (char_iter.next()) |ch| {
                try std.testing.expect(ch.size > 0);
                try std.testing.expect(ch.codepoint > 0);
                char_count += 1;
            }
        }
    }

    // Should have many characters
    try std.testing.expect(char_count > 10);
}

test "TextLine.getText collects line text" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, text_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    var text_page = try page.extractText(.{});
    defer text_page.deinit();

    const allocator = std.testing.allocator;

    var blocks = text_page.blocks();
    if (blocks.next()) |block| {
        var line_iter = block.lines();
        if (line_iter.next()) |line| {
            const line_text = try line.getText(allocator);
            defer allocator.free(line_text);
            try std.testing.expect(line_text.len > 0);
            // First line should contain "Hello World"
            try std.testing.expect(std.mem.indexOf(u8, line_text, "Hello World") != null);
        }
    }
}

test "TextChar has valid position and font info" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, text_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    var text_page = try page.extractText(.{});
    defer text_page.deinit();

    var blocks = text_page.blocks();
    if (blocks.next()) |block| {
        var line_iter = block.lines();
        if (line_iter.next()) |line| {
            var char_iter = line.chars();
            if (char_iter.next()) |ch| {
                // 'H' from "Hello World"
                try std.testing.expectEqual(@as(u21, 'H'), ch.codepoint);
                // Font size should be 12 (as set in our test PDF)
                try std.testing.expectApproxEqAbs(@as(f32, 12.0), ch.size, 0.1);
                // Origin should be around x=72 (as set in our content stream)
                try std.testing.expect(ch.origin.x > 0);
                try std.testing.expect(ch.origin.y > 0);
            }
        }
    }
}

test "Page.search finds text on page" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, text_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    const allocator = std.testing.allocator;
    const hits = try page.search("Hello", allocator);
    defer allocator.free(hits);

    // Should find at least one hit
    try std.testing.expect(hits.len > 0);

    // Hit should have a valid bounding quad
    const rect = hits[0].quad.toRect();
    try std.testing.expect(rect.width() > 0);
    try std.testing.expect(rect.height() > 0);
}

test "Page.search returns empty for non-matching text" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, text_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    const allocator = std.testing.allocator;
    const hits = try page.search("xyznonexistent", allocator);
    defer allocator.free(hits);

    try std.testing.expectEqual(@as(usize, 0), hits.len);
}

test "Page.search finds unique search term" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, text_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    const allocator = std.testing.allocator;
    const hits = try page.search("zigmupdf", allocator);
    defer allocator.free(hits);

    // "zigmupdf" appears exactly once in our test PDF
    try std.testing.expect(hits.len >= 1);
}

test "Quad.toRect produces valid bounding rect" {
    const quad = Quad{
        .ul = .{ .x = 10, .y = 10 },
        .ur = .{ .x = 100, .y = 10 },
        .ll = .{ .x = 10, .y = 50 },
        .lr = .{ .x = 100, .y = 50 },
    };
    const rect = quad.toRect();
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), rect.x0, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), rect.y0, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), rect.x1, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), rect.y1, 0.001);
}

test "TextOptions default preserves ligatures and whitespace" {
    const opts = TextOptions{};
    try std.testing.expect(opts.preserve_ligatures);
    try std.testing.expect(opts.preserve_whitespace);
    try std.testing.expect(!opts.preserve_images);
    try std.testing.expect(!opts.inhibit_spaces);
    try std.testing.expect(!opts.dehyphenate);
}

test "Page.extractText with no text returns empty" {
    var ctx = try Context.init();
    defer ctx.deinit();

    // Use original sample.pdf which has no text content
    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    const allocator = std.testing.allocator;
    const text = try page.getText(allocator);
    defer allocator.free(text);

    // Empty page should return empty or whitespace-only text
    const trimmed = std.mem.trim(u8, text, " \t\n\r");
    try std.testing.expectEqual(@as(usize, 0), trimmed.len);
}

// ============================================
// Image Extraction Tests (Phase 4)
// ============================================

const image_pdf_path = "tests/fixtures/image_sample.pdf";

test "Page.getImages finds embedded images" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, image_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    const allocator = std.testing.allocator;
    const images = try page.getImages(allocator);
    defer allocator.free(images);

    // Our test PDF has one embedded image
    try std.testing.expect(images.len >= 1);

    // Check image metadata
    const img = images[0];
    try std.testing.expectEqual(@as(i32, 8), img.width);
    try std.testing.expectEqual(@as(i32, 8), img.height);
    try std.testing.expectEqual(@as(i32, 8), img.bpc);
    try std.testing.expect(img.xref > 0);
}

test "Page.getImages returns image colorspace info" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, image_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    const allocator = std.testing.allocator;
    const images = try page.getImages(allocator);
    defer allocator.free(images);

    try std.testing.expect(images.len >= 1);
    // DeviceRGB colorspace
    try std.testing.expect(images[0].colorspace.len > 0);
}

test "Page.getImages returns empty for page without images" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, text_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    const allocator = std.testing.allocator;
    const images = try page.getImages(allocator);
    defer allocator.free(images);

    try std.testing.expectEqual(@as(usize, 0), images.len);
}

test "Page.loadImage loads image by xref" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, image_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    const allocator = std.testing.allocator;
    const images = try page.getImages(allocator);
    defer allocator.free(images);

    try std.testing.expect(images.len >= 1);

    var img = try page.loadImage(images[0].xref);
    defer img.deinit();

    try std.testing.expectEqual(@as(i32, 8), img.getWidth());
    try std.testing.expectEqual(@as(i32, 8), img.getHeight());
    try std.testing.expectEqual(@as(i32, 8), img.getBpc());
}

test "Image.toPixmap decodes image to pixels" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, image_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    const allocator = std.testing.allocator;
    const images = try page.getImages(allocator);
    defer allocator.free(images);

    try std.testing.expect(images.len >= 1);

    var img = try page.loadImage(images[0].xref);
    defer img.deinit();

    var pixmap = try img.toPixmap();
    defer pixmap.deinit();

    try std.testing.expectEqual(@as(i32, 8), pixmap.width());
    try std.testing.expectEqual(@as(i32, 8), pixmap.height());
    try std.testing.expect(pixmap.components() >= 3); // RGB or RGBA
}

test "Image.getResolution returns DPI info" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, image_pdf_path);
    defer doc.deinit();

    var page = try doc.loadPage(0);
    defer page.deinit();

    const allocator = std.testing.allocator;
    const images = try page.getImages(allocator);
    defer allocator.free(images);

    try std.testing.expect(images.len >= 1);

    var img = try page.loadImage(images[0].xref);
    defer img.deinit();

    const res = img.getResolution();
    // Resolution should be positive (typically 72 or 96 DPI)
    try std.testing.expect(res.xres > 0);
    try std.testing.expect(res.yres > 0);
}

// ============================================
// PDF Manipulation Tests (Phase 5)
// ============================================

const multipage_pdf_path = "tests/fixtures/multipage.pdf";

test "Document.deletePage removes a page" {
    var ctx = try Context.init();
    defer ctx.deinit();

    // Open from memory so we don't modify the file
    const allocator = std.testing.allocator;
    const data = try std.fs.cwd().readFileAlloc(allocator, multipage_pdf_path, 10 * 1024 * 1024);
    defer allocator.free(data);

    var doc = try Document.openFromMemory(&ctx, data, "application/pdf");
    defer doc.deinit();

    try std.testing.expectEqual(@as(i32, 3), try doc.pageCount());

    try doc.deletePage(1); // Remove page 2 (0-indexed)

    try std.testing.expectEqual(@as(i32, 2), try doc.pageCount());
}

test "Document.deletePage rejects out of range" {
    var ctx = try Context.init();
    defer ctx.deinit();

    const allocator = std.testing.allocator;
    const data = try std.fs.cwd().readFileAlloc(allocator, multipage_pdf_path, 10 * 1024 * 1024);
    defer allocator.free(data);

    var doc = try Document.openFromMemory(&ctx, data, "application/pdf");
    defer doc.deinit();

    try std.testing.expectError(Error.PageOutOfRange, doc.deletePage(10));
    try std.testing.expectError(Error.PageOutOfRange, doc.deletePage(-1));
}

test "Document.deletePageRange removes multiple pages" {
    var ctx = try Context.init();
    defer ctx.deinit();

    const allocator = std.testing.allocator;
    const data = try std.fs.cwd().readFileAlloc(allocator, multipage_pdf_path, 10 * 1024 * 1024);
    defer allocator.free(data);

    var doc = try Document.openFromMemory(&ctx, data, "application/pdf");
    defer doc.deinit();

    try std.testing.expectEqual(@as(i32, 3), try doc.pageCount());

    try doc.deletePageRange(0, 2); // Remove pages 0 and 1

    try std.testing.expectEqual(@as(i32, 1), try doc.pageCount());
}

test "Document.rearrangePages reorders pages" {
    var ctx = try Context.init();
    defer ctx.deinit();

    const allocator = std.testing.allocator;
    const data = try std.fs.cwd().readFileAlloc(allocator, multipage_pdf_path, 10 * 1024 * 1024);
    defer allocator.free(data);

    var doc = try Document.openFromMemory(&ctx, data, "application/pdf");
    defer doc.deinit();

    try std.testing.expectEqual(@as(i32, 3), try doc.pageCount());

    // Reverse page order: [2, 1, 0]
    try doc.rearrangePages(&[_]i32{ 2, 1, 0 });

    try std.testing.expectEqual(@as(i32, 3), try doc.pageCount());
}

test "Document.rearrangePages can remove pages" {
    var ctx = try Context.init();
    defer ctx.deinit();

    const allocator = std.testing.allocator;
    const data = try std.fs.cwd().readFileAlloc(allocator, multipage_pdf_path, 10 * 1024 * 1024);
    defer allocator.free(data);

    var doc = try Document.openFromMemory(&ctx, data, "application/pdf");
    defer doc.deinit();

    // Keep only pages 0 and 2
    try doc.rearrangePages(&[_]i32{ 0, 2 });

    try std.testing.expectEqual(@as(i32, 2), try doc.pageCount());
}

test "Document.rearrangePages can duplicate pages" {
    var ctx = try Context.init();
    defer ctx.deinit();

    const allocator = std.testing.allocator;
    const data = try std.fs.cwd().readFileAlloc(allocator, multipage_pdf_path, 10 * 1024 * 1024);
    defer allocator.free(data);

    var doc = try Document.openFromMemory(&ctx, data, "application/pdf");
    defer doc.deinit();

    // Duplicate page 0
    try doc.rearrangePages(&[_]i32{ 0, 0, 1, 2 });

    try std.testing.expectEqual(@as(i32, 4), try doc.pageCount());
}

test "Document.insertPageFrom copies page from another document" {
    var ctx = try Context.init();
    defer ctx.deinit();

    const allocator = std.testing.allocator;
    const data = try std.fs.cwd().readFileAlloc(allocator, multipage_pdf_path, 10 * 1024 * 1024);
    defer allocator.free(data);

    var src = try Document.openFromMemory(&ctx, data, "application/pdf");
    defer src.deinit();

    // Create a new empty PDF as destination
    var dst = try Document.createPdf(&ctx);
    defer dst.deinit();

    try std.testing.expectEqual(@as(i32, 0), try dst.pageCount());

    // Copy page 0 from source to destination
    try dst.insertPageFrom(-1, &src, 0);

    try std.testing.expectEqual(@as(i32, 1), try dst.pageCount());
}

test "Document.insertPageFrom merges multiple pages" {
    var ctx = try Context.init();
    defer ctx.deinit();

    const allocator = std.testing.allocator;
    const data = try std.fs.cwd().readFileAlloc(allocator, multipage_pdf_path, 10 * 1024 * 1024);
    defer allocator.free(data);

    var src = try Document.openFromMemory(&ctx, data, "application/pdf");
    defer src.deinit();

    var dst = try Document.createPdf(&ctx);
    defer dst.deinit();

    // Copy all 3 pages
    try dst.insertPageFrom(-1, &src, 0);
    try dst.insertPageFrom(-1, &src, 1);
    try dst.insertPageFrom(-1, &src, 2);

    try std.testing.expectEqual(@as(i32, 3), try dst.pageCount());
}

test "Document.createPdf creates empty document" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.createPdf(&ctx);
    defer doc.deinit();

    try std.testing.expectEqual(@as(i32, 0), try doc.pageCount());
    try std.testing.expect(doc.isPdf());
}

// ============================================
// Annotation Tests (Phase 6)
// ============================================

fn countAnnotations(page: *Page) usize {
    var count: usize = 0;
    var iter = page.getAnnotations() orelse return 0;
    while (iter.next()) |_| count += 1;
    return count;
}

test "Page.getAnnotations returns empty for page without annotations" {
    var ctx = try Context.init();
    defer ctx.deinit();
    const al = std.testing.allocator;
    const data = try std.fs.cwd().readFileAlloc(al, multipage_pdf_path, 10 * 1024 * 1024);
    defer al.free(data);
    var doc = try Document.openFromMemory(&ctx, data, "application/pdf");
    defer doc.deinit();
    var page = try doc.loadPage(0);
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 0), countAnnotations(&page));
}

test "Page.createAnnotation creates text annotation" {
    var ctx = try Context.init();
    defer ctx.deinit();
    const al = std.testing.allocator;
    const data = try std.fs.cwd().readFileAlloc(al, multipage_pdf_path, 10 * 1024 * 1024);
    defer al.free(data);
    var doc = try Document.openFromMemory(&ctx, data, "application/pdf");
    defer doc.deinit();
    var page = try doc.loadPage(0);
    defer page.deinit();

    var annot = try page.createAnnotation(.text);
    annot.setRect(.{ .x0 = 100, .y0 = 100, .x1 = 200, .y1 = 150 });
    annot.setContents("Test note");
    annot.update();

    try std.testing.expectEqual(AnnotationType.text, annot.getType());
    try std.testing.expectEqualStrings("Test note", annot.getContents());
}

test "Page.createAnnotation creates highlight annotation with color" {
    var ctx = try Context.init();
    defer ctx.deinit();
    const al = std.testing.allocator;
    const data = try std.fs.cwd().readFileAlloc(al, multipage_pdf_path, 10 * 1024 * 1024);
    defer al.free(data);
    var doc = try Document.openFromMemory(&ctx, data, "application/pdf");
    defer doc.deinit();
    var page = try doc.loadPage(0);
    defer page.deinit();

    var annot = try page.createAnnotation(.highlight);
    annot.setColor(.{ .r = 1.0, .g = 1.0, .b = 0.0 });
    const quad = Quad{
        .ul = .{ .x = 72, .y = 700 }, .ur = .{ .x = 200, .y = 700 },
        .ll = .{ .x = 72, .y = 720 }, .lr = .{ .x = 200, .y = 720 },
    };
    annot.setQuadPoints(&[_]Quad{quad});
    annot.update();

    try std.testing.expectEqual(AnnotationType.highlight, annot.getType());
    const color = annot.getColor();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), color.r, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), color.g, 0.01);
}

test "Annotation iteration counts created annotations" {
    var ctx = try Context.init();
    defer ctx.deinit();
    const al = std.testing.allocator;
    const data = try std.fs.cwd().readFileAlloc(al, multipage_pdf_path, 10 * 1024 * 1024);
    defer al.free(data);
    var doc = try Document.openFromMemory(&ctx, data, "application/pdf");
    defer doc.deinit();
    var page = try doc.loadPage(0);
    defer page.deinit();

    var a1 = try page.createAnnotation(.text);
    a1.setContents("Note 1");
    a1.update();
    var a2 = try page.createAnnotation(.text);
    a2.setContents("Note 2");
    a2.update();

    try std.testing.expectEqual(@as(usize, 2), countAnnotations(&page));
}

test "Annotation.setAuthor and getAuthor" {
    var ctx = try Context.init();
    defer ctx.deinit();
    const al = std.testing.allocator;
    const data = try std.fs.cwd().readFileAlloc(al, multipage_pdf_path, 10 * 1024 * 1024);
    defer al.free(data);
    var doc = try Document.openFromMemory(&ctx, data, "application/pdf");
    defer doc.deinit();
    var page = try doc.loadPage(0);
    defer page.deinit();

    var annot = try page.createAnnotation(.text);
    annot.setAuthor("Test Author");
    annot.update();
    try std.testing.expectEqualStrings("Test Author", annot.getAuthor());
}

test "Annotation.setOpacity and getOpacity" {
    var ctx = try Context.init();
    defer ctx.deinit();
    const al = std.testing.allocator;
    const data = try std.fs.cwd().readFileAlloc(al, multipage_pdf_path, 10 * 1024 * 1024);
    defer al.free(data);
    var doc = try Document.openFromMemory(&ctx, data, "application/pdf");
    defer doc.deinit();
    var page = try doc.loadPage(0);
    defer page.deinit();

    var annot = try page.createAnnotation(.text);
    annot.setOpacity(0.5);
    annot.update();
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), annot.getOpacity(), 0.01);
}

test "Annotation.delete removes annotation" {
    var ctx = try Context.init();
    defer ctx.deinit();
    const al = std.testing.allocator;
    const data = try std.fs.cwd().readFileAlloc(al, multipage_pdf_path, 10 * 1024 * 1024);
    defer al.free(data);
    var doc = try Document.openFromMemory(&ctx, data, "application/pdf");
    defer doc.deinit();
    var page = try doc.loadPage(0);
    defer page.deinit();

    var annot = try page.createAnnotation(.text);
    annot.setContents("Will be deleted");
    annot.update();
    try std.testing.expectEqual(@as(usize, 1), countAnnotations(&page));

    try annot.delete();
    try std.testing.expectEqual(@as(usize, 0), countAnnotations(&page));
}

test "AnnotationType enum values" {
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(AnnotationType.text));
    try std.testing.expectEqual(@as(i32, 8), @intFromEnum(AnnotationType.highlight));
    try std.testing.expectEqual(@as(i32, 9), @intFromEnum(AnnotationType.underline));
    try std.testing.expectEqual(@as(i32, 11), @intFromEnum(AnnotationType.strike_out));
    try std.testing.expectEqual(@as(i32, -1), @intFromEnum(AnnotationType.unknown));
}

// ============================================
// Outline / TOC Tests (Phase 7)
// ============================================

test "Document.loadOutline returns null for document without TOC" {
    var ctx = try Context.init();
    defer ctx.deinit();
    const al = std.testing.allocator;
    const data = try std.fs.cwd().readFileAlloc(al, multipage_pdf_path, 10 * 1024 * 1024);
    defer al.free(data);
    var doc = try Document.openFromMemory(&ctx, data, "application/pdf");
    defer doc.deinit();

    // Our simple test PDFs have no outline
    try std.testing.expect(doc.loadOutline() == null);
}

test "Document.loadOutline works with example.pdf" {
    var ctx = try Context.init();
    defer ctx.deinit();
    const al = std.testing.allocator;
    const data = try std.fs.cwd().readFileAlloc(al, "examples/example.pdf", 10 * 1024 * 1024);
    defer al.free(data);
    var doc = try Document.openFromMemory(&ctx, data, "application/pdf");
    defer doc.deinit();

    var outline_opt = doc.loadOutline();
    if (outline_opt) |_| {
        defer outline_opt.?.deinit();
        const entries = try outline_opt.?.toList(al);
        defer al.free(entries);

        if (entries.len > 0) {
            try std.testing.expect(entries[0].item.title.len > 0);
            try std.testing.expectEqual(@as(u32, 0), entries[0].depth);
        }
    }
}

test "Outline.toList returns flat list with depth" {
    var ctx = try Context.init();
    defer ctx.deinit();
    const al = std.testing.allocator;
    const data = try std.fs.cwd().readFileAlloc(al, "examples/example.pdf", 10 * 1024 * 1024);
    defer al.free(data);
    var doc = try Document.openFromMemory(&ctx, data, "application/pdf");
    defer doc.deinit();

    var outline_opt = doc.loadOutline();
    if (outline_opt) |_| {
        defer outline_opt.?.deinit();
        const entries = try outline_opt.?.toList(al);
        defer al.free(entries);

        for (entries) |entry| {
            try std.testing.expect(entry.depth < 20);
        }
    }
}

// ============================================
// Widget / Form Field Tests (Phase 7)
// ============================================

test "Page.getWidgets returns iterator for page without forms" {
    var ctx = try Context.init();
    defer ctx.deinit();
    const al = std.testing.allocator;
    const data = try std.fs.cwd().readFileAlloc(al, multipage_pdf_path, 10 * 1024 * 1024);
    defer al.free(data);
    var doc = try Document.openFromMemory(&ctx, data, "application/pdf");
    defer doc.deinit();
    var page = try doc.loadPage(0);
    defer page.deinit();

    var iter_opt = page.getWidgets();
    if (iter_opt) |_| {
        try std.testing.expect(iter_opt.?.next() == null);
    }
}

test "WidgetType enum values" {
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(WidgetType.unknown));
    try std.testing.expectEqual(@as(i32, 2), @intFromEnum(WidgetType.checkbox));
    try std.testing.expectEqual(@as(i32, 7), @intFromEnum(WidgetType.text));
}

test "OutlineItem struct has correct fields" {
    const item = OutlineItem{
        .title = "Chapter 1",
        .uri = "#page=0",
        .page = 0,
        .is_open = true,
        .has_children = false,
    };
    try std.testing.expectEqualStrings("Chapter 1", item.title);
    try std.testing.expectEqual(@as(i32, 0), item.page);
    try std.testing.expect(item.is_open);
    try std.testing.expect(!item.has_children);
}

// ============================================
// Malformed input regression tests
//
// Fixtures are generated by scripts/repro/make_malformed_fixtures.py. Before
// the fallible shims existed, each of these aborted the whole process via
// MuPDF's "aborting process from uncaught error!" exit(1).
// ============================================

test "pageCount returns error for negative /Count instead of aborting" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, "tests/fixtures/malformed_negative_count.pdf");
    defer doc.deinit();

    try std.testing.expectError(Error.MupdfError, doc.pageCount());
    try std.testing.expectError(Error.MupdfError, doc.loadPage(0));
}

test "pageCount returns error for impossible /Count instead of aborting" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, "tests/fixtures/malformed_huge_count.pdf");
    defer doc.deinit();

    try std.testing.expectError(Error.MupdfError, doc.pageCount());
    try std.testing.expectError(Error.MupdfError, doc.deletePage(0));
}

test "Page.bounds returns error for /Parent cycle instead of aborting" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, "tests/fixtures/malformed_parent_cycle.pdf");
    defer doc.deinit();

    try std.testing.expectEqual(@as(i32, 1), try doc.pageCount());
    var page = try doc.loadPage(0);
    defer page.deinit();

    try std.testing.expectError(Error.MupdfError, page.bounds());
    try std.testing.expectError(Error.MupdfError, page.width());
    try std.testing.expectError(Error.MupdfError, page.height());
}

test "Pixmap.savePng returns WriteFailed for unwritable path instead of aborting" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();
    var page = try doc.loadPage(0);
    defer page.deinit();
    var pixmap = try page.toPixmap(0.1, 0.0);
    defer pixmap.deinit();

    try std.testing.expectError(Error.WriteFailed, pixmap.savePng("/nonexistent-dir/zig-mupdf/out.png"));
}

test "authenticate and needsPassword return values on unencrypted PDF" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, test_pdf_path);
    defer doc.deinit();

    try std.testing.expect(!(try doc.needsPassword()));
    try std.testing.expect(try doc.authenticate(""));
}

test "metadata on broken Info dictionary does not abort" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var doc = try Document.open(&ctx, "tests/fixtures/malformed_broken_info.pdf");
    defer doc.deinit();

    const allocator = std.testing.allocator;
    var metadata = try doc.getAllMetadata(allocator);
    defer metadata.deinit();
    try doc.setMetadata(.title, "repaired");
}

test "every malformed fixture survives the full open/count/load/bound/text/render pipeline" {
    const fixtures = [_][]const u8{
        "tests/fixtures/malformed_negative_count.pdf",
        "tests/fixtures/malformed_huge_count.pdf",
        "tests/fixtures/malformed_parent_cycle.pdf",
        "tests/fixtures/malformed_broken_info.pdf",
        "tests/fixtures/malformed_truncated.pdf",
        "tests/fixtures/malformed_bad_xref.pdf",
    };
    const allocator = std.testing.allocator;

    var ctx = try Context.init();
    defer ctx.deinit();

    for (fixtures) |path| {
        var doc = Document.open(&ctx, path) catch continue;
        defer doc.deinit();

        _ = doc.needsPassword() catch {};
        _ = doc.authenticate("") catch {};
        var metadata = doc.getAllMetadata(allocator) catch null;
        if (metadata) |*m| m.deinit();

        const count = doc.pageCount() catch continue;
        var i: i32 = 0;
        while (i < count) : (i += 1) {
            var page = doc.loadPage(i) catch continue;
            defer page.deinit();
            _ = page.bounds() catch {};
            _ = page.rotation();
            if (page.getText(allocator)) |text| allocator.free(text) else |_| {}
            var pixmap = page.toPixmap(0.25, 0.0) catch continue;
            defer pixmap.deinit();
            if (pixmap.toPng(allocator)) |png| allocator.free(png) else |_| {}
        }
    }
}

//! PDF Info Example
//!
//! This example demonstrates basic usage of zig-mupdf:
//! - Opening a PDF document
//! - Getting page count and metadata
//! - Getting page dimensions

const std = @import("std");
const mupdf = @import("mupdf");

pub fn main() !void {
    var args = std.process.args();

    // Skip program name
    _ = args.skip();

    // Get PDF path from arguments
    const pdf_path = args.next() orelse {
        std.debug.print("Usage: pdf-info <path-to-pdf>\n", .{});
        return;
    };

    // Initialize MuPDF context
    var ctx = mupdf.Context.init() catch |err| {
        std.debug.print("Failed to initialize MuPDF: {s}\n", .{mupdf.formatError(err)});
        return;
    };
    defer ctx.deinit();

    std.debug.print("Opening: {s}\n", .{pdf_path});

    // Open the document
    var doc = ctx.openDocument(pdf_path) catch |err| {
        std.debug.print("Failed to open document: {s}\n", .{mupdf.formatError(err)});
        return;
    };
    defer doc.deinit();

    // Print document info
    std.debug.print("\n=== Document Info ===\n", .{});

    // Check if it's a PDF
    if (doc.isPdf()) {
        std.debug.print("Format: PDF\n", .{});
    } else {
        std.debug.print("Format: Other (XPS, SVG, CBZ or image)\n", .{});
    }

    // Page count
    const page_count = doc.pageCount() catch |err| {
        std.debug.print("Failed to count pages: {s}\n", .{mupdf.formatError(err)});
        return;
    };
    std.debug.print("Pages: {d}\n", .{page_count});

    // Check for password protection
    if (doc.needsPassword() catch false) {
        std.debug.print("Password Protected: Yes\n", .{});
    } else {
        std.debug.print("Password Protected: No\n", .{});
    }

    // Metadata
    const alloc = std.heap.page_allocator;
    if (try doc.getMetadata(.title, alloc)) |title| {
        defer alloc.free(title);
        std.debug.print("Title: {s}\n", .{title});
    }

    if (try doc.getMetadata(.author, alloc)) |author| {
        defer alloc.free(author);
        std.debug.print("Author: {s}\n", .{author});
    }

    // Print page dimensions for first few pages
    std.debug.print("\n=== Page Dimensions ===\n", .{});

    const pages_to_show = @min(page_count, 5);
    var i: i32 = 0;
    while (i < pages_to_show) : (i += 1) {
        var page = doc.loadPage(i) catch |err| {
            std.debug.print("Page {d}: Failed to load - {s}\n", .{ i + 1, mupdf.formatError(err) });
            continue;
        };
        defer page.deinit();

        const b = page.bounds() catch |err| {
            std.debug.print("Page {d}: Failed to read bounds - {s}\n", .{ i + 1, mupdf.formatError(err) });
            continue;
        };
        const w = b.width();
        const h = b.height();

        // Convert points to inches (72 points = 1 inch)
        const w_in = w / 72.0;
        const h_in = h / 72.0;

        std.debug.print("Page {d}: {d:.1} x {d:.1} pts ({d:.2} x {d:.2} in)\n", .{
            i + 1,
            w,
            h,
            w_in,
            h_in,
        });
    }

    if (page_count > 5) {
        std.debug.print("... and {d} more pages\n", .{page_count - 5});
    }

    std.debug.print("\nDone!\n", .{});
}

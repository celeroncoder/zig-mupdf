//! Error types for zig-mupdf.
//!
//! MuPDF uses setjmp/longjmp for error handling. This module provides
//! Zig-friendly error types that map to MuPDF's error conditions.

const std = @import("std");

/// Errors that can occur when working with MuPDF.
pub const Error = error{
    /// Failed to allocate memory.
    OutOfMemory,

    /// Failed to open or read a document.
    OpenFailed,

    /// The document format is not supported.
    UnsupportedFormat,

    /// The document is encrypted and requires a password.
    NeedsPassword,

    /// Invalid password provided.
    InvalidPassword,

    /// The page number is out of range.
    PageOutOfRange,

    /// Failed to render a page.
    RenderFailed,

    /// Failed to extract text from a page.
    TextExtractionFailed,

    /// Failed to create a pixmap.
    PixmapCreationFailed,

    /// Failed to write output.
    WriteFailed,

    /// Generic MuPDF error.
    MupdfError,

    /// Invalid argument provided.
    InvalidArgument,

    /// Context creation failed.
    ContextCreationFailed,

    /// Document is not a PDF.
    NotAPdf,

    /// Failed to save document.
    SaveFailed,

    /// Failed to search text.
    SearchFailed,
};

/// Convert a MuPDF error code to a Zig error.
/// Note: MuPDF typically uses setjmp/longjmp, so this is mainly for
/// cases where we can detect errors through return values.
pub fn fromMupdf(code: c_int) Error {
    return switch (code) {
        0 => Error.MupdfError, // No error, but this shouldn't be called
        else => Error.MupdfError,
    };
}

/// Format an error message.
pub fn format(err: Error) []const u8 {
    return switch (err) {
        Error.OutOfMemory => "Out of memory",
        Error.OpenFailed => "Failed to open document",
        Error.UnsupportedFormat => "Unsupported document format",
        Error.NeedsPassword => "Document requires a password",
        Error.InvalidPassword => "Invalid password",
        Error.PageOutOfRange => "Page number out of range",
        Error.RenderFailed => "Failed to render page",
        Error.TextExtractionFailed => "Failed to extract text",
        Error.PixmapCreationFailed => "Failed to create pixmap",
        Error.WriteFailed => "Failed to write output",
        Error.MupdfError => "MuPDF error",
        Error.InvalidArgument => "Invalid argument",
        Error.ContextCreationFailed => "Failed to create context",
        Error.NotAPdf => "Document is not a PDF",
        Error.SaveFailed => "Failed to save document",
        Error.SearchFailed => "Failed to search text",
    };
}

// ============================================
// Unit Tests
// ============================================

test "format returns correct message for all errors" {
    // Test each error type has a non-empty message
    try std.testing.expect(format(Error.OutOfMemory).len > 0);
    try std.testing.expect(format(Error.OpenFailed).len > 0);
    try std.testing.expect(format(Error.UnsupportedFormat).len > 0);
    try std.testing.expect(format(Error.NeedsPassword).len > 0);
    try std.testing.expect(format(Error.InvalidPassword).len > 0);
    try std.testing.expect(format(Error.PageOutOfRange).len > 0);
    try std.testing.expect(format(Error.RenderFailed).len > 0);
    try std.testing.expect(format(Error.TextExtractionFailed).len > 0);
    try std.testing.expect(format(Error.PixmapCreationFailed).len > 0);
    try std.testing.expect(format(Error.WriteFailed).len > 0);
    try std.testing.expect(format(Error.MupdfError).len > 0);
    try std.testing.expect(format(Error.InvalidArgument).len > 0);
    try std.testing.expect(format(Error.ContextCreationFailed).len > 0);
    try std.testing.expect(format(Error.NotAPdf).len > 0);
    try std.testing.expect(format(Error.SaveFailed).len > 0);
    try std.testing.expect(format(Error.SearchFailed).len > 0);
}

test "format messages are unique" {
    // Ensure each error has a distinct message
    const messages = [_][]const u8{
        format(Error.OutOfMemory),
        format(Error.OpenFailed),
        format(Error.UnsupportedFormat),
        format(Error.NeedsPassword),
        format(Error.InvalidPassword),
        format(Error.PageOutOfRange),
        format(Error.RenderFailed),
        format(Error.TextExtractionFailed),
        format(Error.PixmapCreationFailed),
        format(Error.WriteFailed),
        format(Error.MupdfError),
        format(Error.InvalidArgument),
        format(Error.ContextCreationFailed),
        format(Error.NotAPdf),
        format(Error.SaveFailed),
        format(Error.SearchFailed),
    };

    // Check that no two messages are the same
    for (messages, 0..) |msg1, i| {
        for (messages[i + 1 ..]) |msg2| {
            try std.testing.expect(!std.mem.eql(u8, msg1, msg2));
        }
    }
}

test "fromMupdf returns MupdfError for unknown codes" {
    try std.testing.expectEqual(Error.MupdfError, fromMupdf(0));
    try std.testing.expectEqual(Error.MupdfError, fromMupdf(1));
    try std.testing.expectEqual(Error.MupdfError, fromMupdf(-1));
}

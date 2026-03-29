//! zig-mupdf HTTP Server
//!
//! A simple HTTP server exposing PDF processing endpoints.
//!
//! Usage:
//!   zig build run-server
//!   # Then use curl to test:
//!   curl http://localhost:8080/health
//!   curl -X POST -F "file=@doc.pdf" http://localhost:8080/info
//!   curl -X POST -F "file=@doc.pdf" -F "page=0" http://localhost:8080/text
//!   curl -X POST -F "file=@doc.pdf" -F "page=0" -F "query=hello" http://localhost:8080/search
//!   curl -X POST -F "file=@doc.pdf" -F "page=0" --output page.png http://localhost:8080/render

const std = @import("std");
const mupdf = @import("mupdf");

const allocator = std.heap.page_allocator;

// ============================================
// HTTP Server Core
// ============================================

const Request = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8,
    content_type: []const u8,
    raw_header: []const u8,
};

const Response = struct {
    status: []const u8 = "200 OK",
    content_type: []const u8 = "application/json",
    body: []const u8 = "",
};

fn parseRequest(buf: []const u8) ?Request {
    // Find end of headers
    const header_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return null;
    const header_section = buf[0..header_end];
    const body = buf[header_end + 4 ..];

    // Parse request line
    const first_line_end = std.mem.indexOf(u8, header_section, "\r\n") orelse return null;
    const request_line = header_section[0..first_line_end];

    // METHOD PATH HTTP/1.x
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return null;
    const path = parts.next() orelse return null;

    // Find Content-Type header
    var content_type: []const u8 = "";
    var lines = std.mem.splitSequence(u8, header_section, "\r\n");
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-type:")) {
            content_type = std.mem.trim(u8, line["content-type:".len..], " ");
            break;
        }
    }

    return Request{
        .method = method,
        .path = path,
        .body = body,
        .content_type = content_type,
        .raw_header = header_section,
    };
}

fn sendResponse(stream: std.net.Stream, response: Response) void {
    var header_buf: [1024]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n", .{
        response.status,
        response.content_type,
        response.body.len,
    }) catch return;

    _ = stream.write(header) catch return;
    if (response.body.len > 0) {
        _ = stream.write(response.body) catch return;
    }
}

fn sendError(stream: std.net.Stream, status: []const u8, message: []const u8) void {
    var buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}", .{message}) catch return;
    sendResponse(stream, .{
        .status = status,
        .content_type = "application/json",
        .body = body,
    });
}

// ============================================
// Multipart Form Parser
// ============================================

const FormData = struct {
    file_data: ?[]const u8 = null,
    page: i32 = 0,
    query: ?[]const u8 = null,
    scale: f32 = 1.0,
};

fn parseMultipart(content_type: []const u8, body: []const u8) FormData {
    var result = FormData{};

    // Extract boundary from content-type
    const boundary_prefix = "boundary=";
    const boundary_start = std.mem.indexOf(u8, content_type, boundary_prefix) orelse return result;
    var boundary_value = content_type[boundary_start + boundary_prefix.len ..];
    // Remove quotes if present
    if (boundary_value.len > 0 and boundary_value[0] == '"') {
        boundary_value = boundary_value[1..];
        if (std.mem.indexOf(u8, boundary_value, "\"")) |end| {
            boundary_value = boundary_value[0..end];
        }
    }

    // Build delimiter: "--" + boundary
    var delim_buf: [256]u8 = undefined;
    const delim = std.fmt.bufPrint(&delim_buf, "--{s}", .{boundary_value}) catch return result;

    // Split by boundary
    var parts = std.mem.splitSequence(u8, body, delim);
    while (parts.next()) |part| {
        if (part.len < 4) continue;
        // Skip leading \r\n
        const trimmed = if (std.mem.startsWith(u8, part, "\r\n")) part[2..] else part;

        // Find header/body separator
        const sep = std.mem.indexOf(u8, trimmed, "\r\n\r\n") orelse continue;
        const part_header = trimmed[0..sep];
        const part_body = trimmed[sep + 4 ..];

        // Remove trailing \r\n from body
        const clean_body = if (part_body.len >= 2 and std.mem.endsWith(u8, part_body, "\r\n"))
            part_body[0 .. part_body.len - 2]
        else
            part_body;

        // Check field name
        if (std.mem.indexOf(u8, part_header, "name=\"file\"") != null) {
            result.file_data = clean_body;
        } else if (std.mem.indexOf(u8, part_header, "name=\"page\"") != null) {
            result.page = std.fmt.parseInt(i32, std.mem.trim(u8, clean_body, " \r\n"), 10) catch 0;
        } else if (std.mem.indexOf(u8, part_header, "name=\"query\"") != null) {
            result.query = clean_body;
        } else if (std.mem.indexOf(u8, part_header, "name=\"scale\"") != null) {
            result.scale = std.fmt.parseFloat(f32, std.mem.trim(u8, clean_body, " \r\n")) catch 1.0;
        }
    }

    return result;
}

// ============================================
// JSON Helpers
// ============================================

fn jsonEscape(input: []const u8, buf: []u8) []const u8 {
    var i: usize = 0;
    for (input) |ch| {
        if (i + 6 >= buf.len) break;
        switch (ch) {
            '"' => {
                buf[i] = '\\';
                buf[i + 1] = '"';
                i += 2;
            },
            '\\' => {
                buf[i] = '\\';
                buf[i + 1] = '\\';
                i += 2;
            },
            '\n' => {
                buf[i] = '\\';
                buf[i + 1] = 'n';
                i += 2;
            },
            '\r' => {
                buf[i] = '\\';
                buf[i + 1] = 'r';
                i += 2;
            },
            '\t' => {
                buf[i] = '\\';
                buf[i + 1] = 't';
                i += 2;
            },
            else => {
                if (ch < 0x20) {
                    // Skip control characters
                } else {
                    buf[i] = ch;
                    i += 1;
                }
            },
        }
    }
    return buf[0..i];
}

// ============================================
// Route Handlers
// ============================================

fn handleHealth(stream: std.net.Stream) void {
    sendResponse(stream, .{
        .body = "{\"status\":\"ok\",\"service\":\"zig-mupdf\"}",
    });
}

fn handleInfo(stream: std.net.Stream, form: FormData) void {
    const file_data = form.file_data orelse {
        sendError(stream, "400 Bad Request", "No file uploaded. Use: curl -F file=@doc.pdf ...");
        return;
    };

    var ctx = mupdf.Context.init() catch {
        sendError(stream, "500 Internal Server Error", "Failed to init MuPDF context");
        return;
    };
    defer ctx.deinit();

    var doc = mupdf.Document.openFromMemory(&ctx, file_data, "application/pdf") catch {
        sendError(stream, "400 Bad Request", "Failed to open PDF");
        return;
    };
    defer doc.deinit();

    const page_count = doc.pageCount();
    const is_pdf = doc.isPdf();
    const needs_password = doc.needsPassword();

    // Get metadata
    var title_esc_buf: [2048]u8 = undefined;
    var author_esc_buf: [2048]u8 = undefined;
    var subject_esc_buf: [2048]u8 = undefined;
    var creator_esc_buf: [2048]u8 = undefined;
    var producer_esc_buf: [2048]u8 = undefined;
    var format_esc_buf: [256]u8 = undefined;

    var metadata = doc.getAllMetadata(allocator) catch {
        sendError(stream, "500 Internal Server Error", "Failed to read metadata");
        return;
    };
    defer metadata.deinit();

    const title = if (metadata.title) |t| jsonEscape(t, &title_esc_buf) else "";
    const author = if (metadata.author) |a| jsonEscape(a, &author_esc_buf) else "";
    const subject = if (metadata.subject) |s| jsonEscape(s, &subject_esc_buf) else "";
    const creator = if (metadata.creator) |c_val| jsonEscape(c_val, &creator_esc_buf) else "";
    const producer = if (metadata.producer) |p| jsonEscape(p, &producer_esc_buf) else "";
    const format = if (metadata.format) |f| jsonEscape(f, &format_esc_buf) else "";

    // Build page dimensions
    var pages_json_buf: [8192]u8 = undefined;
    var pages_len: usize = 0;
    pages_json_buf[0] = '[';
    pages_len = 1;

    const pages_to_show: i32 = @min(page_count, 50);
    var i: i32 = 0;
    while (i < pages_to_show) : (i += 1) {
        var page = doc.loadPage(i) catch continue;
        defer page.deinit();

        const w = page.width();
        const h = page.height();
        const rot = page.rotation();

        if (i > 0) {
            pages_json_buf[pages_len] = ',';
            pages_len += 1;
        }

        const entry = std.fmt.bufPrint(pages_json_buf[pages_len..], "{{\"page\":{d},\"width\":{d:.1},\"height\":{d:.1},\"rotation\":{d}}}", .{ i, w, h, rot }) catch break;
        pages_len += entry.len;
    }
    pages_json_buf[pages_len] = ']';
    pages_len += 1;

    // Build response
    var response_buf: [16384]u8 = undefined;
    const body = std.fmt.bufPrint(&response_buf, "{{\"page_count\":{d},\"is_pdf\":{},\"needs_password\":{},\"format\":\"{s}\",\"title\":\"{s}\",\"author\":\"{s}\",\"subject\":\"{s}\",\"creator\":\"{s}\",\"producer\":\"{s}\",\"pages\":{s}}}", .{
        page_count,
        is_pdf,
        needs_password,
        format,
        title,
        author,
        subject,
        creator,
        producer,
        pages_json_buf[0..pages_len],
    }) catch {
        sendError(stream, "500 Internal Server Error", "Response too large");
        return;
    };

    sendResponse(stream, .{ .body = body });
}

fn handleText(stream: std.net.Stream, form: FormData) void {
    const file_data = form.file_data orelse {
        sendError(stream, "400 Bad Request", "No file uploaded");
        return;
    };

    var ctx = mupdf.Context.init() catch {
        sendError(stream, "500 Internal Server Error", "Failed to init MuPDF context");
        return;
    };
    defer ctx.deinit();

    var doc = mupdf.Document.openFromMemory(&ctx, file_data, "application/pdf") catch {
        sendError(stream, "400 Bad Request", "Failed to open PDF");
        return;
    };
    defer doc.deinit();

    if (form.page < 0 or form.page >= doc.pageCount()) {
        sendError(stream, "400 Bad Request", "Page number out of range");
        return;
    }

    var page = doc.loadPage(form.page) catch {
        sendError(stream, "500 Internal Server Error", "Failed to load page");
        return;
    };
    defer page.deinit();

    const text = page.getText(allocator) catch {
        sendError(stream, "500 Internal Server Error", "Failed to extract text");
        return;
    };
    defer allocator.free(text);

    // Escape text for JSON
    const escaped_buf = allocator.alloc(u8, text.len * 2 + 1) catch {
        sendError(stream, "500 Internal Server Error", "Out of memory");
        return;
    };
    defer allocator.free(escaped_buf);
    const escaped = jsonEscape(text, escaped_buf);

    // Build response
    const prefix = std.fmt.allocPrint(allocator, "{{\"page\":{d},\"text\":\"", .{form.page}) catch {
        sendError(stream, "500 Internal Server Error", "Out of memory");
        return;
    };
    defer allocator.free(prefix);

    const suffix = "\"}";
    const total_len = prefix.len + escaped.len + suffix.len;
    const body = allocator.alloc(u8, total_len) catch {
        sendError(stream, "500 Internal Server Error", "Out of memory");
        return;
    };
    defer allocator.free(body);

    @memcpy(body[0..prefix.len], prefix);
    @memcpy(body[prefix.len .. prefix.len + escaped.len], escaped);
    @memcpy(body[prefix.len + escaped.len ..], suffix);

    sendResponse(stream, .{ .body = body });
}

fn handleSearch(stream: std.net.Stream, form: FormData) void {
    const file_data = form.file_data orelse {
        sendError(stream, "400 Bad Request", "No file uploaded");
        return;
    };
    const query = form.query orelse {
        sendError(stream, "400 Bad Request", "No query provided. Use: -F query=searchterm");
        return;
    };

    var ctx = mupdf.Context.init() catch {
        sendError(stream, "500 Internal Server Error", "Failed to init MuPDF context");
        return;
    };
    defer ctx.deinit();

    var doc = mupdf.Document.openFromMemory(&ctx, file_data, "application/pdf") catch {
        sendError(stream, "400 Bad Request", "Failed to open PDF");
        return;
    };
    defer doc.deinit();

    if (form.page < 0 or form.page >= doc.pageCount()) {
        sendError(stream, "400 Bad Request", "Page number out of range");
        return;
    }

    var page = doc.loadPage(form.page) catch {
        sendError(stream, "500 Internal Server Error", "Failed to load page");
        return;
    };
    defer page.deinit();

    const hits = page.search(query, allocator) catch {
        sendError(stream, "500 Internal Server Error", "Search failed");
        return;
    };
    defer allocator.free(hits);

    // Build JSON response
    var buf: [32768]u8 = undefined;
    var len: usize = 0;

    var query_esc_buf: [1024]u8 = undefined;
    const query_escaped = jsonEscape(query, &query_esc_buf);

    const header = std.fmt.bufPrint(buf[len..], "{{\"page\":{d},\"query\":\"{s}\",\"hit_count\":{d},\"hits\":[", .{ form.page, query_escaped, hits.len }) catch {
        sendError(stream, "500 Internal Server Error", "Response too large");
        return;
    };
    len += header.len;

    for (hits, 0..) |hit, i| {
        if (i > 0) {
            buf[len] = ',';
            len += 1;
        }
        const rect = hit.quad.toRect();
        const entry = std.fmt.bufPrint(buf[len..], "{{\"x\":{d:.1},\"y\":{d:.1},\"width\":{d:.1},\"height\":{d:.1}}}", .{ rect.x0, rect.y0, rect.width(), rect.height() }) catch break;
        len += entry.len;
    }

    const footer = "]}";
    @memcpy(buf[len .. len + footer.len], footer);
    len += footer.len;

    sendResponse(stream, .{ .body = buf[0..len] });
}

fn handleRender(stream: std.net.Stream, form: FormData) void {
    const file_data = form.file_data orelse {
        sendError(stream, "400 Bad Request", "No file uploaded");
        return;
    };

    var ctx = mupdf.Context.init() catch {
        sendError(stream, "500 Internal Server Error", "Failed to init MuPDF context");
        return;
    };
    defer ctx.deinit();

    var doc = mupdf.Document.openFromMemory(&ctx, file_data, "application/pdf") catch {
        sendError(stream, "400 Bad Request", "Failed to open PDF");
        return;
    };
    defer doc.deinit();

    if (form.page < 0 or form.page >= doc.pageCount()) {
        sendError(stream, "400 Bad Request", "Page number out of range");
        return;
    }

    var page = doc.loadPage(form.page) catch {
        sendError(stream, "500 Internal Server Error", "Failed to load page");
        return;
    };
    defer page.deinit();

    const scale = if (form.scale > 0 and form.scale <= 10) form.scale else 1.0;

    var pixmap = page.toPixmap(scale, 0.0) catch {
        sendError(stream, "500 Internal Server Error", "Failed to render page");
        return;
    };
    defer pixmap.deinit();

    // Save to a temp file and read it back (MuPDF's PNG writer works with files)
    const tmp_path = "/tmp/zig-mupdf-render.png";
    pixmap.savePng(tmp_path) catch {
        sendError(stream, "500 Internal Server Error", "Failed to encode PNG");
        return;
    };

    // Read the PNG file
    const png_data = std.fs.cwd().readFileAlloc(allocator, tmp_path, 50 * 1024 * 1024) catch {
        sendError(stream, "500 Internal Server Error", "Failed to read rendered PNG");
        return;
    };
    defer allocator.free(png_data);

    // Clean up temp file
    std.fs.cwd().deleteFile(tmp_path) catch {};

    sendResponse(stream, .{
        .content_type = "image/png",
        .body = png_data,
    });
}

// ============================================
// Main Server
// ============================================

fn handleConnection(stream: std.net.Stream) void {
    defer stream.close();

    // Read request (up to 50MB for PDF uploads)
    const max_size = 50 * 1024 * 1024;
    var buf = allocator.alloc(u8, max_size) catch {
        sendError(stream, "500 Internal Server Error", "Out of memory");
        return;
    };
    defer allocator.free(buf);

    var total: usize = 0;

    // Read until we have the full request
    // First, read headers to find Content-Length
    while (total < max_size) {
        const n = stream.read(buf[total..]) catch return;
        if (n == 0) break;
        total += n;

        // Check if we have complete headers
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |header_end| {
            // Look for Content-Length
            const headers = buf[0..header_end];
            var content_length: usize = 0;
            var lines = std.mem.splitSequence(u8, headers, "\r\n");
            while (lines.next()) |line| {
                if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                    const val = std.mem.trim(u8, line["content-length:".len..], " ");
                    content_length = std.fmt.parseInt(usize, val, 10) catch 0;
                    break;
                }
            }

            const expected_total = header_end + 4 + content_length;
            if (total >= expected_total) break;

            // Keep reading if we haven't received all the body
            if (total >= max_size) break;
        }
    }

    if (total == 0) return;

    const request = parseRequest(buf[0..total]) orelse {
        sendError(stream, "400 Bad Request", "Malformed request");
        return;
    };

    // Log request
    std.debug.print("{s} {s}\n", .{ request.method, request.path });

    // Route
    if (std.mem.eql(u8, request.path, "/health")) {
        handleHealth(stream);
    } else if (std.mem.eql(u8, request.method, "POST")) {
        const form = if (std.mem.indexOf(u8, request.content_type, "multipart/form-data") != null)
            parseMultipart(request.content_type, request.body)
        else
            FormData{ .file_data = if (request.body.len > 0) request.body else null };

        if (std.mem.eql(u8, request.path, "/info")) {
            handleInfo(stream, form);
        } else if (std.mem.eql(u8, request.path, "/text")) {
            handleText(stream, form);
        } else if (std.mem.eql(u8, request.path, "/search")) {
            handleSearch(stream, form);
        } else if (std.mem.eql(u8, request.path, "/render")) {
            handleRender(stream, form);
        } else {
            sendError(stream, "404 Not Found", "Unknown endpoint");
        }
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/")) {
        sendResponse(stream, .{
            .content_type = "text/plain",
            .body =
            \\zig-mupdf PDF Server
            \\
            \\Endpoints:
            \\  GET  /health              Health check
            \\  POST /info                PDF metadata (form: file=@doc.pdf)
            \\  POST /text                Extract text (form: file, page=0)
            \\  POST /search              Search text  (form: file, page=0, query=term)
            \\  POST /render              Render PNG   (form: file, page=0, scale=2.0)
            \\
            \\Example:
            \\  curl -X POST -F "file=@document.pdf" http://localhost:8080/info
            \\  curl -X POST -F "file=@document.pdf" -F "page=0" http://localhost:8080/text
            \\  curl -X POST -F "file=@document.pdf" -F "page=0" -F "query=hello" http://localhost:8080/search
            \\  curl -X POST -F "file=@document.pdf" -F "page=0" -F "scale=2" -o page.png http://localhost:8080/render
            ,
        });
    } else {
        sendError(stream, "404 Not Found", "Unknown endpoint. GET / for help.");
    }
}

pub fn main() !void {
    const port: u16 = blk: {
        var args = std.process.args();
        _ = args.skip(); // program name
        if (args.next()) |p| {
            break :blk std.fmt.parseInt(u16, p, 10) catch 8080;
        }
        break :blk 8080;
    };

    const address = std.net.Address.parseIp4("0.0.0.0", port) catch unreachable;
    var server = address.listen(.{
        .reuse_address = true,
    }) catch |err| {
        std.debug.print("Failed to bind to port {d}: {}\n", .{ port, err });
        return;
    };
    defer server.deinit();

    std.debug.print("\n", .{});
    std.debug.print("  zig-mupdf server running on http://localhost:{d}\n", .{port});
    std.debug.print("  Press Ctrl+C to stop\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("  Try: curl http://localhost:{d}/health\n", .{port});
    std.debug.print("       curl -X POST -F \"file=@doc.pdf\" http://localhost:{d}/info\n", .{port});
    std.debug.print("\n", .{});

    while (true) {
        const connection = server.accept() catch continue;
        handleConnection(connection.stream);
    }
}

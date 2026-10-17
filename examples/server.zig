//! zig-mupdf HTTP Server (optimized)
//!
//! Usage:
//!   zig build run-server -Doptimize=ReleaseFast -- [port] [--workers N]
//!   curl http://localhost:8080/health
//!   curl -X POST -F "file=@doc.pdf" http://localhost:8080/info
//!
//! Concurrency model: the main thread accepts connections and pushes them to a
//! bounded queue; a fixed pool of worker threads (default: one per CPU) pops
//! and serves them. Each worker owns a `fz_context` cloned from one
//! lock-enabled base context, so no MuPDF context is ever shared by threads.

const std = @import("std");
const mupdf = @import("mupdf");

// malloc-backed: thread-safe and fast for many concurrent workers
const allocator = std.heap.c_allocator;

const c_lib = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("netinet/tcp.h");
    @cInclude("netinet/in.h");
});

const Config = struct {
    port: u16 = 8080,
    /// Worker threads; 0 = one per CPU.
    workers: usize = 0,
    /// Accepted connections waiting for a free worker before new ones get 503.
    queue_capacity: usize = 1024,
};

// ============================================
// HTTP Parsing (minimal, fast)
// ============================================

const Request = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8,
    content_type: []const u8,
};

const FormData = struct {
    file_data: ?[]const u8 = null,
    page: i32 = 0,
    query: ?[]const u8 = null,
    scale: f32 = 1.0,
};

fn parseRequest(buf: []const u8) ?Request {
    const header_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return null;
    const header = buf[0..header_end];
    const body = buf[header_end + 4 ..];

    const line_end = std.mem.indexOf(u8, header, "\r\n") orelse return null;
    const request_line = header[0..line_end];

    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return null;
    const path = parts.next() orelse return null;

    var content_type: []const u8 = "";
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-type:")) {
            content_type = std.mem.trim(u8, line["content-type:".len..], " ");
            break;
        }
    }

    return .{ .method = method, .path = path, .body = body, .content_type = content_type };
}

fn getContentLength(buf: []const u8) usize {
    const header_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return 0;
    const header = buf[0..header_end];
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const val = std.mem.trim(u8, line["content-length:".len..], " ");
            return std.fmt.parseInt(usize, val, 10) catch 0;
        }
    }
    return 0;
}

fn parseMultipart(content_type: []const u8, body: []const u8) FormData {
    var result = FormData{};

    const boundary_prefix = "boundary=";
    const boundary_start = std.mem.indexOf(u8, content_type, boundary_prefix) orelse return result;
    var bv = content_type[boundary_start + boundary_prefix.len ..];
    if (bv.len > 0 and bv[0] == '"') {
        bv = bv[1..];
        if (std.mem.indexOf(u8, bv, "\"")) |end| bv = bv[0..end];
    }

    var delim_buf: [256]u8 = undefined;
    const delim = std.fmt.bufPrint(&delim_buf, "--{s}", .{bv}) catch return result;

    var parts_iter = std.mem.splitSequence(u8, body, delim);
    while (parts_iter.next()) |part| {
        if (part.len < 4) continue;
        const trimmed = if (std.mem.startsWith(u8, part, "\r\n")) part[2..] else part;
        const sep = std.mem.indexOf(u8, trimmed, "\r\n\r\n") orelse continue;
        const ph = trimmed[0..sep];
        const pb = trimmed[sep + 4 ..];
        const cb = if (pb.len >= 2 and std.mem.endsWith(u8, pb, "\r\n")) pb[0 .. pb.len - 2] else pb;

        if (std.mem.indexOf(u8, ph, "name=\"file\"") != null) {
            result.file_data = cb;
        } else if (std.mem.indexOf(u8, ph, "name=\"page\"") != null) {
            result.page = std.fmt.parseInt(i32, std.mem.trim(u8, cb, " \r\n"), 10) catch 0;
        } else if (std.mem.indexOf(u8, ph, "name=\"query\"") != null) {
            result.query = cb;
        } else if (std.mem.indexOf(u8, ph, "name=\"scale\"") != null) {
            result.scale = std.fmt.parseFloat(f32, std.mem.trim(u8, cb, " \r\n")) catch 1.0;
        }
    }
    return result;
}

// ============================================
// Response helpers
// ============================================

fn sendFull(stream: std.net.Stream, status: []const u8, ctype: []const u8, body: []const u8) void {
    // Build header + body into one buffer for a single write syscall
    const header_max = 256;
    const total = header_max + body.len;
    const buf = allocator.alloc(u8, total) catch {
        // Fallback: two writes
        var hb: [256]u8 = undefined;
        const h = std.fmt.bufPrint(&hb, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n", .{ status, ctype, body.len }) catch return;
        _ = stream.write(h) catch return;
        if (body.len > 0) _ = stream.write(body) catch return;
        return;
    };
    defer allocator.free(buf);

    const hlen = std.fmt.bufPrint(buf[0..header_max], "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n", .{ status, ctype, body.len }) catch return;
    @memcpy(buf[hlen.len .. hlen.len + body.len], body);
    _ = stream.write(buf[0 .. hlen.len + body.len]) catch return;
}

fn sendJson(stream: std.net.Stream, body: []const u8) void {
    sendFull(stream, "200 OK", "application/json", body);
}

fn sendError(stream: std.net.Stream, status: []const u8, msg: []const u8) void {
    var buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}", .{msg}) catch return;
    sendFull(stream, status, "application/json", body);
}

// ============================================
// JSON helpers
// ============================================

fn jsonEscape(input: []const u8, buf: []u8) []const u8 {
    var i: usize = 0;
    for (input) |ch| {
        if (i + 6 >= buf.len) break;
        switch (ch) {
            '"' => { buf[i] = '\\'; buf[i + 1] = '"'; i += 2; },
            '\\' => { buf[i] = '\\'; buf[i + 1] = '\\'; i += 2; },
            '\n' => { buf[i] = '\\'; buf[i + 1] = 'n'; i += 2; },
            '\r' => { buf[i] = '\\'; buf[i + 1] = 'r'; i += 2; },
            '\t' => { buf[i] = '\\'; buf[i + 1] = 't'; i += 2; },
            else => if (ch >= 0x20) { buf[i] = ch; i += 1; },
        }
    }
    return buf[0..i];
}

// ============================================
// Route Handlers
// ============================================

fn handleHealth(stream: std.net.Stream) void {
    sendJson(stream, "{\"status\":\"ok\",\"service\":\"zig-mupdf\"}");
}

fn handleInfo(ctx: *mupdf.Context, stream: std.net.Stream, form: FormData) void {
    const file_data = form.file_data orelse {
        sendError(stream, "400 Bad Request", "No file uploaded");
        return;
    };

    var doc = mupdf.Document.openFromMemory(ctx, file_data, "application/pdf") catch {
        sendError(stream, "400 Bad Request", "Failed to open PDF");
        return;
    };
    defer doc.deinit();

    const page_count = doc.pageCount() catch {
        sendError(stream, "422 Unprocessable Entity", "Malformed page tree");
        return;
    };
    const needs_password = doc.needsPassword() catch true;

    var metadata = doc.getAllMetadata(allocator) catch {
        sendError(stream, "500 Internal Server Error", "Metadata read failed");
        return;
    };
    defer metadata.deinit();

    var esc_bufs: [6][2048]u8 = undefined;
    const title = if (metadata.title) |t| jsonEscape(t, &esc_bufs[0]) else "";
    const author_val = if (metadata.author) |a| jsonEscape(a, &esc_bufs[1]) else "";
    const subject = if (metadata.subject) |s| jsonEscape(s, &esc_bufs[2]) else "";
    const creator_val = if (metadata.creator) |cv| jsonEscape(cv, &esc_bufs[3]) else "";
    const producer = if (metadata.producer) |p| jsonEscape(p, &esc_bufs[4]) else "";
    const format = if (metadata.format) |f| jsonEscape(f, &esc_bufs[5]) else "";

    // Pages array
    var pages_buf: [16384]u8 = undefined;
    var pl: usize = 1;
    pages_buf[0] = '[';

    const show: i32 = @min(page_count, 50);
    var i: i32 = 0;
    while (i < show) : (i += 1) {
        var page = doc.loadPage(i) catch continue;
        defer page.deinit();
        const b = page.bounds() catch continue;
        if (pl > 1) { pages_buf[pl] = ','; pl += 1; }
        const e = std.fmt.bufPrint(pages_buf[pl..], "{{\"page\":{d},\"width\":{d:.1},\"height\":{d:.1},\"rotation\":{d}}}", .{ i, b.width(), b.height(), page.rotation() }) catch break;
        pl += e.len;
    }
    pages_buf[pl] = ']';
    pl += 1;

    var resp_buf: [32768]u8 = undefined;
    const body = std.fmt.bufPrint(&resp_buf, "{{\"page_count\":{d},\"is_pdf\":{},\"needs_password\":{},\"format\":\"{s}\",\"title\":\"{s}\",\"author\":\"{s}\",\"subject\":\"{s}\",\"creator\":\"{s}\",\"producer\":\"{s}\",\"pages\":{s}}}", .{
        page_count, doc.isPdf(), needs_password, format, title, author_val, subject, creator_val, producer, pages_buf[0..pl],
    }) catch { sendError(stream, "500 Internal Server Error", "Response too large"); return; };

    sendJson(stream, body);
}

fn handleText(ctx: *mupdf.Context, stream: std.net.Stream, form: FormData) void {
    const file_data = form.file_data orelse { sendError(stream, "400 Bad Request", "No file"); return; };

    var doc = mupdf.Document.openFromMemory(ctx, file_data, "application/pdf") catch {
        sendError(stream, "400 Bad Request", "Failed to open PDF"); return;
    };
    defer doc.deinit();

    const page_count = doc.pageCount() catch { sendError(stream, "422 Unprocessable Entity", "Malformed page tree"); return; };
    if (form.page < 0 or form.page >= page_count) {
        sendError(stream, "400 Bad Request", "Page out of range"); return;
    }

    var page = doc.loadPage(form.page) catch { sendError(stream, "500 Internal Server Error", "Load page failed"); return; };
    defer page.deinit();

    const text = page.getText(allocator) catch { sendError(stream, "500 Internal Server Error", "Text extraction failed"); return; };
    defer allocator.free(text);

    const esc_buf = allocator.alloc(u8, text.len * 2 + 1) catch { sendError(stream, "500 Internal Server Error", "OOM"); return; };
    defer allocator.free(esc_buf);
    const escaped = jsonEscape(text, esc_buf);

    const prefix = std.fmt.allocPrint(allocator, "{{\"page\":{d},\"text\":\"", .{form.page}) catch { sendError(stream, "500 Internal Server Error", "OOM"); return; };
    defer allocator.free(prefix);
    const suffix = "\"}";

    const body = allocator.alloc(u8, prefix.len + escaped.len + suffix.len) catch { sendError(stream, "500 Internal Server Error", "OOM"); return; };
    defer allocator.free(body);
    @memcpy(body[0..prefix.len], prefix);
    @memcpy(body[prefix.len .. prefix.len + escaped.len], escaped);
    @memcpy(body[prefix.len + escaped.len ..], suffix);

    sendJson(stream, body);
}

fn handleSearch(ctx: *mupdf.Context, stream: std.net.Stream, form: FormData) void {
    const file_data = form.file_data orelse { sendError(stream, "400 Bad Request", "No file"); return; };
    const query = form.query orelse { sendError(stream, "400 Bad Request", "No query"); return; };

    var doc = mupdf.Document.openFromMemory(ctx, file_data, "application/pdf") catch { sendError(stream, "400 Bad Request", "Failed to open PDF"); return; };
    defer doc.deinit();

    const page_count = doc.pageCount() catch { sendError(stream, "422 Unprocessable Entity", "Malformed page tree"); return; };
    if (form.page < 0 or form.page >= page_count) { sendError(stream, "400 Bad Request", "Page out of range"); return; }

    var page = doc.loadPage(form.page) catch { sendError(stream, "500 Internal Server Error", "Load failed"); return; };
    defer page.deinit();

    const hits = page.search(query, allocator) catch { sendError(stream, "500 Internal Server Error", "Search failed"); return; };
    defer allocator.free(hits);

    var buf: [32768]u8 = undefined;
    var len: usize = 0;
    var qesc: [1024]u8 = undefined;
    const qe = jsonEscape(query, &qesc);
    const hdr = std.fmt.bufPrint(buf[0..], "{{\"page\":{d},\"query\":\"{s}\",\"hit_count\":{d},\"hits\":[", .{ form.page, qe, hits.len }) catch { sendError(stream, "500 Internal Server Error", "Response too large"); return; };
    len = hdr.len;

    for (hits, 0..) |hit, idx| {
        if (idx > 0) { buf[len] = ','; len += 1; }
        const r = hit.quad.toRect();
        const e = std.fmt.bufPrint(buf[len..], "{{\"x\":{d:.1},\"y\":{d:.1},\"width\":{d:.1},\"height\":{d:.1}}}", .{ r.x0, r.y0, r.width(), r.height() }) catch break;
        len += e.len;
    }
    @memcpy(buf[len .. len + 2], "]}");
    len += 2;

    sendJson(stream, buf[0..len]);
}

fn handleRender(ctx: *mupdf.Context, stream: std.net.Stream, form: FormData) void {
    const file_data = form.file_data orelse { sendError(stream, "400 Bad Request", "No file"); return; };

    var timer = std.time.Timer.start() catch unreachable;

    var doc = mupdf.Document.openFromMemory(ctx, file_data, "application/pdf") catch { sendError(stream, "400 Bad Request", "Failed to open PDF"); return; };
    defer doc.deinit();
    const t_open = timer.lap();

    const page_count = doc.pageCount() catch { sendError(stream, "422 Unprocessable Entity", "Malformed page tree"); return; };
    if (form.page < 0 or form.page >= page_count) { sendError(stream, "400 Bad Request", "Page out of range"); return; }

    var page = doc.loadPage(form.page) catch { sendError(stream, "500 Internal Server Error", "Load failed"); return; };
    defer page.deinit();
    const t_load = timer.lap();

    const scale = if (form.scale > 0 and form.scale <= 10) form.scale else 1.0;

    var pixmap = page.toPixmap(scale, 0.0) catch { sendError(stream, "500 Internal Server Error", "Render failed"); return; };
    defer pixmap.deinit();
    const t_render = timer.lap();

    const png_data = pixmap.toPng(allocator) catch { sendError(stream, "500 Internal Server Error", "PNG encode failed"); return; };
    defer allocator.free(png_data);
    const t_png = timer.lap();

    sendFull(stream, "200 OK", "image/png", png_data);
    const t_send = timer.lap();

    std.debug.print("  render: open={d:.1}ms load={d:.1}ms render={d:.1}ms png={d:.1}ms send={d:.1}ms total={d:.1}ms\n", .{
        @as(f64, @floatFromInt(t_open)) / 1_000_000.0,
        @as(f64, @floatFromInt(t_load)) / 1_000_000.0,
        @as(f64, @floatFromInt(t_render)) / 1_000_000.0,
        @as(f64, @floatFromInt(t_png)) / 1_000_000.0,
        @as(f64, @floatFromInt(t_send)) / 1_000_000.0,
        @as(f64, @floatFromInt(t_open + t_load + t_render + t_png + t_send)) / 1_000_000.0,
    });
}

// ============================================
// Connection handler
// ============================================

fn handleConnection(ctx: *mupdf.Context, stream: std.net.Stream) void {
    defer stream.close();

    // Set socket options for fast transfer
    const fd: c_int = @intCast(stream.handle);
    var nodelay: c_int = 1;
    _ = c_lib.setsockopt(fd, c_lib.IPPROTO_TCP, c_lib.TCP_NODELAY, &nodelay, @sizeOf(c_int));

    // Read the full request
    // Strategy: allocate generous buffer, read continuously until we have
    // headers + full Content-Length body. Use readAtLeast to minimize syscalls.
    const max_request = 50 * 1024 * 1024;

    // First read: get headers
    var hdr_buf: [4096]u8 = undefined;
    var hdr_len: usize = 0;
    while (hdr_len < hdr_buf.len) {
        const n = stream.read(hdr_buf[hdr_len..]) catch return;
        if (n == 0) return;
        hdr_len += n;
        if (std.mem.indexOf(u8, hdr_buf[0..hdr_len], "\r\n\r\n") != null) break;
    }
    if (hdr_len == 0) return;

    // Handle Expect: 100-continue — client waits for this before sending body
    const headers_slice = hdr_buf[0..hdr_len];
    if (std.ascii.indexOfIgnoreCase(headers_slice, "expect: 100-continue") != null or
        std.ascii.indexOfIgnoreCase(headers_slice, "expect:100-continue") != null)
    {
        _ = stream.write("HTTP/1.1 100 Continue\r\n\r\n") catch {};
    }

    const content_length = getContentLength(hdr_buf[0..hdr_len]);
    const header_end_pos = std.mem.indexOf(u8, hdr_buf[0..hdr_len], "\r\n\r\n") orelse return;
    const header_end = header_end_pos + 4;

    // For requests with no/small body, use stack buffer
    var full_buf: []u8 = undefined;
    var owns_buf = false;
    var total = hdr_len;

    if (content_length == 0) {
        full_buf = hdr_buf[0..hdr_len];
    } else {
        const expected_total = header_end + content_length;
        if (expected_total > max_request) {
            sendError(stream, "413 Payload Too Large", "Request too large");
            return;
        }

        full_buf = allocator.alloc(u8, expected_total) catch {
            sendError(stream, "500 Internal Server Error", "OOM");
            return;
        };
        owns_buf = true;
        @memcpy(full_buf[0..hdr_len], hdr_buf[0..hdr_len]);

        // Read remaining body using recv(MSG_WAITALL) to avoid delayed ACK penalty
        const remaining = expected_total - total;
        if (remaining > 0) {
            const rc = c_lib.recv(fd, full_buf.ptr + total, remaining, c_lib.MSG_WAITALL);
            if (rc > 0) total += @intCast(@as(usize, @bitCast(rc)));
        }
    }
    defer if (owns_buf) allocator.free(full_buf);

    const request = parseRequest(full_buf[0..total]) orelse {
        sendError(stream, "400 Bad Request", "Malformed request");
        return;
    };

    // Route
    if (std.mem.eql(u8, request.path, "/health")) {
        handleHealth(stream);
    } else if (std.mem.eql(u8, request.method, "POST")) {
        const form = if (std.mem.indexOf(u8, request.content_type, "multipart/form-data") != null)
            parseMultipart(request.content_type, request.body)
        else
            FormData{ .file_data = if (request.body.len > 0) request.body else null };

        if (std.mem.eql(u8, request.path, "/info")) handleInfo(ctx, stream, form)
        else if (std.mem.eql(u8, request.path, "/text")) handleText(ctx, stream, form)
        else if (std.mem.eql(u8, request.path, "/search")) handleSearch(ctx, stream, form)
        else if (std.mem.eql(u8, request.path, "/render")) handleRender(ctx, stream, form)
        else sendError(stream, "404 Not Found", "Unknown endpoint");
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/")) {
        sendFull(stream, "200 OK", "text/plain",
            \\zig-mupdf PDF Server
            \\
            \\Endpoints:
            \\  GET  /health              Health check
            \\  POST /info                PDF metadata (form: file=@doc.pdf)
            \\  POST /text                Extract text (form: file, page=0)
            \\  POST /search              Search text  (form: file, page=0, query=term)
            \\  POST /render              Render PNG   (form: file, page=0, scale=2.0)
        );
    } else {
        sendError(stream, "404 Not Found", "Unknown endpoint");
    }
}

// ============================================
// Worker pool
// ============================================

/// Bounded FIFO of accepted connections shared by the acceptor and workers.
const ConnQueue = struct {
    mutex: std.Thread.Mutex = .{},
    not_empty: std.Thread.Condition = .{},
    items: []std.net.Stream,
    head: usize = 0,
    len: usize = 0,

    /// Returns false if the queue is full.
    fn push(self: *ConnQueue, stream: std.net.Stream) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len == self.items.len) return false;
        self.items[(self.head + self.len) % self.items.len] = stream;
        self.len += 1;
        self.not_empty.signal();
        return true;
    }

    fn pop(self: *ConnQueue) std.net.Stream {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.len == 0) self.not_empty.wait(&self.mutex);
        const stream = self.items[self.head];
        self.head = (self.head + 1) % self.items.len;
        self.len -= 1;
        return stream;
    }
};

fn workerMain(ctx: *mupdf.Context, queue: *ConnQueue) void {
    while (true) handleConnection(ctx, queue.pop());
}

fn parseArgs() !Config {
    var cfg = Config{};
    var args = std.process.args();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--workers") or std.mem.eql(u8, arg, "-w")) {
            cfg.workers = try std.fmt.parseInt(usize, args.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--queue")) {
            cfg.queue_capacity = try std.fmt.parseInt(usize, args.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\usage: mupdf-server [port] [--workers N] [--queue N]
                \\  port         TCP port (default 8080)
                \\  --workers N  worker threads (default: CPU count)
                \\  --queue N    max accepted connections waiting for a worker (default 1024)
                \\
            , .{});
            std.process.exit(0);
        } else {
            cfg.port = try std.fmt.parseInt(u16, arg, 10);
        }
    }
    if (cfg.workers == 0) cfg.workers = std.Thread.getCpuCount() catch 1;
    if (cfg.queue_capacity == 0) cfg.queue_capacity = 1;
    return cfg;
}

// ============================================
// Main
// ============================================

pub fn main() !void {
    const cfg = parseArgs() catch |err| {
        std.debug.print("Invalid arguments ({}); see --help\n", .{err});
        std.process.exit(2);
    };

    // One lock-enabled base context; every worker gets its own clone.
    var base_ctx = try mupdf.Context.initThreadSafe();
    defer base_ctx.deinit();

    const worker_ctxs = try allocator.alloc(mupdf.Context, cfg.workers);
    defer allocator.free(worker_ctxs);
    for (worker_ctxs) |*wctx| wctx.* = try base_ctx.clone();
    defer for (worker_ctxs) |*wctx| wctx.deinit();

    var queue = ConnQueue{ .items = try allocator.alloc(std.net.Stream, cfg.queue_capacity) };
    defer allocator.free(queue.items);

    const address = std.net.Address.parseIp4("0.0.0.0", cfg.port) catch unreachable;
    var server = address.listen(.{ .reuse_address = true, .kernel_backlog = 1024 }) catch |err| {
        std.debug.print("Failed to bind port {d}: {}\n", .{ cfg.port, err });
        return;
    };
    defer server.deinit();

    for (worker_ctxs) |*wctx| {
        const t = try std.Thread.spawn(.{}, workerMain, .{ wctx, &queue });
        t.detach();
    }

    std.debug.print("\n  zig-mupdf server on http://localhost:{d} ({d} workers)\n\n", .{ cfg.port, cfg.workers });

    while (true) {
        const conn = server.accept() catch continue;
        if (!queue.push(conn.stream)) {
            sendError(conn.stream, "503 Service Unavailable", "Server busy");
            conn.stream.close();
        }
    }
}

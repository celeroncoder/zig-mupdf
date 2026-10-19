//! zig-mupdf HTTP Server (optimized)
//!
//! Usage:
//!   zig build run-server -Doptimize=ReleaseFast -- [port] [--workers N]
//!   curl http://localhost:8080/health
//!   curl -X POST -F "file=@doc.pdf" http://localhost:8080/info
//!
//! License: this binary statically links MuPDF (AGPL-3.0). Offering it as a
//! network service obliges you to provide its complete source to its users
//! (AGPL section 13) unless you hold an Artifex commercial license.
//!
//! Concurrency model: the main thread runs a non-blocking poll() loop that
//! accepts connections and reads each request in full (with deadlines and size
//! limits). Only complete requests are pushed to a bounded queue, which a
//! fixed pool of worker threads (default: one per CPU) drains. Idle or slow
//! clients therefore never occupy a worker. Each worker owns its own
//! `fz_context`, so no MuPDF context is ever shared by threads. By default the
//! worker contexts are fully independent (separate resource stores); with
//! `--shared-store` they are clones of one lock-enabled base context and share
//! the store and caches. Independent is the default because MuPDF 1.28's shared
//! store compares un-hashed keys across documents, which can read another
//! thread's document while it is being dropped or repaired (see VERIFICATION.md).

const std = @import("std");
const mupdf = @import("mupdf");

// malloc-backed: thread-safe and fast for many concurrent workers
const allocator = std.heap.c_allocator;

const c_lib = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("netinet/tcp.h");
    @cInclude("netinet/in.h");
});

const posix = std.posix;

const Config = struct {
    port: u16 = 8080,
    /// Worker threads; 0 = one per CPU.
    workers: usize = 0,
    /// Complete requests waiting for a free worker before new ones get 503.
    queue_capacity: usize = 1024,
    /// Connections being read concurrently before new ones get 503.
    max_connections: usize = 1024,
    /// The request head must arrive within this long after accept, and the
    /// body must make progress at least this often. Also SO_RCVTIMEO.
    read_timeout_ms: u32 = 10_000,
    /// SO_SNDTIMEO for writing responses.
    write_timeout_ms: u32 = 10_000,
    /// Max size of request line + headers (431 beyond this).
    max_header_bytes: usize = 16 * 1024,
    /// Max Content-Length (413 beyond this).
    max_body_bytes: usize = 50 * 1024 * 1024,
    /// Clone worker contexts from one lock-enabled base (shared store) instead
    /// of giving each worker an independent context.
    shared_store: bool = false,
    /// Total MuPDF resource store budget, split evenly across independent workers.
    store_mb: usize = 256,
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
        stream.writeAll(h) catch return;
        if (body.len > 0) stream.writeAll(body) catch return;
        return;
    };
    defer allocator.free(buf);

    const hlen = std.fmt.bufPrint(buf[0..header_max], "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n", .{ status, ctype, body.len }) catch return;
    @memcpy(buf[hlen.len .. hlen.len + body.len], body);
    // writeAll: a single write() may be partial (large PNGs, SO_SNDTIMEO)
    stream.writeAll(buf[0 .. hlen.len + body.len]) catch return;
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
// Request routing (worker threads)
// ============================================

/// Serve one fully-buffered request and close the connection.
fn serveRequest(ctx: *mupdf.Context, stream: std.net.Stream, raw: []const u8) void {
    defer stream.close();

    const request = parseRequest(raw) orelse {
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

/// A complete request handed from the reader loop to a worker.
const Job = struct {
    stream: std.net.Stream,
    /// Owned request bytes (head + body), freed by the worker.
    data: std.ArrayListUnmanaged(u8),
};

/// Bounded FIFO of complete requests shared by the reader loop and workers.
const JobQueue = struct {
    mutex: std.Thread.Mutex = .{},
    not_empty: std.Thread.Condition = .{},
    items: []Job,
    head: usize = 0,
    len: usize = 0,

    /// Returns false if the queue is full.
    fn push(self: *JobQueue, job: Job) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len == self.items.len) return false;
        self.items[(self.head + self.len) % self.items.len] = job;
        self.len += 1;
        self.not_empty.signal();
        return true;
    }

    fn pop(self: *JobQueue) Job {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.len == 0) self.not_empty.wait(&self.mutex);
        const job = self.items[self.head];
        self.head = (self.head + 1) % self.items.len;
        self.len -= 1;
        return job;
    }
};

fn workerMain(ctx: *mupdf.Context, queue: *JobQueue) void {
    while (true) {
        var job = queue.pop();
        defer job.data.deinit(allocator);
        serveRequest(ctx, job.stream, job.data.items);
    }
}

// ============================================
// Request reader (main thread)
// ============================================
//
// Workers never block on a client socket. The main thread reads every
// request with non-blocking sockets and poll(), enforcing:
//   - the request head must arrive within read_timeout_ms of accept
//     (defeats slowloris trickling headers),
//   - the body must make progress at least every read_timeout_ms (408 otherwise),
//   - head <= max_header_bytes (431), Content-Length <= max_body_bytes (413),
//   - a valid Content-Length (400) and no chunked encoding (411),
//   - EOF before Content-Length bytes arrived means 400, never a parse of a
//     truncated body.

const Head = struct {
    content_length: usize = 0,
    expect_continue: bool = false,
};

const HeadError = error{ InvalidContentLength, ChunkedUnsupported };

fn parseHead(head: []const u8) HeadError!Head {
    var result = Head{};
    var seen_length = false;
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next(); // request line
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            const len = std.fmt.parseInt(usize, value, 10) catch return error.InvalidContentLength;
            if (seen_length and len != result.content_length) return error.InvalidContentLength;
            result.content_length = len;
            seen_length = true;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            return error.ChunkedUnsupported;
        } else if (std.ascii.eqlIgnoreCase(name, "expect")) {
            result.expect_continue = std.ascii.eqlIgnoreCase(value, "100-continue");
        }
    }
    return result;
}

const Conn = struct {
    stream: std.net.Stream,
    buf: std.ArrayListUnmanaged(u8) = .{},
    /// Offset just past "\r\n\r\n", once the head has arrived.
    body_start: ?usize = null,
    content_length: usize = 0,
    accepted: std.time.Instant,
    last_progress: std.time.Instant,
};

fn setSocketTimeouts(fd: posix.socket_t, cfg: Config) void {
    const rcv = posix.timeval{ .sec = @intCast(cfg.read_timeout_ms / 1000), .usec = @intCast((cfg.read_timeout_ms % 1000) * 1000) };
    const snd = posix.timeval{ .sec = @intCast(cfg.write_timeout_ms / 1000), .usec = @intCast((cfg.write_timeout_ms % 1000) * 1000) };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&rcv)) catch {};
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&snd)) catch {};
}

fn setBlocking(fd: posix.socket_t) !void {
    var flags: posix.O = @bitCast(@as(u32, @intCast(try posix.fcntl(fd, posix.F.GETFL, 0))));
    flags.NONBLOCK = false;
    _ = try posix.fcntl(fd, posix.F.SETFL, @as(u32, @bitCast(flags)));
}

const Reader = struct {
    cfg: Config,
    listener: std.net.Server,
    queue: *JobQueue,
    conns: std.ArrayListUnmanaged(Conn) = .{},
    pollfds: std.ArrayListUnmanaged(posix.pollfd) = .{},

    fn run(self: *Reader) noreturn {
        while (true) {
            self.pollfds.clearRetainingCapacity();
            self.pollfds.append(allocator, .{ .fd = self.listener.stream.handle, .events = posix.POLL.IN, .revents = 0 }) catch @panic("OOM");
            for (self.conns.items) |conn| {
                self.pollfds.append(allocator, .{ .fd = conn.stream.handle, .events = posix.POLL.IN, .revents = 0 }) catch @panic("OOM");
            }

            _ = posix.poll(self.pollfds.items, self.pollTimeoutMs()) catch continue;
            const now = std.time.Instant.now() catch unreachable;

            // Walk backwards: removing conns[i] (swapRemove) only moves an
            // already-visited element into slot i.
            var i = self.conns.items.len;
            while (i > 0) {
                i -= 1;
                if (self.pollfds.items[i + 1].revents != 0) {
                    if (!self.onReadable(i, now)) continue;
                }
                self.checkDeadline(i, now);
            }

            if (self.pollfds.items[0].revents & posix.POLL.IN != 0) self.acceptAll(now);
        }
    }

    fn limitNs(self: *const Reader) u64 {
        return @as(u64, self.cfg.read_timeout_ms) * std.time.ns_per_ms;
    }

    /// Deadline reference: accept time while reading the head, last progress
    /// while reading the body.
    fn deadlineBase(conn: *const Conn) std.time.Instant {
        return if (conn.body_start == null) conn.accepted else conn.last_progress;
    }

    fn pollTimeoutMs(self: *const Reader) i32 {
        if (self.conns.items.len == 0) return -1;
        const now = std.time.Instant.now() catch unreachable;
        var min_left: u64 = self.limitNs();
        for (self.conns.items) |*conn| {
            const elapsed = now.since(deadlineBase(conn));
            min_left = @min(min_left, self.limitNs() -| elapsed);
        }
        return @intCast(@min(min_left / std.time.ns_per_ms + 1, std.math.maxInt(i32)));
    }

    fn acceptAll(self: *Reader, now: std.time.Instant) void {
        while (true) {
            const fd = posix.accept(self.listener.stream.handle, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC) catch return;
            const stream = std.net.Stream{ .handle = fd };
            if (self.conns.items.len >= self.cfg.max_connections) {
                sendError(stream, "503 Service Unavailable", "Too many connections");
                stream.close();
                continue;
            }
            var nodelay: c_int = 1;
            _ = c_lib.setsockopt(fd, c_lib.IPPROTO_TCP, c_lib.TCP_NODELAY, &nodelay, @sizeOf(c_int));
            self.conns.append(allocator, .{ .stream = stream, .accepted = now, .last_progress = now }) catch {
                stream.close();
                return;
            };
        }
    }

    /// Drop a connection, optionally answering with an error first.
    fn reject(self: *Reader, i: usize, status: ?[]const u8, msg: []const u8) void {
        var conn = self.conns.swapRemove(i);
        if (status) |st| sendError(conn.stream, st, msg);
        conn.stream.close();
        conn.buf.deinit(allocator);
    }

    fn checkDeadline(self: *Reader, i: usize, now: std.time.Instant) void {
        const conn = &self.conns.items[i];
        if (now.since(deadlineBase(conn)) < self.limitNs()) return;
        // A client that sent nothing just gets disconnected.
        self.reject(i, if (conn.buf.items.len > 0) "408 Request Timeout" else null, "Request not received in time");
    }

    /// Returns false if the connection was removed (rejected or dispatched).
    fn onReadable(self: *Reader, i: usize, now: std.time.Instant) bool {
        const conn = &self.conns.items[i];
        while (true) {
            conn.buf.ensureUnusedCapacity(allocator, 64 * 1024) catch {
                self.reject(i, "500 Internal Server Error", "OOM");
                return false;
            };
            const n = posix.read(conn.stream.handle, conn.buf.unusedCapacitySlice()) catch |err| switch (err) {
                error.WouldBlock => return true,
                else => {
                    self.reject(i, null, "");
                    return false;
                },
            };
            if (n == 0) {
                // EOF before the request was complete.
                if (conn.body_start != null) {
                    self.reject(i, "400 Bad Request", "Incomplete request body");
                } else if (conn.buf.items.len > 0) {
                    self.reject(i, "400 Bad Request", "Incomplete request head");
                } else {
                    self.reject(i, null, "");
                }
                return false;
            }
            const prev_len = conn.buf.items.len;
            conn.buf.items.len += n;
            conn.last_progress = now;

            if (conn.body_start == null) {
                const search_from = prev_len -| 3;
                if (std.mem.indexOfPos(u8, conn.buf.items, search_from, "\r\n\r\n")) |idx| {
                    if (idx + 4 > self.cfg.max_header_bytes) {
                        self.reject(i, "431 Request Header Fields Too Large", "Request head too large");
                        return false;
                    }
                    const head = parseHead(conn.buf.items[0..idx]) catch |err| {
                        switch (err) {
                            error.InvalidContentLength => self.reject(i, "400 Bad Request", "Invalid Content-Length"),
                            error.ChunkedUnsupported => self.reject(i, "411 Length Required", "Chunked transfer encoding not supported"),
                        }
                        return false;
                    };
                    if (head.content_length > self.cfg.max_body_bytes) {
                        self.reject(i, "413 Payload Too Large", "Request too large");
                        return false;
                    }
                    conn.body_start = idx + 4;
                    conn.content_length = head.content_length;
                    conn.buf.ensureTotalCapacity(allocator, idx + 4 + head.content_length) catch {
                        self.reject(i, "500 Internal Server Error", "OOM");
                        return false;
                    };
                    // curl waits up to 1s for this before sending large bodies.
                    if (head.expect_continue and conn.buf.items.len < idx + 4 + head.content_length) {
                        conn.stream.writeAll("HTTP/1.1 100 Continue\r\n\r\n") catch {};
                    }
                } else if (conn.buf.items.len > self.cfg.max_header_bytes) {
                    self.reject(i, "431 Request Header Fields Too Large", "Request head too large");
                    return false;
                }
            }

            if (conn.body_start) |body_start| {
                if (conn.buf.items.len >= body_start + conn.content_length) {
                    self.dispatch(i, body_start + conn.content_length);
                    return false;
                }
            }
        }
    }

    fn dispatch(self: *Reader, i: usize, request_len: usize) void {
        var conn = self.conns.swapRemove(i);
        conn.buf.items.len = request_len; // ignore anything after the body
        setBlocking(conn.stream.handle) catch {
            conn.stream.close();
            conn.buf.deinit(allocator);
            return;
        };
        setSocketTimeouts(conn.stream.handle, self.cfg);
        if (!self.queue.push(.{ .stream = conn.stream, .data = conn.buf })) {
            sendError(conn.stream, "503 Service Unavailable", "Server busy");
            conn.stream.close();
            conn.buf.deinit(allocator);
        }
    }
};

fn parseArgs() !Config {
    var cfg = Config{};
    var args = std.process.args();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\usage: mupdf-server [port] [options]
                \\  port                    TCP port (default 8080)
                \\  --workers N, -w N       worker threads (default: CPU count)
                \\  --queue N               complete requests waiting for a worker (default 1024)
                \\  --max-connections N     connections being read at once (default 1024)
                \\  --read-timeout-ms N     head must arrive / body must progress within N ms (default 10000)
                \\  --write-timeout-ms N    SO_SNDTIMEO for responses (default 10000)
                \\  --max-header-bytes N    request line + headers limit (default 16384)
                \\  --max-body-bytes N      Content-Length limit (default 52428800)
                \\  --store-mb N            total MuPDF resource store budget (default 256)
                \\  --shared-store          workers share one store via fz_clone_context
                \\                          (default: independent context per worker)
                \\
            , .{});
            std.process.exit(0);
        }
        if (!std.mem.startsWith(u8, arg, "-")) {
            cfg.port = try std.fmt.parseInt(u16, arg, 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--shared-store")) {
            cfg.shared_store = true;
            continue;
        }
        const value = args.next() orelse return error.MissingValue;
        if (std.mem.eql(u8, arg, "--workers") or std.mem.eql(u8, arg, "-w")) {
            cfg.workers = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--queue")) {
            cfg.queue_capacity = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--max-connections")) {
            cfg.max_connections = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--read-timeout-ms")) {
            cfg.read_timeout_ms = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--write-timeout-ms")) {
            cfg.write_timeout_ms = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--max-header-bytes")) {
            cfg.max_header_bytes = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--max-body-bytes")) {
            cfg.max_body_bytes = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--store-mb")) {
            cfg.store_mb = try std.fmt.parseInt(usize, value, 10);
        } else {
            return error.UnknownOption;
        }
    }
    if (cfg.workers == 0) cfg.workers = std.Thread.getCpuCount() catch 1;
    if (cfg.queue_capacity == 0) cfg.queue_capacity = 1;
    if (cfg.max_connections == 0) cfg.max_connections = 1;
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

    // Every worker gets its own context: either an independent one with a
    // slice of the store budget, or a clone of one lock-enabled base context.
    const store_bytes = cfg.store_mb << 20;
    var base_ctx: ?mupdf.Context = if (cfg.shared_store) try mupdf.Context.initThreadSafeWithStore(store_bytes) else null;
    defer if (base_ctx) |*b| b.deinit();

    const worker_ctxs = try allocator.alloc(mupdf.Context, cfg.workers);
    defer allocator.free(worker_ctxs);
    for (worker_ctxs) |*wctx| {
        wctx.* = if (base_ctx) |*b|
            try b.clone()
        else
            try mupdf.Context.initWithOptions(null, null, @max(store_bytes / cfg.workers, 16 << 20));
    }
    defer for (worker_ctxs) |*wctx| wctx.deinit();

    var queue = JobQueue{ .items = try allocator.alloc(Job, cfg.queue_capacity) };
    defer allocator.free(queue.items);

    const address = std.net.Address.parseIp4("0.0.0.0", cfg.port) catch unreachable;
    const listener = address.listen(.{ .reuse_address = true, .kernel_backlog = 1024, .force_nonblocking = true }) catch |err| {
        std.debug.print("Failed to bind port {d}: {}\n", .{ cfg.port, err });
        return;
    };

    for (worker_ctxs) |*wctx| {
        const t = try std.Thread.spawn(.{}, workerMain, .{ wctx, &queue });
        t.detach();
    }

    std.debug.print("\n  zig-mupdf server on http://localhost:{d} ({d} workers, {s} store, read timeout {d}ms, write timeout {d}ms, max header {d}B)\n\n", .{
        cfg.port, cfg.workers, if (cfg.shared_store) "shared" else "per-worker", cfg.read_timeout_ms, cfg.write_timeout_ms, cfg.max_header_bytes,
    });

    var reader = Reader{ .cfg = cfg, .listener = listener, .queue = &queue };
    reader.run();
}

//! Mutation fuzz loop for zig-mupdf.
//!
//! Takes the PDFs in tests/fixtures/, applies random byte-level mutations and
//! runs every mutant through open -> count -> metadata -> load page -> bound ->
//! text -> render -> PNG. Any MuPDF exception that escapes a fz_try aborts the
//! process (exit 1), so simply finishing the loop is the pass criterion.
//!
//! Usage:
//!   zig build fuzz -- [iterations] [seed] [corpus_dir]
//!   zig-out/bin/mupdf-fuzz 3000 1 tests/fixtures

const std = @import("std");
const mupdf = @import("mupdf");

const max_pages_per_doc = 3;
const max_render_pixels: f32 = 2_000_000;

var quiet_messages: usize = 0;

/// Swallow MuPDF's per-error/warning chatter, but always surface the fatal
/// "aborting process" message so a crash is visible in the log.
fn onMessage(_: ?*anyopaque, message: [*c]const u8) callconv(.c) void {
    const msg = std.mem.span(message);
    if (std.mem.indexOf(u8, msg, "aborting process") != null) {
        std.debug.print("FATAL: {s}\n", .{msg});
    } else {
        quiet_messages += 1;
    }
}

/// Accept both `T` and `Error!T` so the harness compiles against the API
/// before and after the fallible-call refactor.
fn val(x: anytype) ?Payload(@TypeOf(x)) {
    return switch (@typeInfo(@TypeOf(x))) {
        .error_union => x catch null,
        else => x,
    };
}

fn Payload(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |eu| eu.payload,
        else => T,
    };
}

fn mutate(rng: std.Random, src: []const u8, out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) !void {
    out.clearRetainingCapacity();
    try out.appendSlice(alloc, src);
    const tokens = [_][]const u8{ "-1", "0", "R", " 0 R", "<<", ">>", "[", "]", "obj", "endobj", "stream", "/Parent 2 0 R", "/Count", "/Kids", "/MediaBox [0 0 0 0]", "99999999999", "/Length 0", "(", ")", "%%EOF", "xref" };
    const n_mut = 1 + rng.uintLessThan(usize, 8);
    for (0..n_mut) |_| {
        if (out.items.len == 0) try out.append(alloc, '%');
        const pos = rng.uintLessThan(usize, out.items.len);
        switch (rng.uintLessThan(u8, 6)) {
            0 => out.items[pos] = rng.int(u8), // random byte
            1 => out.items[pos] ^= @as(u8, 1) << rng.int(u3), // bit flip
            2 => { // delete a range
                const len = @min(out.items.len - pos, 1 + rng.uintLessThan(usize, 32));
                out.replaceRangeAssumeCapacity(pos, len, &.{});
            },
            3 => try out.insertSlice(alloc, pos, tokens[rng.uintLessThan(usize, tokens.len)]),
            4 => out.shrinkRetainingCapacity(pos), // truncate
            else => { // duplicate a chunk
                const len = @min(out.items.len - pos, 1 + rng.uintLessThan(usize, 64));
                const chunk = try alloc.dupe(u8, out.items[pos .. pos + len]);
                defer alloc.free(chunk);
                try out.insertSlice(alloc, rng.uintLessThan(usize, out.items.len), chunk);
            },
        }
    }
}

fn exercise(ctx: *mupdf.Context, data: []const u8, alloc: std.mem.Allocator) void {
    var doc = mupdf.Document.openFromMemory(ctx, data, "application/pdf") catch return;
    defer doc.deinit();

    _ = val(doc.authenticate(""));
    var meta = doc.getAllMetadata(alloc) catch null;
    if (meta) |*m| m.deinit();

    const count = val(doc.pageCount()) orelse return;
    var i: i32 = 0;
    while (i < @min(count, max_pages_per_doc)) : (i += 1) {
        var page = doc.loadPage(i) catch continue;
        defer page.deinit();

        const b = val(page.bounds()) orelse continue;
        _ = page.rotation();

        if (page.getText(alloc)) |text| alloc.free(text) else |_| {}

        const area = @abs(b.width() * b.height());
        const scale: f32 = 0.25;
        if (!(area * scale * scale < max_render_pixels)) continue; // also rejects NaN
        var pix = page.toPixmap(scale, 0) catch continue;
        defer pix.deinit();
        if (pix.toPng(alloc)) |png| alloc.free(png) else |_| {}
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = std.process.args();
    _ = args.skip();
    const iterations = if (args.next()) |s| try std.fmt.parseInt(usize, s, 10) else 3000;
    const seed = if (args.next()) |s| try std.fmt.parseInt(u64, s, 10) else 1;
    const corpus_dir = args.next() orelse "tests/fixtures";

    // Load corpus.
    var corpus = std.ArrayListUnmanaged([]u8){};
    defer {
        for (corpus.items) |item| alloc.free(item);
        corpus.deinit(alloc);
    }
    var dir = try std.fs.cwd().openDir(corpus_dir, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".pdf")) continue;
        try corpus.append(alloc, try dir.readFileAlloc(alloc, entry.name, 16 << 20));
    }
    std.mem.sort([]u8, corpus.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return a.len < b.len or (a.len == b.len and std.mem.order(u8, a, b) == .lt);
        }
    }.lt);
    if (corpus.items.len == 0) return error.EmptyCorpus;

    var ctx = try mupdf.Context.init();
    defer ctx.deinit();
    mupdf.c.c.fz_set_error_callback(ctx.ptr, onMessage, null);
    mupdf.c.c.fz_set_warning_callback(ctx.ptr, onMessage, null);

    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(alloc);

    std.debug.print("fuzz: corpus={d} files, iterations={d}, seed={d}\n", .{ corpus.items.len, iterations, seed });
    var timer = try std.time.Timer.start();
    for (0..iterations) |iter| {
        const src = corpus.items[rng.uintLessThan(usize, corpus.items.len)];
        try mutate(rng, src, &buf, alloc);
        // Record the mutant being processed so a crash can be reproduced.
        std.fs.cwd().writeFile(.{ .sub_path = "zig-out/fuzz-current.pdf", .data = buf.items }) catch {};
        std.debug.print("iter {d}\n", .{iter});
        exercise(&ctx, buf.items, alloc);
    }
    const secs = @as(f64, @floatFromInt(timer.read())) / 1e9;
    std.debug.print("fuzz: completed {d}/{d} iterations in {d:.1}s, 0 aborts ({d} MuPDF errors/warnings handled)\n", .{ iterations, iterations, secs, quiet_messages });
}

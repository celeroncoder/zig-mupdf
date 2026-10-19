//! In-process engine benchmark: times zig-mupdf library calls directly (no HTTP).
//!
//! Mirrors benchmarks/engine_benchmark.py (PyMuPDF) operation for operation:
//!   open   - open from memory + page count
//!   text   - open + load page + plain-text extraction
//!   render - open + load page + render at scale + PNG encode
//!
//! Usage: zig build bench-engine -- [pdf] [iterations] [page]
//! Prints one JSON object per operation: {"op":..,"median_ms":..,...}

const std = @import("std");
const mupdf = @import("mupdf");

const alloc = std.heap.c_allocator;

fn opOpen(ctx: *mupdf.Context, data: []const u8, page: i32) !void {
    _ = page;
    var doc = try mupdf.Document.openFromMemory(ctx, data, "application/pdf");
    defer doc.deinit();
    _ = try doc.pageCount();
}

fn opText(ctx: *mupdf.Context, data: []const u8, page_num: i32) !void {
    var doc = try mupdf.Document.openFromMemory(ctx, data, "application/pdf");
    defer doc.deinit();
    var page = try doc.loadPage(page_num);
    defer page.deinit();
    const text = try page.getText(alloc);
    alloc.free(text);
}

fn opRender(comptime scale: f32) fn (*mupdf.Context, []const u8, i32) anyerror!void {
    return struct {
        fn f(ctx: *mupdf.Context, data: []const u8, page_num: i32) anyerror!void {
            var doc = try mupdf.Document.openFromMemory(ctx, data, "application/pdf");
            defer doc.deinit();
            var page = try doc.loadPage(page_num);
            defer page.deinit();
            var pix = try page.toPixmap(scale, 0);
            defer pix.deinit();
            const png = try pix.toPng(alloc);
            alloc.free(png);
        }
    }.f;
}

fn lessThan(_: void, a: f64, b: f64) bool {
    return a < b;
}

fn bench(name: []const u8, ctx: *mupdf.Context, data: []const u8, page: i32, iters: usize, comptime op: anytype) !void {
    const samples = try alloc.alloc(f64, iters);
    defer alloc.free(samples);
    for (0..3) |_| try op(ctx, data, page); // warm-up
    for (samples) |*s| {
        var t = try std.time.Timer.start();
        try op(ctx, data, page);
        s.* = @as(f64, @floatFromInt(t.read())) / 1e6;
    }
    std.mem.sort(f64, samples, {}, lessThan);
    var sum: f64 = 0;
    for (samples) |s| sum += s;
    const out = std.fs.File.stdout();
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "{{\"op\":\"{s}\",\"iterations\":{d},\"median_ms\":{d:.3},\"mean_ms\":{d:.3},\"p95_ms\":{d:.3},\"min_ms\":{d:.3}}}\n", .{
        name, iters, samples[iters / 2], sum / @as(f64, @floatFromInt(iters)), samples[(iters * 95) / 100], samples[0],
    });
    try out.writeAll(line);
}

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip();
    const path = args.next() orelse "examples/example.pdf";
    const iters = if (args.next()) |s| try std.fmt.parseInt(usize, s, 10) else 30;
    const page = if (args.next()) |s| try std.fmt.parseInt(i32, s, 10) else 0;

    const data = try std.fs.cwd().readFileAlloc(alloc, path, 512 << 20);
    defer alloc.free(data);

    var ctx = try mupdf.Context.init();
    defer ctx.deinit();
    // The sample PDF triggers repair warnings on every open; keep stderr quiet.
    mupdf.c.c.fz_set_warning_callback(ctx.ptr, null, null);
    mupdf.c.c.fz_set_error_callback(ctx.ptr, null, null);

    try bench("open", &ctx, data, page, iters, opOpen);
    try bench("text", &ctx, data, page, iters, opText);
    try bench("render_1x_png", &ctx, data, page, iters, opRender(1.0));
    try bench("render_2x_png", &ctx, data, page, iters, opRender(2.0));
}

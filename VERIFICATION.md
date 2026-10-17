# Verification log

Verification-review fixes for `main @ 7d0fca5`. Each issue follows the loop
**reproduce → fix → re-verify**, and the exact commands below can be re-run.

**Machine:** Intel Xeon @ 2.60GHz, **2 vCPUs**, 7 GiB RAM, Linux 6.1, Zig 0.15.2.
The 2-core limit caps how far concurrency can scale; see Issue 2.

**Baseline test suite (unfixed):** `zig build test --summary all` gives `Build Summary: 5/5 steps succeeded; 99/99 tests passed`.

---

## Issue 1 (HIGH): MuPDF calls bypass the `fz_try` shim, so one throw kills the process

### Audit of direct `c.c.fz_*` / `c.c.pdf_*` calls in `src/`, `examples/`, `tests/`

I checked each call against the MuPDF source in `.context/mupdf`.

| Call | Where | Can throw? | Action |
|---|---|---|---|
| `fz_count_pages` | `Document.pageCount` | **Yes**: `pdf_count_pages` throws "Invalid number of pages"; page-tree loaders throw | **Wrapped**: `mupdf_shim_count_pages`, now `Error!i32` |
| `fz_needs_password` | `Document.needsPassword` | **Yes** (dispatches to `pdf_needs_password` → authenticate; XPS/others via handler) | **Wrapped**: `mupdf_shim_needs_password`, now `Error!bool` |
| `fz_authenticate_password` | `Document.authenticate` | **Yes** (crypt key derivation, handler dispatch) | **Wrapped**: `mupdf_shim_authenticate_password`, now `Error!bool` |
| `fz_lookup_metadata` (×2) | `Document.getMetadataRaw` | **Yes** (`pdf_dict_get` on the trailer can resolve or repair objects; handler dispatch) | **Wrapped**: `mupdf_shim_lookup_metadata` (−2 = error, distinct from −1 = not found), mapped to `Error.MupdfError` |
| `fz_set_metadata` | `Document.setMetadataRaw` | **Yes** (`pdf_begin_operation`, `pdf_add_new_dict`, `pdf_dict_put*` can throw) | **Wrapped**: `mupdf_shim_set_metadata`, returns `Error.MupdfError` |
| `fz_bound_page` | `Page.bounds` / `width` / `height` | **Yes**: `pdf_dict_get_inheritable` throws "cycle in resources" | **Wrapped**: `mupdf_shim_bound_page`, now `Error!Rect` / `Error!f32` |
| `fz_save_pixmap_as_png` | `Pixmap.savePng` | **Yes**: `fz_new_output_with_path` throws if the file can't be opened | **Wrapped**: `mupdf_shim_save_pixmap_as_png`, returns `Error.WriteFailed` |
| `fz_register_document_handlers` | `Context.initWithOptions` | Yes in principle ("too many document handlers", OOM) | **Wrapped** defensively: `mupdf_shim_register_document_handlers`, returns `Error.ContextCreationFailed` |
| `fz_new_context` | `Context.initWithOptions` | No: returns NULL on failure | — |
| `fz_clone_context` | `Context.clone` | No: returns NULL (no locks, or malloc failure) | — |
| `fz_drop_context/document/page/pixmap/stext_page/buffer/image/link/outline` | `deinit`s | No: MuPDF drop functions never throw | — |
| `fz_device_rgb/gray/cmyk` | `Context`, `Page.toPixmapWithMatrix` | No: returns `ctx->colorspace->rgb` etc. | — |
| `pdf_specifics`, `pdf_page_from_fz_page` | `isPdf`/`asPdf`, page helpers | No: pointer/type checks only | — |
| `fz_buffer_storage` | `TextPage.getText`, `Pixmap.toPng` | No: field access | — |
| `fz_pixmap_width/height/components/stride/samples` | `Pixmap` accessors | No: field access | — |
| `fz_scale/rotate/translate/shear/concat/pre_*`, `fz_invert_matrix`, `fz_is_rectilinear`, `fz_matrix_expansion`, `fz_transform_point_xy`, `fz_transform_rect` | `Matrix` | No: pure math | — |
| `fz_set_error_callback`, `fz_set_warning_callback` | `tests/fuzz.zig` | No: field assignment | — |

`src/mupdf_shim.c` was also checked. Every call outside a `fz_try` is a plain field accessor that can't throw (`fz_font_flags`, `fz_font_name`, the image/outline accessors). `src/c.zig` still re-exports the raw C functions (`c.fz_count_pages` and others) as an escape hatch for low-level users. The safe Zig API no longer uses them.

### Reproduce

Crafted fixtures (`scripts/repro/make_malformed_fixtures.py` writes them to `tests/fixtures/malformed_*.pdf`; each has a correct xref, so MuPDF parses the broken structure as written instead of repairing it):

| Fixture | Defect | Throwing call |
|---|---|---|
| `malformed_negative_count.pdf` | `/Pages /Count -1` | `fz_count_pages` |
| `malformed_huge_count.pdf` | `/Count 2147483647` (more than the number of objects) | `fz_count_pages` |
| `malformed_parent_cycle.pdf` | page with no MediaBox whose `/Parent` chain is a cycle | `fz_bound_page` |
| `malformed_broken_info.pdf` | `/Info` with garbage values, Catalog `/Pages` points to a missing object | (handled; no throw reached) |
| `malformed_truncated.pdf` | `text_sample.pdf` cut in half | (repaired) |
| `malformed_bad_xref.pdf` | xref offsets point into other objects | (repaired) |

Command: `scripts/repro/issue1_uncaught_throw.sh 8080`

Before:
```
== library (pdf-info example) on crafted fixtures ==
tests/fixtures/malformed_bad_xref.pdf         exit=0   uncaught_abort=0
tests/fixtures/malformed_broken_info.pdf      exit=0   uncaught_abort=0
tests/fixtures/malformed_huge_count.pdf       exit=1   uncaught_abort=1
tests/fixtures/malformed_negative_count.pdf   exit=1   uncaught_abort=1
tests/fixtures/malformed_parent_cycle.pdf     exit=1   uncaught_abort=1
tests/fixtures/malformed_truncated.pdf        exit=0   uncaught_abort=0
== server: POST crafted fixtures, then GET /health ==
malformed_negative_count     /info    http=000 server_alive=NO
  server exit status: 1
  server log: aborting process from uncaught error!
malformed_negative_count     /text    http=000 server_alive=NO
  server exit status: 1
  server log: aborting process from uncaught error!
malformed_negative_count     /render  http=000 server_alive=NO
  server exit status: 1
  server log: aborting process from uncaught error!
malformed_huge_count         /info    http=000 server_alive=NO
  server exit status: 1
  server log: aborting process from uncaught error!
malformed_huge_count         /text    http=000 server_alive=NO
  server exit status: 1
  server log: aborting process from uncaught error!
malformed_huge_count         /render  http=000 server_alive=NO
  server exit status: 1
  server log: aborting process from uncaught error!
malformed_parent_cycle       /info    http=000 server_alive=NO
  server exit status: 1
  server log: aborting process from uncaught error!
malformed_parent_cycle       /text    http=500 server_alive=yes
malformed_parent_cycle       /render  http=500 server_alive=yes
RESULT: FAIL
```

Fuzz, before. `scripts/repro/issue1_fuzz.sh 3000 20 <corpus>` ran against the **unfixed** `main` sources (same harness and build flags, ReleaseFast):
```
### BEFORE (main @ 7d0fca5 sources, ReleaseFast, corpus = 4 original well-formed fixtures)
seed=1   exit=1 died_at_iter=1758  FATAL: aborting process from uncaught error!
seed=2   exit=1 died_at_iter=965   FATAL: aborting process from uncaught error!
seed=3   exit=1 died_at_iter=2097  FATAL: aborting process from uncaught error!
seed=4   exit=1 died_at_iter=83    FATAL: aborting process from uncaught error!
seed=5   exit=1 died_at_iter=1052  FATAL: aborting process from uncaught error!
seed=6   exit=1 died_at_iter=582   FATAL: aborting process from uncaught error!
seed=7   exit=1 died_at_iter=1356  FATAL: aborting process from uncaught error!
seed=8   exit=1 died_at_iter=1139  FATAL: aborting process from uncaught error!
seed=9   exit=1 died_at_iter=1486  FATAL: aborting process from uncaught error!
seed=10  exit=1 died_at_iter=622   FATAL: aborting process from uncaught error!
seed=11  exit=1 died_at_iter=65    FATAL: aborting process from uncaught error!
seed=12  exit=1 died_at_iter=94    FATAL: aborting process from uncaught error!
seed=13  exit=1 died_at_iter=37    FATAL: aborting process from uncaught error!
seed=14  exit=1 died_at_iter=135   FATAL: aborting process from uncaught error!
seed=15  exit=1 died_at_iter=453   FATAL: aborting process from uncaught error!
seed=16  exit=1 died_at_iter=1288  FATAL: aborting process from uncaught error!
seed=17  exit=1 died_at_iter=468   FATAL: aborting process from uncaught error!
seed=18  exit=1 died_at_iter=170   FATAL: aborting process from uncaught error!
seed=19  exit=1 died_at_iter=945   FATAL: aborting process from uncaught error!
seed=20  exit=1 died_at_iter=379   FATAL: aborting process from uncaught error!
TOTAL: seeds=20 iterations_executed=15194 process_aborts=20

### BEFORE (main sources, ReleaseFast, corpus = tests/fixtures incl. malformed_*)
seed=1   exit=1 died_at_iter=30    FATAL: aborting process from uncaught error!
seed=2   exit=1 died_at_iter=1     FATAL: aborting process from uncaught error!
seed=3   exit=1 died_at_iter=1     FATAL: aborting process from uncaught error!
seed=4   exit=1 died_at_iter=5     FATAL: aborting process from uncaught error!
seed=5   exit=1 died_at_iter=4     FATAL: aborting process from uncaught error!
seed=6   exit=1 died_at_iter=14    FATAL: aborting process from uncaught error!
seed=7   exit=1 died_at_iter=14    FATAL: aborting process from uncaught error!
seed=8   exit=1 died_at_iter=0     FATAL: aborting process from uncaught error!
seed=9   exit=1 died_at_iter=14    FATAL: aborting process from uncaught error!
seed=10  exit=1 died_at_iter=3     FATAL: aborting process from uncaught error!
seed=11  exit=1 died_at_iter=20    FATAL: aborting process from uncaught error!
seed=12  exit=1 died_at_iter=4     FATAL: aborting process from uncaught error!
seed=13  exit=1 died_at_iter=3     FATAL: aborting process from uncaught error!
seed=14  exit=1 died_at_iter=42    FATAL: aborting process from uncaught error!
seed=15  exit=1 died_at_iter=5     FATAL: aborting process from uncaught error!
seed=16  exit=1 died_at_iter=0     FATAL: aborting process from uncaught error!
seed=17  exit=1 died_at_iter=33    FATAL: aborting process from uncaught error!
seed=18  exit=1 died_at_iter=11    FATAL: aborting process from uncaught error!
seed=19  exit=1 died_at_iter=21    FATAL: aborting process from uncaught error!
seed=20  exit=1 died_at_iter=0     FATAL: aborting process from uncaught error!
TOTAL: seeds=20 iterations_executed=245 process_aborts=20
```

So without the fix, **every** fuzz run aborts the process, even when only the 4 original well-formed fixtures are mutated (mean ≈ 760 iterations before death).

### Fix

* `src/mupdf_shim.c/.h`: new `fz_try`/`fz_catch` wrappers: `mupdf_shim_count_pages`, `mupdf_shim_needs_password`, `mupdf_shim_authenticate_password`, `mupdf_shim_lookup_metadata`, `mupdf_shim_set_metadata`, `mupdf_shim_bound_page`, `mupdf_shim_save_pixmap_as_png`, `mupdf_shim_register_document_handlers`.
* `src/document.zig` / `src/context.zig`: route every throwing call through those shims and map failures to Zig errors. **API change:** `pageCount()`, `needsPassword()`, `authenticate()`, `Page.bounds()`, `width()`, `height()` now return error unions.
* `examples/server.zig`: a malformed page tree now returns `422 Unprocessable Entity`. `/info` skips pages whose bounds can't be computed.
* `examples/pdf_info.zig`: reports the errors instead of dying.
* Regression tests (7 new, in `src/document.zig`) use the crafted fixtures, plus an unwritable-path `savePng` test.
* `tests/fuzz.zig` plus `zig build fuzz -- <iters> <seed> <corpus>`: an in-process mutation fuzz loop (byte/bit flips, deletions, PDF-token insertions, truncation, chunk duplication). Each mutant goes through open → authenticate → metadata → count → load page → bound → rotation → text → render → PNG.
* `build.zig`: new option `-Dsanitize-mupdf=<bool>` (see the limitation below).

### Re-verify

`scripts/repro/issue1_uncaught_throw.sh 8080`:
```
== library (pdf-info example) on crafted fixtures ==
tests/fixtures/malformed_bad_xref.pdf         exit=0   uncaught_abort=0
tests/fixtures/malformed_broken_info.pdf      exit=0   uncaught_abort=0
tests/fixtures/malformed_huge_count.pdf       exit=0   uncaught_abort=0
tests/fixtures/malformed_negative_count.pdf   exit=0   uncaught_abort=0
tests/fixtures/malformed_parent_cycle.pdf     exit=0   uncaught_abort=0
tests/fixtures/malformed_truncated.pdf        exit=0   uncaught_abort=0
== server: POST crafted fixtures, then GET /health ==
malformed_negative_count     /info    http=422 server_alive=yes
malformed_negative_count     /text    http=422 server_alive=yes
malformed_negative_count     /render  http=422 server_alive=yes
malformed_huge_count         /info    http=422 server_alive=yes
malformed_huge_count         /text    http=422 server_alive=yes
malformed_huge_count         /render  http=422 server_alive=yes
malformed_parent_cycle       /info    http=200 server_alive=yes
malformed_parent_cycle       /text    http=500 server_alive=yes
malformed_parent_cycle       /render  http=500 server_alive=yes
RESULT: PASS
```

Fuzz, after (`scripts/repro/issue1_fuzz.sh 3000 20 <corpus>`; per-seed lines trimmed):
```
### AFTER (fixed, ReleaseFast, corpus = 4 original well-formed fixtures)
TOTAL: seeds=20 iterations_executed=60000 process_aborts=0
### AFTER (fixed, ReleaseFast, corpus = tests/fixtures incl. malformed_*)
TOTAL: seeds=20 iterations_executed=60000 process_aborts=0
### AFTER (fixed, Debug, -Dsanitize-mupdf=false, corpus = tests/fixtures)
TOTAL: seeds=10 iterations_executed=30000 process_aborts=0
```

**Fuzz summary:** before the fix, 40/40 runs aborted (15,439 iterations executed in total). After the fix, 50/50 runs completed: **150,000 iterations, 0 process aborts**.

`zig build test --summary all` after the fix: `106/106 tests passed` (99 existing + 7 new).

### Known limitation (not fixed: upstream MuPDF)

In **Debug** builds, Zig compiles C with UBSan by default. Upstream MuPDF code has undefined behaviour on malformed input, and UBSan turns it into a panic (SIGABRT, exit 134). The fuzzer found these sites, none of which are in this repo's code:

* `source/pdf/pdf-page.c:160` `qsort(NULL, 0, …)` (null pointer argument)
* `source/fitz/pixmap.c:1253` `memcpy` with a NULL source on an empty pixmap
* `source/pdf/pdf-interpret.c:1318/1321` left shift of a negative value
* `source/pdf/pdf-lex.c:182` signed `int64` overflow in `fast_atoi`
* `source/fitz/draw-device.c:1135`, `source/pdf/pdf-xref.c:977` float→int out of range

They are all harmless in practice, and ReleaseFast and ReleaseSmall builds have no UBSan. I didn't patch vendored MuPDF. Debug builds keep UBSan on by default so real memory bugs stay visible; pass `-Dsanitize-mupdf=false` to run a Debug server on untrusted input. Evidence (Debug, default UBSan): `TOTAL: seeds=10 iterations_executed=1725 process_aborts=10`. All 10 aborts are UBSan panics in the MuPDF sources above, and none is an uncaught `fz_throw`.

I couldn't build a fixture that makes `fz_lookup_metadata`, `fz_set_metadata` or `fz_authenticate_password` throw (on the PDF handler they mostly catch internally or only throw on OOM). They are wrapped defensively anyway.

---

## Issue 2 (HIGH): the server is strictly single-threaded

### Reproduce

Command (ReleaseFast build): `scripts/repro/issue2_concurrency.sh 8080`. It times 16 `/render` requests (page 1..16, scale 2) serially vs. all at once (`curl &` + `wait`), then runs a closed-loop load at concurrency 1/2/4/8 (`benchmarks/loadgen.py`).

Before:
```
cpus: 2  server args: 8080 
16x /render scale=2  serial: 1.26s (16 ok)   parallel: 1.16s (16 ok)   speedup: 1.08x
-- closed-loop load (benchmarks/loadgen.py) --
endpoint   conc    ok  err    req/s   p50 ms   p95 ms   p99 ms
/render       1    32    0    11.89     83.4     85.8     86.0
/render       2    32    0    11.65    165.2    189.2    192.5
/render       4    32    0    11.66    335.8    348.9    349.8
/render       8    32    0    11.11    673.9    729.0    730.5
/text         1    64    0    52.24     18.1     24.5     24.9
/text         2    64    0    55.44     34.3     40.2     41.5
/text         4    64    0    55.13     68.7     73.6     75.0
/text         8    64    0    49.07    141.3    149.4    150.3
```
Parallel takes the same time as serial (1.08×). req/s stays flat as concurrency rises, and p50 grows linearly, so requests just queue behind each other.

### Fix

* `src/context.zig`: new `Context.initThreadSafe()` / `initThreadSafeWithStore()`. These install a real `fz_locks_context` backed by `FZ_LOCK_MAX` `std.Thread.Mutex`es, owned by the base context (`Context.locks`) and freed in `deinit`. `clone()` now works on such contexts. New tests: `Context.initThreadSafe allows clone`, plus a 4-thread test in which each thread clones, opens, extracts text, renders and PNG-encodes ×10 and gets identical results.
* `examples/server.zig`:
  * The global `fz_context` is gone. `main` creates one lock-enabled base context and **one cloned context per worker**, and handlers receive their worker's context. No context is ever shared between threads.
  * A fixed worker pool (`--workers N`, default = CPU count) pops accepted connections from a bounded queue (`--queue N`, default 1024). When the queue is full, new connections get `503`.
  * The allocator is now `std.heap.c_allocator` (thread-safe malloc) instead of a GPA.

### Re-verify

Same command, default workers (= 2 CPUs):
```
cpus: 2  server args: 8080 
  zig-mupdf server on http://localhost:8080 (2 workers)
16x /render scale=2  serial: 1.31s (16 ok)   parallel: 0.71s (16 ok)   speedup: 1.85x
-- closed-loop load (benchmarks/loadgen.py) --
endpoint   conc    ok  err    req/s   p50 ms   p95 ms   p99 ms
/render       1    32    0    11.78     83.7     88.4     90.9
/render       2    32    0    19.10     92.9    135.6    163.0
/render       4    32    0    18.67    198.7    228.3    241.6
/render       8    32    0    17.92    376.2    436.4    447.3
/text         1    64    0    52.55     18.1     20.6     28.7
/text         2    64    0    71.40     24.5     37.4     44.1
/text         4    64    0    69.93     49.5     60.0     65.6
/text         8    64    0    63.60     98.8    139.3    143.3
```
Control run with `--workers 1` (behaves like the old server, as expected):
```
cpus: 2  server args: 8080 --workers 1
  zig-mupdf server on http://localhost:8080 (1 workers)
16x /render scale=2  serial: 1.27s (16 ok)   parallel: 1.19s (16 ok)   speedup: 1.07x
-- closed-loop load (benchmarks/loadgen.py) --
endpoint   conc    ok  err    req/s   p50 ms   p95 ms   p99 ms
/render       1    32    0    11.52     84.6     94.3     97.5
/render       2    32    0    11.90    162.4    177.7    183.5
/render       4    32    0    11.37    337.6    354.9    355.2
```

| /render scale=2 | before req/s | after req/s | before p50 / p95 ms | after p50 / p95 ms |
|---|---:|---:|---:|---:|
| c=1 | 11.89 | 11.78 | 83.4 / 85.8 | 83.7 / 88.4 |
| c=2 | 11.65 | **19.10** | 165.2 / 189.2 | **92.9 / 135.6** |
| c=4 | 11.66 | **18.67** | 335.8 / 348.9 | **198.7 / 228.3** |
| c=8 | 11.11 | **17.92** | 673.9 / 729.0 | **376.2 / 436.4** |

| /text page 0 | before req/s | after req/s | before p50 / p95 ms | after p50 / p95 ms |
|---|---:|---:|---:|---:|
| c=1 | 52.24 | 52.55 | 18.1 / 24.5 | 18.1 / 20.6 |
| c=2 | 55.44 | **71.40** | 34.3 / 40.2 | **24.5 / 37.4** |
| c=4 | 55.13 | **69.93** | 68.7 / 73.6 | **49.5 / 60.0** |
| c=8 | 49.07 | **63.60** | 141.3 / 149.4 | **98.8 / 139.3** |

Throughput now scales with the cores available. This VM has **2 vCPUs**, so the ceiling is about 2×: `/render` gets 1.6–1.85×, which is near-linear. `/text` gets about 1.35×, because each request is only ~18 ms of server work and the Python load generator and curl compete with the server for the same 2 cores. Past c=2 throughput plateaus, as it should when all cores are busy. I couldn't test scaling beyond 2 cores on this machine.

Thread-safety soak (Debug build, safety checks on, `--workers 4`): 120 requests each of `/render`, `/text`, `/search`, `/info` at c=8 gave 0 errors, 0 panics, and the server stayed alive.

`zig build test --summary all`: `108/108 tests passed`.

---

## Issue 3 (HIGH): one idle connection blocks the whole server (slowloris)

### Reproduce

Command: `scripts/repro/issue3_slowloris.sh 8080 8`. It runs 7 cases:
* (A) open 8 idle sockets with `exec N<>/dev/tcp/…` (4× the worker count), then `curl -m 3 /health`
* (B) stalled partial request line
* (C) `Content-Length: 100000` with only 10 body bytes, then the client half-closes
* (D) the same as C, but the client stalls instead
* (E) 64 KiB header with no terminator
* (F) `Content-Length: abc`
* (G) a slowloris that trickles one header byte every 0.5 s

Before (built from the Issue-2 commit `9c4fb3f`, so 2 workers are already in place):
```
  zig-mupdf server on http://localhost:8081 (2 workers)
== A) 8 idle sockets, then GET /health with curl -m 3 ==
  curl exit=28 time=3.03s  http=000
== B) stalled partial request line (sent 'POST /te', then nothing) ==
  after 20.0s: connection still-open, response: <no response>
== C) Content-Length: 100000 but only 10 body bytes, then client half-closes ==
  after 0.0s: HTTP/1.1 400 Bad Request  body={"error":"Failed to open PDF"}
== D) Content-Length: 100000 but only 10 body bytes, client stalls ==
  after 20.0s: connection still-open, response: <no response>
== E) 64 KiB of header without terminator ==
  after 0.0s: <no response>
== F) Content-Length: abc ==
  after 0.0s: HTTP/1.1 400 Bad Request  body={"error":"No file"}
== G) trickle one header byte every 0.5s for up to 30s ==
  after 30.1s: connection still-open
server alive: yes
final /health http=200
RESULT: FAIL
```
The thread pool alone doesn't help: 8 idle sockets pin both workers forever. C and F "work" only by accident. The 10 truncated body bytes (C) and the empty body after `Content-Length: abc` was read as 0 (F) are handed to MuPDF as a PDF. That is the `recv(MSG_WAITALL)`-returned-short bug.

### Fix (`examples/server.zig`)

* **Workers never read from sockets.** The main thread runs a non-blocking `poll()` loop that accepts connections and buffers each request. Only complete requests are queued to the worker pool, so an idle client costs an fd and a small buffer, not a worker.
* **Deadlines** (`--read-timeout-ms`, default 10 000): the request head must arrive within the timeout from accept. This is a total deadline, which defeats trickling (G). The body must make progress at least once per timeout. A stalled client gets `408` (or is just disconnected if it sent nothing).
* **Limits:** `--max-header-bytes` (default 16 KiB) returns `431`. `--max-body-bytes` (default 50 MiB) returns `413`. `--max-connections` (default 1024) and `--queue` return `503` when full.
* **Strict framing:** an invalid or conflicting `Content-Length` returns `400`. `Transfer-Encoding` returns `411`. EOF before `Content-Length` bytes have arrived returns `400 Incomplete request body`, so nothing truncated is ever parsed. The `recv(MSG_WAITALL)` path is removed.
* `SO_RCVTIMEO` / `SO_SNDTIMEO` (`--read-timeout-ms` / `--write-timeout-ms`) are set on each socket before it reaches a worker. Responses use `writeAll` (the old single `write()` could send a truncated PNG).

### A crash found while re-verifying, and its fix

Re-running the Issue-2 load against this build segfaulted once in about three runs under CPU contention:
```
Segmentation fault at address 0x8
source/pdf/pdf-xref.c:428  pdf_get_xref_entry_aux
source/pdf/pdf-object.c:681 do_objcmp
source/fitz/store.c:610    fz_find_item
source/pdf/pdf-function.c:1474 pdf_load_function_imp
...
```
This is an **upstream MuPDF 1.28 race between cloned contexts**. The resource store is shared by clones, and keys that are direct objects are not hashed, so `fz_find_item` linearly compares them using `pdf_objcmp`. That reads the *owning document's* xref (`DICT(a)->doc`), which can belong to another thread. Meanwhile `pdf_drop_document_imp` frees the xref (`pdf_drop_xref_sections`) **before** it calls `pdf_empty_store`, so another thread can compare against a half-dropped document. Issue 2's design (clones sharing one store) exposes this.

Fix:
1. **Library:** `Document.deinit` now calls `mupdf_shim_drop_document`, which runs `pdf_empty_store()` while the xref is still intact and then drops the document. With this, the replay that crashed survived 6/6 rounds under a CPU hog, versus a crash in 1 of 3 without it.
2. **Server default: independent per-worker contexts** (`Context.initWithOptions`, store budget `--store-mb` split across workers), so no store is shared at all. The same cross-document compare can also read a document that its own thread is lazily repairing, and hostile input can trigger that repair; independent contexts rule this out completely. The Issue-2 design (one `initThreadSafe()` base plus `fz_clone_context` per worker) is still available as `--shared-store`.

Hostile concurrent stress (`scripts/repro/hostile_concurrency.py`): 8 threads for 120 s post a mix of the real PDF and random mutants to `/render`, `/text`, `/info` (ReleaseFast with a segfault handler, 4 workers):
```
  zig-mupdf server on http://localhost:8086 (4 workers, per-worker store, read timeout 10000ms, write timeout 10000ms, max header 16384B)
requests=22754 status_counts={200: 13567, 400: 8169, 422: 967, 500: 51} server_alive=True
alive ()
  zig-mupdf server on http://localhost:8086 (4 workers, shared store, read timeout 10000ms, write timeout 10000ms, max header 16384B)
requests=16497 status_counts={200: 9835, 400: 5929, 422: 693, 500: 40} server_alive=True
alive (--shared-store)
```
Neither mode crashed. The per-worker mode also completed 38% more requests (no store-lock contention).

### Re-verify

`scripts/repro/issue3_slowloris.sh 8080 8`:
```
  zig-mupdf server on http://localhost:8080 (2 workers, per-worker store, read timeout 10000ms, write timeout 10000ms, max header 16384B)
== A) 8 idle sockets, then GET /health with curl -m 3 ==
  curl exit=0 time=0.01s {"status":"ok","service":"zig-mupdf"} http=200
== B) stalled partial request line (sent 'POST /te', then nothing) ==
  after 10.0s: connection closed, response: HTTP/1.1 408 Request Timeout  body={"error":"Request not received in time"}
== C) Content-Length: 100000 but only 10 body bytes, then client half-closes ==
  after 0.0s: HTTP/1.1 400 Bad Request  body={"error":"Incomplete request body"}
== D) Content-Length: 100000 but only 10 body bytes, client stalls ==
  after 10.0s: connection closed, response: HTTP/1.1 408 Request Timeout  body={"error":"Request not received in time"}
== E) 64 KiB of header without terminator ==
  after 0.0s: HTTP/1.1 431 Request Header Fields Too Large  body={"error":"Request head too large"}
== F) Content-Length: abc ==
  after 0.0s: HTTP/1.1 400 Bad Request  body={"error":"Invalid Content-Length"}
== G) trickle one header byte every 0.5s for up to 30s ==
  after 10.0s: connection closed
server alive: yes
final /health http=200
RESULT: PASS
```
With **200 idle sockets** and a 2 s timeout (`scripts/repro/issue3_slowloris.sh 8080 200 --read-timeout-ms 2000`):
```
  zig-mupdf server on http://localhost:8080 (2 workers, per-worker store, read timeout 2000ms, write timeout 10000ms, max header 16384B)
== A) 200 idle sockets, then GET /health with curl -m 3 ==
  curl exit=0 time=0.01s {"status":"ok","service":"zig-mupdf"} http=200
== B) stalled partial request line (sent 'POST /te', then nothing) ==
  after 2.0s: connection closed, response: HTTP/1.1 408 Request Timeout  body={"error":"Request not received in time"}
== C) Content-Length: 100000 but only 10 body bytes, then client half-closes ==
  after 0.0s: HTTP/1.1 400 Bad Request  body={"error":"Incomplete request body"}
== D) Content-Length: 100000 but only 10 body bytes, client stalls ==
  after 2.0s: connection closed, response: HTTP/1.1 408 Request Timeout  body={"error":"Request not received in time"}
== E) 64 KiB of header without terminator ==
  after 0.0s: HTTP/1.1 431 Request Header Fields Too Large  body={"error":"Request head too large"}
== F) Content-Length: abc ==
  after 0.0s: HTTP/1.1 400 Bad Request  body={"error":"Invalid Content-Length"}
== G) trickle one header byte every 0.5s for up to 30s ==
  after 2.0s: connection closed
server alive: yes
final /health http=200
RESULT: PASS
```
Issue-2 check re-run on this build (`scripts/repro/issue2_concurrency.sh 8080`). Scaling improves further with independent contexts: `/text` now reaches 1.96× at c=2.
```
cpus: 2  server args: 8080 
  zig-mupdf server on http://localhost:8080 (2 workers, per-worker store, read timeout 10000ms, write timeout 10000ms, max header 16384B)
16x /render scale=2  serial: 1.31s (16 ok)   parallel: 0.72s (16 ok)   speedup: 1.83x
-- closed-loop load (benchmarks/loadgen.py) --
endpoint   conc    ok  err    req/s   p50 ms   p95 ms   p99 ms
/render       1    32    0    11.53     84.3     97.8    103.5
/render       2    32    0    21.01     85.6    124.4    128.4
/render       4    32    0    20.66    173.1    216.5    224.6
/render       8    32    0    20.71    337.3    359.4    359.9
/text         1    64    0    53.33     18.0     20.6     23.5
/text         2    64    0   104.33     18.2     19.4     20.0
/text         4    64    0    86.68     36.9     56.2     59.7
/text         8    64    0    82.71     74.1     81.4     81.7
```
`scripts/repro/issue1_uncaught_throw.sh` still passes. `zig build test --summary all`: `108/108 tests passed`.

**Also found (not fixed: upstream MuPDF):** a Debug build of the server (`zig build run-server` without `-Doptimize`) panics on the shipped `examples/example.pdf` page 1 at scale 2, because UBSan flags a signed overflow in `source/fitz/draw-rasterize.c:251`. ReleaseSafe trap-mode UBSan also trips inside lcms2 (`cmslut.c:1446`, a function-pointer type check). This is the same class as the Issue-1 limitation. Use ReleaseFast for serving, or `-Dsanitize-mupdf=false`.

---

## Issue 4 (MEDIUM): format/font coverage is trimmed, and the README overstates it

### Reproduce

Command: `scripts/repro/issue4_formats.sh`. It writes one tiny sample per format (`scripts/repro/make_format_fixtures.py` → `tests/fixtures/formats/`) and opens each with `pdf-info`. It then checks that README has a matching "Supported formats" row and greps the docs for overclaims.

Before:
```
PDF     opens=yes README=missing  MISMATCH
XPS     opens=yes README=missing  MISMATCH
SVG     opens=yes README=missing  MISMATCH
CBZ     opens=yes README=missing  MISMATCH
Images  opens=yes README=missing  MISMATCH
EPUB    opens=no  README=missing  MISMATCH
HTML    opens=no  README=missing  MISMATCH
TXT     opens=no  README=missing  MISMATCH
FB2     opens=no  README=missing  MISMATCH
Office  opens=no  README=missing  MISMATCH
-- overclaiming phrases in docs --
README.md:112:| `Document` | Opened PDF/XPS/EPUB document |
src/context.zig:146:    /// Supported formats: PDF, XPS, EPUB, HTML, and various image formats.
src/document.zig:3://! Represents an opened document (PDF, XPS, EPUB, etc.).
src/root.zig:52://! - **Document Loading**: PDF, XPS, EPUB, HTML, and image formats
examples/pdf_info.zig:46:        std.debug.print("Format: Other (XPS, EPUB, etc.)\n", .{});
RESULT: FAIL
```
EPUB, HTML, TXT, FB2 and Office fail to open, yet README, `root.zig`, `context.zig`, `document.zig` and `pdf_info.zig` all claim EPUB (and sometimes HTML).

### Fix

* README: new **Supported formats** section with a per-format table (PDF, XPS, SVG, CBZ/ZIP/TAR, images ✅; EPUB, HTML, TXT, FB2/MOBI, Office ❌, each with its `FZ_ENABLE_*` flag). It also lists the font limits (Base14 only; Noto and CJK compiled out, so non-embedded CJK or other non-Latin fonts have no fallback), no HarfBuzz, and no OCR or JS.
* Doc comments in `root.zig`, `context.zig` and `document.zig`, plus the `pdf_info.zig` output, corrected.
* New test: `compiled-in format matrix matches README Supported formats table`. Supported formats must open with ≥1 page, and unsupported ones must fail with `error.OpenFailed`.
* **Optional build options (`-Dharfbuzz`, `-Dcjk-fonts`, `-Dhtml`): not done.** HarfBuzz is C++ and would need its own compile unit and flags. CJK/Noto fonts need several MB of generated font C sources (`generated/fonts` only has Base14), and HTML/EPUB need gumbo plus HarfBuzz together. I couldn't add these cleanly, and verified, in this PR without risking the default build.

### Found while re-verifying: Debug builds couldn't open SVG/XPS/CBZ at all

The new format test aborted the Debug test run. UBSan flagged `member access within misaligned address … for type 'fz_xml'` in MuPDF's XML pool allocator (`source/fitz/xml.c:479`), which every SVG and XPS open hits (CBZ recognition hits it too). With this, the shipped `example.pdf` crashing the Debug server (Issue 3), and the fuzz findings (Issue 1), it's clear upstream MuPDF is not UBSan-clean even on ordinary input. **`build.zig` now defaults `-Dsanitize-mupdf` to `false`.** UBSan is off for the vendored C code only. Zig code keeps all its safety checks, and `-Dsanitize-mupdf=true` turns UBSan back on for MuPDF debugging. This supersedes the default described under Issue 1.

### Re-verify

```
PDF     opens=yes README=yes      ok
XPS     opens=yes README=yes      ok
SVG     opens=yes README=yes      ok
CBZ     opens=yes README=yes      ok
Images  opens=yes README=yes      ok
EPUB    opens=no  README=no       ok
HTML    opens=no  README=no       ok
TXT     opens=no  README=no       ok
FB2     opens=no  README=no       ok
Office  opens=no  README=no       ok
-- overclaiming phrases in docs --
(none)
RESULT: PASS
```
Debug build (new default) fuzz: `scripts/repro/issue1_fuzz.sh 3000 5 tests/fixtures` gives `TOTAL: seeds=5 iterations_executed=15000 process_aborts=0`. A Debug server renders `example.pdf` pages 0–3 at scale 2 with `200 200 200 200` (page 1 used to panic).

`zig build test --summary all`: `109/109 tests passed`.

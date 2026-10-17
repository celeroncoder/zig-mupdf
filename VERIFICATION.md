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

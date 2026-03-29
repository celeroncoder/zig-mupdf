/**
 * MuPDF Shim Header for Zig
 *
 * This header works around Zig's inability to handle C bitfields.
 * Instead of including the full MuPDF headers directly, we:
 * 1. Forward-declare fz_font as an opaque type
 * 2. Include headers that don't depend on fz_font's internals
 * 3. Provide wrapper functions for font-related operations
 * 4. Provide safe wrapper functions that handle fz_try/fz_catch
 *
 * This allows Zig's @cImport to work without encountering the
 * fz_font_flags_t bitfield struct, and provides safe error handling.
 */

#ifndef MUPDF_SHIM_H
#define MUPDF_SHIM_H

/* Prevent the real font.h from being included */
#define MUPDF_FITZ_FONT_H

/* Forward declare fz_font as opaque - this MUST come before any MuPDF includes */
typedef struct fz_font fz_font;

/* Forward declare fz_font_flags_t - we'll provide accessor functions instead */
typedef struct fz_font_flags_t_opaque fz_font_flags_t;

/* Now include the main MuPDF headers */
#include "mupdf/fitz.h"
#include "mupdf/pdf.h"

/*
 * Font flag accessor functions
 * These provide access to fz_font_flags_t fields without exposing the bitfield struct
 */

/* Check if font is monospace */
int mupdf_shim_font_is_mono(fz_font *font);

/* Check if font is serif */
int mupdf_shim_font_is_serif(fz_font *font);

/* Check if font is bold */
int mupdf_shim_font_is_bold(fz_font *font);

/* Check if font is italic */
int mupdf_shim_font_is_italic(fz_font *font);

/* Get font name */
const char *mupdf_shim_font_name(fz_context *ctx, fz_font *font);

/*
 * Safe wrapper functions that handle fz_try/fz_catch
 * These return NULL on error instead of throwing via longjmp.
 */

/* Safely open a document - returns NULL on error */
fz_document *mupdf_shim_open_document(fz_context *ctx, const char *filename);

/* Safely open a document from stream - returns NULL on error */
fz_document *mupdf_shim_open_document_with_stream(fz_context *ctx, const char *magic, fz_stream *stream);

/* Safely load a page - returns NULL on error */
fz_page *mupdf_shim_load_page(fz_context *ctx, fz_document *doc, int page_num);

/* Safely render page to pixmap - returns NULL on error */
fz_pixmap *mupdf_shim_new_pixmap_from_page(fz_context *ctx, fz_page *page, fz_matrix ctm, fz_colorspace *cs, int alpha);

/* Safely save PDF document - returns 0 on success, -1 on error */
int mupdf_shim_save_document(fz_context *ctx, pdf_document *doc, const char *filename, const pdf_write_options *opts);

/* Get page rotation in degrees (0, 90, 180, 270). Returns 0 for non-PDF pages or on error. */
int mupdf_shim_page_rotation(fz_context *ctx, pdf_page *page);

/* Safely load links from a page - returns NULL if no links or on error */
fz_link *mupdf_shim_load_links(fz_context *ctx, fz_page *page);

/* Safely extract structured text from a page - returns NULL on error */
fz_stext_page *mupdf_shim_new_stext_page(fz_context *ctx, fz_page *page, const fz_stext_options *opts);

/* Safely extract plain text buffer from stext page - returns NULL on error */
fz_buffer *mupdf_shim_stext_to_buffer(fz_context *ctx, fz_stext_page *text);

/* Safely search a page for text - returns number of quads found, -1 on error */
int mupdf_shim_search_page(fz_context *ctx, fz_page *page, const char *needle, int *hit_mark, fz_quad *hit_bbox, int hit_max);

#endif /* MUPDF_SHIM_H */

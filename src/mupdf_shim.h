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

/* Safely open a document from a memory buffer - returns NULL on error */
fz_document *mupdf_shim_open_document_with_buffer(fz_context *ctx, const char *magic, const unsigned char *data, size_t len);

/* Safely register all compiled-in document handlers - returns 0 on success, -1 on error */
int mupdf_shim_register_document_handlers(fz_context *ctx);

/* Safely count pages - returns the page count, or -1 on error */
int mupdf_shim_count_pages(fz_context *ctx, fz_document *doc);

/* Safely check whether a password is needed - returns 0/1, or -1 on error */
int mupdf_shim_needs_password(fz_context *ctx, fz_document *doc);

/* Safely authenticate - returns fz_authenticate_password's result (0 = failed), or -1 on error */
int mupdf_shim_authenticate_password(fz_context *ctx, fz_document *doc, const char *password);

/* Value returned by mupdf_shim_lookup_metadata when MuPDF threw (distinct from -1 = key not found) */
#define MUPDF_SHIM_METADATA_ERROR (-2)

/* Safely look up metadata - returns size incl. NUL, -1 if not found, MUPDF_SHIM_METADATA_ERROR on error */
int mupdf_shim_lookup_metadata(fz_context *ctx, fz_document *doc, const char *key, char *buf, size_t size);

/* Safely set metadata - returns 0 on success, -1 on error */
int mupdf_shim_set_metadata(fz_context *ctx, fz_document *doc, const char *key, const char *value);

/* Drop a document. For PDFs, first removes the document's keys from the
 * (possibly shared) resource store while its xref is still intact: upstream
 * pdf_drop_document frees the xref before emptying the store, so a cloned
 * context in another thread could compare against a half-dropped key. */
void mupdf_shim_drop_document(fz_context *ctx, fz_document *doc);

/* Safely load a page - returns NULL on error */
fz_page *mupdf_shim_load_page(fz_context *ctx, fz_document *doc, int page_num);

/* Safely get the page bounds (crop box) - returns 0 on success, -1 on error */
int mupdf_shim_bound_page(fz_context *ctx, fz_page *page, fz_rect *out);

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

/* Image info for a single XObject image on a page */
typedef struct {
    int xref;
    int width;
    int height;
    int bpc;
    int n_components;
    const char *colorspace_name;
    const char *filter_name;
    const char *ref_name;
} mupdf_shim_image_info;

/* Enumerate images on a PDF page. Returns count, fills info array up to max_images. Returns -1 on error. */
int mupdf_shim_page_images(fz_context *ctx, pdf_document *doc, pdf_page *page,
                           mupdf_shim_image_info *infos, int max_images);

/* Safely load an image from a PDF object by xref. Returns NULL on error. */
fz_image *mupdf_shim_load_image(fz_context *ctx, pdf_document *doc, int xref);

/* Safely save pixmap as a PNG file - returns 0 on success, -1 on error */
int mupdf_shim_save_pixmap_as_png(fz_context *ctx, fz_pixmap *pixmap, const char *filename);

/* Safely encode pixmap as PNG in memory - returns NULL on error */
fz_buffer *mupdf_shim_pixmap_to_png(fz_context *ctx, fz_pixmap *pixmap);

/* Image accessor functions (fz_image has bitfields, can't access from Zig) */
int mupdf_shim_image_width(fz_image *img);
int mupdf_shim_image_height(fz_image *img);
int mupdf_shim_image_bpc(fz_image *img);
int mupdf_shim_image_n(fz_image *img);
int mupdf_shim_image_xres(fz_image *img);
int mupdf_shim_image_yres(fz_image *img);

/* Safely get pixmap from an image. Returns NULL on error. */
fz_pixmap *mupdf_shim_image_to_pixmap(fz_context *ctx, fz_image *image);

/* Create a new empty PDF document. Returns NULL on error. */
pdf_document *mupdf_shim_create_pdf(fz_context *ctx);

/* Delete a page from a PDF. Returns 0 on success, -1 on error. */
int mupdf_shim_delete_page(fz_context *ctx, pdf_document *doc, int page_num);

/* Delete a range of pages [start, end). Returns 0 on success, -1 on error. */
int mupdf_shim_delete_page_range(fz_context *ctx, pdf_document *doc, int start, int end);

/* Graft (copy) a page from src to dst. Returns 0 on success, -1 on error. */
int mupdf_shim_graft_page(fz_context *ctx, pdf_document *dst, int page_to, pdf_document *src, int page_from);

/* Rearrange pages in the given order. Returns 0 on success, -1 on error. */
int mupdf_shim_rearrange_pages(fz_context *ctx, pdf_document *doc, int count, const int *pages);

/* ============================================
 * Annotation functions
 * ============================================ */

/* Get first annotation on a PDF page. Returns NULL if none. */
pdf_annot *mupdf_shim_first_annot(fz_context *ctx, pdf_page *page);

/* Get next annotation. Returns NULL at end. */
pdf_annot *mupdf_shim_next_annot(fz_context *ctx, pdf_annot *annot);

/* Get annotation type (returns enum pdf_annot_type value, -1 on error). */
int mupdf_shim_annot_type(fz_context *ctx, pdf_annot *annot);

/* Get annotation bounding rect. */
fz_rect mupdf_shim_annot_rect(fz_context *ctx, pdf_annot *annot);

/* Get annotation contents text. Returns "" on error. */
const char *mupdf_shim_annot_contents(fz_context *ctx, pdf_annot *annot);

/* Get annotation author. Returns "" on error. */
const char *mupdf_shim_annot_author(fz_context *ctx, pdf_annot *annot);

/* Get annotation color (fills n and color[4]). */
void mupdf_shim_annot_color(fz_context *ctx, pdf_annot *annot, int *n, float color[4]);

/* Get annotation opacity (0-1). */
float mupdf_shim_annot_opacity(fz_context *ctx, pdf_annot *annot);

/* Get annotation modification date (epoch seconds). */
int64_t mupdf_shim_annot_modification_date(fz_context *ctx, pdf_annot *annot);

/* Create an annotation. Returns NULL on error. Caller must drop. */
pdf_annot *mupdf_shim_create_annot(fz_context *ctx, pdf_page *page, int type);

/* Delete an annotation. Returns 0 on success, -1 on error. */
int mupdf_shim_delete_annot(fz_context *ctx, pdf_page *page, pdf_annot *annot);

/* Set annotation rect. */
void mupdf_shim_set_annot_rect(fz_context *ctx, pdf_annot *annot, fz_rect rect);

/* Set annotation contents text. */
void mupdf_shim_set_annot_contents(fz_context *ctx, pdf_annot *annot, const char *text);

/* Set annotation author. */
void mupdf_shim_set_annot_author(fz_context *ctx, pdf_annot *annot, const char *author);

/* Set annotation color (RGB). */
void mupdf_shim_set_annot_color(fz_context *ctx, pdf_annot *annot, int n, const float *color);

/* Set annotation opacity. */
void mupdf_shim_set_annot_opacity(fz_context *ctx, pdf_annot *annot, float opacity);

/* Set quad points for highlight/underline/strikeout annotations. */
void mupdf_shim_set_annot_quad_points(fz_context *ctx, pdf_annot *annot, int n, const fz_quad *quads);

/* Update annotation appearance. Returns 0 on success. */
int mupdf_shim_update_annot(fz_context *ctx, pdf_annot *annot);

/* ============================================
 * Outline / TOC functions
 * ============================================ */

/* Load the document outline (TOC). Returns NULL if none. Caller must drop. */
fz_outline *mupdf_shim_load_outline(fz_context *ctx, fz_document *doc);

/* Outline accessor functions (fz_outline has bitfields) */
const char *mupdf_shim_outline_title(fz_outline *outline);
const char *mupdf_shim_outline_uri(fz_outline *outline);
int mupdf_shim_outline_page(fz_context *ctx, fz_document *doc, fz_outline *outline);
int mupdf_shim_outline_is_open(fz_outline *outline);
fz_outline *mupdf_shim_outline_next(fz_outline *outline);
fz_outline *mupdf_shim_outline_down(fz_outline *outline);

/* ============================================
 * Form widget functions
 * ============================================ */

/* Get first widget on a page. Returns NULL if none. */
pdf_annot *mupdf_shim_first_widget(fz_context *ctx, pdf_page *page);

/* Get next widget. Returns NULL at end. */
pdf_annot *mupdf_shim_next_widget(fz_context *ctx, pdf_annot *widget);

/* Get widget type (returns enum pdf_widget_type). */
int mupdf_shim_widget_type(fz_context *ctx, pdf_annot *widget);

/* Get widget/field label. Returns "" on error. */
const char *mupdf_shim_widget_label(fz_context *ctx, pdf_annot *widget);

/* Get widget/field value. Returns "" on error. */
const char *mupdf_shim_widget_value(fz_context *ctx, pdf_annot *widget);

/* Check if widget is read-only. */
int mupdf_shim_widget_is_readonly(fz_context *ctx, pdf_annot *widget);

/* Get widget bounding rect. */
fz_rect mupdf_shim_widget_rect(fz_context *ctx, pdf_annot *widget);

#endif /* MUPDF_SHIM_H */

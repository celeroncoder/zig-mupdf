/**
 * MuPDF Shim Implementation for Zig
 *
 * This file implements wrapper functions that provide access to
 * font properties without exposing the bitfield struct to Zig,
 * and safe wrappers that handle fz_try/fz_catch for error handling.
 */

/* Include the real MuPDF headers here - this C file can handle bitfields */
#include "mupdf/fitz.h"
#include "mupdf/pdf.h"

/* ============================================
 * Font flag accessor functions
 * ============================================ */

int mupdf_shim_font_is_mono(fz_font *font)
{
    if (font == NULL) return 0;
    fz_font_flags_t *flags = fz_font_flags(font);
    if (flags == NULL) return 0;
    return flags->is_mono;
}

int mupdf_shim_font_is_serif(fz_font *font)
{
    if (font == NULL) return 0;
    fz_font_flags_t *flags = fz_font_flags(font);
    if (flags == NULL) return 0;
    return flags->is_serif;
}

int mupdf_shim_font_is_bold(fz_font *font)
{
    if (font == NULL) return 0;
    fz_font_flags_t *flags = fz_font_flags(font);
    if (flags == NULL) return 0;
    return flags->is_bold;
}

int mupdf_shim_font_is_italic(fz_font *font)
{
    if (font == NULL) return 0;
    fz_font_flags_t *flags = fz_font_flags(font);
    if (flags == NULL) return 0;
    return flags->is_italic;
}

const char *mupdf_shim_font_name(fz_context *ctx, fz_font *font)
{
    if (font == NULL) return NULL;
    return fz_font_name(ctx, font);
}

/* ============================================
 * Safe wrapper functions with fz_try/fz_catch
 * These return NULL on error instead of throwing.
 * ============================================ */

fz_document *mupdf_shim_open_document(fz_context *ctx, const char *filename)
{
    fz_document *doc = NULL;
    fz_try(ctx)
    {
        doc = fz_open_document(ctx, filename);
    }
    fz_catch(ctx)
    {
        doc = NULL;
    }
    return doc;
}

fz_document *mupdf_shim_open_document_with_stream(fz_context *ctx, const char *magic, fz_stream *stream)
{
    fz_document *doc = NULL;
    fz_try(ctx)
    {
        doc = fz_open_document_with_stream(ctx, magic, stream);
    }
    fz_catch(ctx)
    {
        doc = NULL;
    }
    return doc;
}

fz_page *mupdf_shim_load_page(fz_context *ctx, fz_document *doc, int page_num)
{
    fz_page *page = NULL;
    fz_try(ctx)
    {
        page = fz_load_page(ctx, doc, page_num);
    }
    fz_catch(ctx)
    {
        page = NULL;
    }
    return page;
}

fz_pixmap *mupdf_shim_new_pixmap_from_page(fz_context *ctx, fz_page *page, fz_matrix ctm, fz_colorspace *cs, int alpha)
{
    fz_pixmap *pixmap = NULL;
    fz_try(ctx)
    {
        pixmap = fz_new_pixmap_from_page(ctx, page, ctm, cs, alpha);
    }
    fz_catch(ctx)
    {
        pixmap = NULL;
    }
    return pixmap;
}

int mupdf_shim_save_document(fz_context *ctx, pdf_document *doc, const char *filename, const pdf_write_options *opts)
{
    int result = 0;
    fz_try(ctx)
    {
        pdf_save_document(ctx, doc, filename, opts);
    }
    fz_catch(ctx)
    {
        result = -1;
    }
    return result;
}

int mupdf_shim_page_rotation(fz_context *ctx, pdf_page *page)
{
    int rotate = 0;
    fz_try(ctx)
    {
        rotate = pdf_to_int(ctx, pdf_dict_get_inheritable(ctx, page->obj, PDF_NAME(Rotate)));
        /* Normalize to 0, 90, 180, 270 */
        rotate = ((rotate % 360) + 360) % 360;
    }
    fz_catch(ctx)
    {
        rotate = 0;
    }
    return rotate;
}

fz_link *mupdf_shim_load_links(fz_context *ctx, fz_page *page)
{
    fz_link *links = NULL;
    fz_try(ctx)
    {
        links = fz_load_links(ctx, page);
    }
    fz_catch(ctx)
    {
        links = NULL;
    }
    return links;
}

fz_stext_page *mupdf_shim_new_stext_page(fz_context *ctx, fz_page *page, const fz_stext_options *opts)
{
    fz_stext_page *stext = NULL;
    fz_try(ctx)
    {
        stext = fz_new_stext_page_from_page(ctx, page, opts);
    }
    fz_catch(ctx)
    {
        stext = NULL;
    }
    return stext;
}

fz_buffer *mupdf_shim_stext_to_buffer(fz_context *ctx, fz_stext_page *text)
{
    fz_buffer *buf = NULL;
    fz_try(ctx)
    {
        buf = fz_new_buffer_from_stext_page(ctx, text);
    }
    fz_catch(ctx)
    {
        buf = NULL;
    }
    return buf;
}

int mupdf_shim_search_page(fz_context *ctx, fz_page *page, const char *needle, int *hit_mark, fz_quad *hit_bbox, int hit_max)
{
    int count = -1;
    fz_try(ctx)
    {
        count = fz_search_page(ctx, page, needle, hit_mark, hit_bbox, hit_max);
    }
    fz_catch(ctx)
    {
        count = -1;
    }
    return count;
}

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

/* Image info struct (must match mupdf_shim.h) */
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

fz_document *mupdf_shim_open_document_with_buffer(fz_context *ctx, const char *magic, const unsigned char *data, size_t len)
{
    fz_document *doc = NULL;
    fz_try(ctx)
    {
        fz_buffer *buf = fz_new_buffer_from_copied_data(ctx, data, len);
        doc = fz_open_document_with_buffer(ctx, magic, buf);
        fz_drop_buffer(ctx, buf); /* doc keeps its own reference */
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

int mupdf_shim_page_images(fz_context *ctx, pdf_document *doc, pdf_page *page,
                           mupdf_shim_image_info *infos, int max_images)
{
    int count = 0;
    fz_try(ctx)
    {
        pdf_obj *resources = pdf_page_resources(ctx, page);
        pdf_obj *xobj = pdf_dict_get(ctx, resources, PDF_NAME(XObject));
        if (!xobj) { fz_throw(ctx, 0, "no xobjects"); }

        int n = pdf_dict_len(ctx, xobj);
        for (int i = 0; i < n && count < max_images; i++)
        {
            pdf_obj *key = pdf_dict_get_key(ctx, xobj, i);
            pdf_obj *val_raw = pdf_dict_get_val(ctx, xobj, i);

            /* Get xref before resolving */
            int xref = pdf_to_num(ctx, val_raw);

            /* Resolve indirect references */
            pdf_obj *val = pdf_resolve_indirect(ctx, val_raw);
            if (!val) continue;

            pdf_obj *subtype = pdf_dict_get(ctx, val, PDF_NAME(Subtype));
            if (!pdf_name_eq(ctx, subtype, PDF_NAME(Image)))
                continue;

            mupdf_shim_image_info *info = &infos[count];
            info->xref = xref;
            info->width = pdf_to_int(ctx, pdf_dict_geta(ctx, val, PDF_NAME(Width), PDF_NAME(W)));
            info->height = pdf_to_int(ctx, pdf_dict_geta(ctx, val, PDF_NAME(Height), PDF_NAME(H)));
            info->bpc = pdf_to_int(ctx, pdf_dict_geta(ctx, val, PDF_NAME(BitsPerComponent), PDF_NAME(BPC)));

            /* Colorspace */
            pdf_obj *cs = pdf_dict_geta(ctx, val, PDF_NAME(ColorSpace), PDF_NAME(CS));
            if (cs)
                info->colorspace_name = pdf_to_name(ctx, cs);
            else
                info->colorspace_name = "";

            /* Filter */
            pdf_obj *filter = pdf_dict_geta(ctx, val, PDF_NAME(Filter), PDF_NAME(F));
            if (pdf_is_array(ctx, filter))
                filter = pdf_array_get(ctx, filter, 0);
            if (filter)
                info->filter_name = pdf_to_name(ctx, filter);
            else
                info->filter_name = "";

            /* Number of components (from colorspace if available) */
            info->n_components = 0;
            if (cs) {
                fz_try(ctx) {
                    fz_colorspace *fzcs = pdf_load_colorspace(ctx, val);
                    info->n_components = fz_colorspace_n(ctx, fzcs);
                    fz_drop_colorspace(ctx, fzcs);
                }
                fz_catch(ctx) {
                    info->n_components = 0;
                }
            }

            /* Reference name */
            info->ref_name = pdf_to_name(ctx, key);

            count++;
        }
    }
    fz_catch(ctx)
    {
        /* Return whatever we found so far, or 0 */
        if (count < 0) count = 0;
    }
    return count;
}

fz_image *mupdf_shim_load_image(fz_context *ctx, pdf_document *doc, int xref)
{
    fz_image *img = NULL;
    fz_try(ctx)
    {
        pdf_obj *obj = pdf_new_indirect(ctx, doc, xref, 0);
        img = pdf_load_image(ctx, doc, obj);
        pdf_drop_obj(ctx, obj);
    }
    fz_catch(ctx)
    {
        img = NULL;
    }
    return img;
}

fz_pixmap *mupdf_shim_image_to_pixmap(fz_context *ctx, fz_image *image)
{
    fz_pixmap *pix = NULL;
    fz_try(ctx)
    {
        pix = fz_get_pixmap_from_image(ctx, image, NULL, NULL, NULL, NULL);
    }
    fz_catch(ctx)
    {
        pix = NULL;
    }
    return pix;
}

fz_buffer *mupdf_shim_pixmap_to_png(fz_context *ctx, fz_pixmap *pixmap)
{
    fz_buffer *buf = NULL;
    fz_try(ctx)
    {
        fz_color_params cp = fz_default_color_params;
        buf = fz_new_buffer_from_pixmap_as_png(ctx, pixmap, cp);
    }
    fz_catch(ctx)
    {
        buf = NULL;
    }
    return buf;
}

int mupdf_shim_image_width(fz_image *img) { return img ? img->w : 0; }
int mupdf_shim_image_height(fz_image *img) { return img ? img->h : 0; }
int mupdf_shim_image_bpc(fz_image *img) { return img ? img->bpc : 0; }
int mupdf_shim_image_n(fz_image *img) { return img ? img->n : 0; }
int mupdf_shim_image_xres(fz_image *img) { return img ? img->xres : 0; }
int mupdf_shim_image_yres(fz_image *img) { return img ? img->yres : 0; }

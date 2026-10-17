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

/* Must match mupdf_shim.h */
#define MUPDF_SHIM_METADATA_ERROR (-2)

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

int mupdf_shim_register_document_handlers(fz_context *ctx)
{
    int result = 0;
    fz_try(ctx)
    {
        fz_register_document_handlers(ctx);
    }
    fz_catch(ctx)
    {
        result = -1;
    }
    return result;
}

int mupdf_shim_count_pages(fz_context *ctx, fz_document *doc)
{
    int count = -1;
    fz_try(ctx)
    {
        count = fz_count_pages(ctx, doc);
    }
    fz_catch(ctx)
    {
        count = -1;
    }
    return count;
}

int mupdf_shim_needs_password(fz_context *ctx, fz_document *doc)
{
    int result = -1;
    fz_try(ctx)
    {
        result = fz_needs_password(ctx, doc) ? 1 : 0;
    }
    fz_catch(ctx)
    {
        result = -1;
    }
    return result;
}

int mupdf_shim_authenticate_password(fz_context *ctx, fz_document *doc, const char *password)
{
    int result = -1;
    fz_try(ctx)
    {
        result = fz_authenticate_password(ctx, doc, password);
    }
    fz_catch(ctx)
    {
        result = -1;
    }
    return result;
}

int mupdf_shim_lookup_metadata(fz_context *ctx, fz_document *doc, const char *key, char *buf, size_t size)
{
    int result = -1;
    fz_try(ctx)
    {
        result = fz_lookup_metadata(ctx, doc, key, buf, size);
    }
    fz_catch(ctx)
    {
        result = MUPDF_SHIM_METADATA_ERROR;
    }
    return result;
}

int mupdf_shim_set_metadata(fz_context *ctx, fz_document *doc, const char *key, const char *value)
{
    int result = 0;
    fz_try(ctx)
    {
        fz_set_metadata(ctx, doc, key, value);
    }
    fz_catch(ctx)
    {
        result = -1;
    }
    return result;
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

int mupdf_shim_bound_page(fz_context *ctx, fz_page *page, fz_rect *out)
{
    int result = 0;
    fz_try(ctx)
    {
        *out = fz_bound_page(ctx, page);
    }
    fz_catch(ctx)
    {
        *out = fz_empty_rect;
        result = -1;
    }
    return result;
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

int mupdf_shim_save_pixmap_as_png(fz_context *ctx, fz_pixmap *pixmap, const char *filename)
{
    int result = 0;
    fz_try(ctx)
    {
        fz_save_pixmap_as_png(ctx, pixmap, filename);
    }
    fz_catch(ctx)
    {
        result = -1;
    }
    return result;
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

pdf_document *mupdf_shim_create_pdf(fz_context *ctx)
{
    pdf_document *doc = NULL;
    fz_try(ctx)
    {
        doc = pdf_create_document(ctx);
    }
    fz_catch(ctx)
    {
        doc = NULL;
    }
    return doc;
}

int mupdf_shim_delete_page(fz_context *ctx, pdf_document *doc, int page_num)
{
    int result = 0;
    fz_try(ctx)
    {
        pdf_delete_page(ctx, doc, page_num);
    }
    fz_catch(ctx)
    {
        result = -1;
    }
    return result;
}

int mupdf_shim_delete_page_range(fz_context *ctx, pdf_document *doc, int start, int end)
{
    int result = 0;
    fz_try(ctx)
    {
        pdf_delete_page_range(ctx, doc, start, end);
    }
    fz_catch(ctx)
    {
        result = -1;
    }
    return result;
}

int mupdf_shim_graft_page(fz_context *ctx, pdf_document *dst, int page_to, pdf_document *src, int page_from)
{
    int result = 0;
    fz_try(ctx)
    {
        pdf_graft_page(ctx, dst, page_to, src, page_from);
    }
    fz_catch(ctx)
    {
        result = -1;
    }
    return result;
}

int mupdf_shim_rearrange_pages(fz_context *ctx, pdf_document *doc, int count, const int *pages)
{
    int result = 0;
    fz_try(ctx)
    {
        pdf_rearrange_pages(ctx, doc, count, pages, 0); /* 0 = PDF_CLEAN_STRUCTURE_DROP */
    }
    fz_catch(ctx)
    {
        result = -1;
    }
    return result;
}

/* ============================================
 * Annotation functions
 * ============================================ */

pdf_annot *mupdf_shim_first_annot(fz_context *ctx, pdf_page *page)
{
    pdf_annot *annot = NULL;
    fz_try(ctx) { annot = pdf_first_annot(ctx, page); }
    fz_catch(ctx) { annot = NULL; }
    return annot;
}

pdf_annot *mupdf_shim_next_annot(fz_context *ctx, pdf_annot *annot)
{
    pdf_annot *next = NULL;
    fz_try(ctx) { next = pdf_next_annot(ctx, annot); }
    fz_catch(ctx) { next = NULL; }
    return next;
}

int mupdf_shim_annot_type(fz_context *ctx, pdf_annot *annot)
{
    int type = -1;
    fz_try(ctx) { type = (int)pdf_annot_type(ctx, annot); }
    fz_catch(ctx) { type = -1; }
    return type;
}

fz_rect mupdf_shim_annot_rect(fz_context *ctx, pdf_annot *annot)
{
    fz_rect r = fz_empty_rect;
    fz_try(ctx) { r = pdf_annot_rect(ctx, annot); }
    fz_catch(ctx) { r = fz_empty_rect; }
    return r;
}

const char *mupdf_shim_annot_contents(fz_context *ctx, pdf_annot *annot)
{
    const char *s = "";
    fz_try(ctx) { s = pdf_annot_contents(ctx, annot); if (!s) s = ""; }
    fz_catch(ctx) { s = ""; }
    return s;
}

const char *mupdf_shim_annot_author(fz_context *ctx, pdf_annot *annot)
{
    const char *s = "";
    fz_try(ctx) { s = pdf_annot_author(ctx, annot); if (!s) s = ""; }
    fz_catch(ctx) { s = ""; }
    return s;
}

void mupdf_shim_annot_color(fz_context *ctx, pdf_annot *annot, int *n, float color[4])
{
    fz_try(ctx) { pdf_annot_color(ctx, annot, n, color); }
    fz_catch(ctx) { *n = 0; }
}

float mupdf_shim_annot_opacity(fz_context *ctx, pdf_annot *annot)
{
    float o = 1.0f;
    fz_try(ctx) { o = pdf_annot_opacity(ctx, annot); }
    fz_catch(ctx) { o = 1.0f; }
    return o;
}

int64_t mupdf_shim_annot_modification_date(fz_context *ctx, pdf_annot *annot)
{
    int64_t d = 0;
    fz_try(ctx) { d = pdf_annot_modification_date(ctx, annot); }
    fz_catch(ctx) { d = 0; }
    return d;
}

pdf_annot *mupdf_shim_create_annot(fz_context *ctx, pdf_page *page, int type)
{
    pdf_annot *annot = NULL;
    fz_try(ctx) { annot = pdf_create_annot(ctx, page, (enum pdf_annot_type)type); }
    fz_catch(ctx) { annot = NULL; }
    return annot;
}

int mupdf_shim_delete_annot(fz_context *ctx, pdf_page *page, pdf_annot *annot)
{
    int result = 0;
    fz_try(ctx) { pdf_delete_annot(ctx, page, annot); }
    fz_catch(ctx) { result = -1; }
    return result;
}

void mupdf_shim_set_annot_rect(fz_context *ctx, pdf_annot *annot, fz_rect rect)
{
    fz_try(ctx) { pdf_set_annot_rect(ctx, annot, rect); }
    fz_catch(ctx) { }
}

void mupdf_shim_set_annot_contents(fz_context *ctx, pdf_annot *annot, const char *text)
{
    fz_try(ctx) { pdf_set_annot_contents(ctx, annot, text); }
    fz_catch(ctx) { }
}

void mupdf_shim_set_annot_author(fz_context *ctx, pdf_annot *annot, const char *author)
{
    fz_try(ctx) { pdf_set_annot_author(ctx, annot, author); }
    fz_catch(ctx) { }
}

void mupdf_shim_set_annot_color(fz_context *ctx, pdf_annot *annot, int n, const float *color)
{
    fz_try(ctx) { pdf_set_annot_color(ctx, annot, n, color); }
    fz_catch(ctx) { }
}

void mupdf_shim_set_annot_opacity(fz_context *ctx, pdf_annot *annot, float opacity)
{
    fz_try(ctx) { pdf_set_annot_opacity(ctx, annot, opacity); }
    fz_catch(ctx) { }
}

void mupdf_shim_set_annot_quad_points(fz_context *ctx, pdf_annot *annot, int n, const fz_quad *quads)
{
    fz_try(ctx) { pdf_set_annot_quad_points(ctx, annot, n, quads); }
    fz_catch(ctx) { }
}

int mupdf_shim_update_annot(fz_context *ctx, pdf_annot *annot)
{
    int result = 0;
    fz_try(ctx) { pdf_update_annot(ctx, annot); }
    fz_catch(ctx) { result = -1; }
    return result;
}

/* ============================================
 * Outline / TOC functions
 * ============================================ */

fz_outline *mupdf_shim_load_outline(fz_context *ctx, fz_document *doc)
{
    fz_outline *outline = NULL;
    fz_try(ctx) { outline = fz_load_outline(ctx, doc); }
    fz_catch(ctx) { outline = NULL; }
    return outline;
}

const char *mupdf_shim_outline_title(fz_outline *outline)
{
    return outline && outline->title ? outline->title : "";
}

const char *mupdf_shim_outline_uri(fz_outline *outline)
{
    return outline && outline->uri ? outline->uri : "";
}

int mupdf_shim_outline_page(fz_context *ctx, fz_document *doc, fz_outline *outline)
{
    if (!outline) return -1;
    int page = -1;
    fz_try(ctx) {
        page = fz_page_number_from_location(ctx, doc, outline->page);
    }
    fz_catch(ctx) { page = -1; }
    return page;
}

int mupdf_shim_outline_is_open(fz_outline *outline)
{
    return outline ? outline->is_open : 0;
}

fz_outline *mupdf_shim_outline_next(fz_outline *outline)
{
    return outline ? outline->next : NULL;
}

fz_outline *mupdf_shim_outline_down(fz_outline *outline)
{
    return outline ? outline->down : NULL;
}

/* ============================================
 * Form widget functions
 * ============================================ */

pdf_annot *mupdf_shim_first_widget(fz_context *ctx, pdf_page *page)
{
    pdf_annot *w = NULL;
    fz_try(ctx) { w = pdf_first_widget(ctx, page); }
    fz_catch(ctx) { w = NULL; }
    return w;
}

pdf_annot *mupdf_shim_next_widget(fz_context *ctx, pdf_annot *widget)
{
    pdf_annot *w = NULL;
    fz_try(ctx) { w = pdf_next_widget(ctx, widget); }
    fz_catch(ctx) { w = NULL; }
    return w;
}

int mupdf_shim_widget_type(fz_context *ctx, pdf_annot *widget)
{
    int t = 0;
    fz_try(ctx) { t = (int)pdf_widget_type(ctx, widget); }
    fz_catch(ctx) { t = 0; }
    return t;
}

const char *mupdf_shim_widget_label(fz_context *ctx, pdf_annot *widget)
{
    const char *s = "";
    fz_try(ctx) { s = pdf_annot_field_label(ctx, widget); if (!s) s = ""; }
    fz_catch(ctx) { s = ""; }
    return s;
}

const char *mupdf_shim_widget_value(fz_context *ctx, pdf_annot *widget)
{
    const char *s = "";
    fz_try(ctx) { s = pdf_annot_field_value(ctx, widget); if (!s) s = ""; }
    fz_catch(ctx) { s = ""; }
    return s;
}

int mupdf_shim_widget_is_readonly(fz_context *ctx, pdf_annot *widget)
{
    int ro = 0;
    fz_try(ctx) { ro = pdf_widget_is_readonly(ctx, widget); }
    fz_catch(ctx) { ro = 0; }
    return ro;
}

fz_rect mupdf_shim_widget_rect(fz_context *ctx, pdf_annot *widget)
{
    fz_rect r = fz_empty_rect;
    fz_try(ctx) { r = pdf_bound_widget(ctx, widget); }
    fz_catch(ctx) { r = fz_empty_rect; }
    return r;
}

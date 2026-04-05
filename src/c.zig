//! Low-level C bindings for MuPDF.
//! This module provides direct access to the MuPDF C API.
//!
//! We use a shim header (mupdf_shim.h) to work around Zig's inability
//! to handle C bitfields. The fz_font_flags_t struct contains bitfields
//! that would cause @cImport to fail, so we make fz_font opaque and
//! provide wrapper functions for font operations.

pub const c = @cImport({
    @cInclude("mupdf_shim.h");
});

// Re-export commonly used types for convenience
pub const fz_context = c.fz_context;
pub const fz_document = c.fz_document;
pub const fz_page = c.fz_page;
pub const fz_pixmap = c.fz_pixmap;
pub const fz_matrix = c.fz_matrix;
pub const fz_rect = c.fz_rect;
pub const fz_irect = c.fz_irect;
pub const fz_colorspace = c.fz_colorspace;
pub const fz_device = c.fz_device;
pub const fz_stext_page = c.fz_stext_page;
pub const fz_stext_options = c.fz_stext_options;
pub const fz_output = c.fz_output;
pub const fz_buffer = c.fz_buffer;
pub const fz_stream = c.fz_stream;
pub const fz_font = c.fz_font;

// PDF specific types
pub const pdf_document = c.pdf_document;
pub const pdf_page = c.pdf_page;
pub const pdf_obj = c.pdf_obj;
pub const pdf_annot = c.pdf_annot;

// Commonly used functions
pub const fz_new_context = c.fz_new_context;
pub const fz_drop_context = c.fz_drop_context;
pub const fz_register_document_handlers = c.fz_register_document_handlers;
pub const fz_open_document = c.fz_open_document;
pub const fz_drop_document = c.fz_drop_document;
pub const fz_count_pages = c.fz_count_pages;
pub const fz_load_page = c.fz_load_page;
pub const fz_drop_page = c.fz_drop_page;
pub const fz_bound_page = c.fz_bound_page;
pub const fz_new_pixmap_from_page = c.fz_new_pixmap_from_page;
pub const fz_drop_pixmap = c.fz_drop_pixmap;
pub const fz_new_stext_page_from_page = c.fz_new_stext_page_from_page;
pub const fz_drop_stext_page = c.fz_drop_stext_page;
pub const fz_lookup_metadata = c.fz_lookup_metadata;

// Matrix operations
pub const fz_identity = c.fz_identity;
pub const fz_scale = c.fz_scale;
pub const fz_rotate = c.fz_rotate;
pub const fz_translate = c.fz_translate;
pub const fz_concat = c.fz_concat;

// Colorspaces
pub const fz_device_rgb = c.fz_device_rgb;
pub const fz_device_gray = c.fz_device_gray;
pub const fz_device_cmyk = c.fz_device_cmyk;

// Pixmap operations
pub const fz_pixmap_width = c.fz_pixmap_width;
pub const fz_pixmap_height = c.fz_pixmap_height;
pub const fz_pixmap_samples = c.fz_pixmap_samples;
pub const fz_pixmap_stride = c.fz_pixmap_stride;
pub const fz_pixmap_n = c.fz_pixmap_n;
pub const fz_save_pixmap_as_png = c.fz_save_pixmap_as_png;

// Output operations
pub const fz_new_buffer = c.fz_new_buffer;
pub const fz_drop_buffer = c.fz_drop_buffer;
pub const fz_new_output_with_buffer = c.fz_new_output_with_buffer;
pub const fz_drop_output = c.fz_drop_output;

// Font shim functions (wrapper around bitfield accessors)
pub const mupdf_shim_font_is_mono = c.mupdf_shim_font_is_mono;
pub const mupdf_shim_font_is_serif = c.mupdf_shim_font_is_serif;
pub const mupdf_shim_font_is_bold = c.mupdf_shim_font_is_bold;
pub const mupdf_shim_font_is_italic = c.mupdf_shim_font_is_italic;
pub const mupdf_shim_font_name = c.mupdf_shim_font_name;

// Link types
pub const fz_link = c.fz_link;

// Structured text types
pub const fz_stext_block = c.fz_stext_block;
pub const fz_stext_line = c.fz_stext_line;
pub const fz_stext_char = c.fz_stext_char;
pub const fz_quad = c.fz_quad;

// Safe wrapper functions (handle fz_try/fz_catch, return null on error)
pub const mupdf_shim_open_document = c.mupdf_shim_open_document;
pub const mupdf_shim_open_document_with_stream = c.mupdf_shim_open_document_with_stream;
pub const mupdf_shim_load_page = c.mupdf_shim_load_page;
pub const mupdf_shim_new_pixmap_from_page = c.mupdf_shim_new_pixmap_from_page;
pub const mupdf_shim_page_rotation = c.mupdf_shim_page_rotation;
pub const mupdf_shim_load_links = c.mupdf_shim_load_links;
pub const mupdf_shim_new_stext_page = c.mupdf_shim_new_stext_page;
pub const mupdf_shim_stext_to_buffer = c.mupdf_shim_stext_to_buffer;
pub const mupdf_shim_search_page = c.mupdf_shim_search_page;
pub const mupdf_shim_image_info = c.mupdf_shim_image_info;
pub const mupdf_shim_page_images = c.mupdf_shim_page_images;
pub const mupdf_shim_load_image = c.mupdf_shim_load_image;
pub const mupdf_shim_image_to_pixmap = c.mupdf_shim_image_to_pixmap;
pub const mupdf_shim_create_pdf = c.mupdf_shim_create_pdf;
pub const mupdf_shim_delete_page = c.mupdf_shim_delete_page;
pub const mupdf_shim_delete_page_range = c.mupdf_shim_delete_page_range;
pub const mupdf_shim_graft_page = c.mupdf_shim_graft_page;
pub const mupdf_shim_rearrange_pages = c.mupdf_shim_rearrange_pages;

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Zig enables UBSan for C code in Debug/ReleaseSafe builds. Upstream MuPDF
    // is not UBSan-clean: its XML pool allocator does misaligned accesses (any
    // SVG/XPS/CBZ open panics) and the rasterizer/lexer have signed overflows on
    // ordinary input. So UBSan is off for the vendored C code by default; Zig
    // code keeps its safety checks. `-Dsanitize-mupdf=true` turns it back on.
    const sanitize_mupdf = b.option(bool, "sanitize-mupdf", "Compile vendored MuPDF C code with UBSan (default: false)") orelse false;

    // Path to vendored MuPDF
    const mupdf_path: std.Build.LazyPath = b.path(".context/mupdf");

    // ============================================
    // Create a module for the MuPDF C library
    // ============================================
    const mupdf_c_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = if (sanitize_mupdf) .full else .off,
    });

    // ============================================
    // Common include paths for MuPDF
    // ============================================
    mupdf_c_module.addIncludePath(b.path(".context/mupdf/include"));
    mupdf_c_module.addIncludePath(b.path(".context/mupdf/scripts/freetype"));
    mupdf_c_module.addIncludePath(b.path(".context/mupdf/scripts/libjpeg"));

    // Thirdparty include paths
    mupdf_c_module.addIncludePath(b.path(".context/mupdf/thirdparty/zlib"));
    mupdf_c_module.addIncludePath(b.path(".context/mupdf/thirdparty/freetype/include"));
    mupdf_c_module.addIncludePath(b.path(".context/mupdf/thirdparty/libjpeg"));
    mupdf_c_module.addIncludePath(b.path(".context/mupdf/thirdparty/harfbuzz/src"));
    mupdf_c_module.addIncludePath(b.path(".context/mupdf/thirdparty/openjpeg/src/lib/openjp2"));
    mupdf_c_module.addIncludePath(b.path(".context/mupdf/thirdparty/jbig2dec"));
    mupdf_c_module.addIncludePath(b.path(".context/mupdf/thirdparty/lcms2/include"));
    mupdf_c_module.addIncludePath(b.path(".context/mupdf/thirdparty/gumbo-parser/src"));
    mupdf_c_module.addIncludePath(b.path(".context/mupdf/thirdparty/brotli/c/include"));
    mupdf_c_module.addIncludePath(b.path(".context/mupdf/thirdparty/mujs"));
    mupdf_c_module.addIncludePath(b.path(".context/mupdf/thirdparty/extract/include"));
    mupdf_c_module.addIncludePath(b.path(".context/mupdf/thirdparty/extract/src"));

    // ============================================
    // ZLIB sources
    // ============================================
    mupdf_c_module.addCSourceFiles(.{
        .root = mupdf_path,
        .files = &.{
            "thirdparty/zlib/adler32.c",
            "thirdparty/zlib/compress.c",
            "thirdparty/zlib/crc32.c",
            "thirdparty/zlib/deflate.c",
            "thirdparty/zlib/inffast.c",
            "thirdparty/zlib/inflate.c",
            "thirdparty/zlib/inftrees.c",
            "thirdparty/zlib/trees.c",
            "thirdparty/zlib/uncompr.c",
            "thirdparty/zlib/zutil.c",
        },
        .flags = &.{
            "-fno-strict-aliasing",
            "-fPIC",
            "-DNDEBUG",
            "-w",
            "-DHAVE_UNISTD_H",
            "-DHAVE_STDARG_H",
        },
    });

    // ============================================
    // FREETYPE sources
    // ============================================
    mupdf_c_module.addCSourceFiles(.{
        .root = mupdf_path,
        .files = &.{
            "thirdparty/freetype/src/base/ftbase.c",
            "thirdparty/freetype/src/base/ftbbox.c",
            "thirdparty/freetype/src/base/ftbitmap.c",
            "thirdparty/freetype/src/base/ftdebug.c",
            "thirdparty/freetype/src/base/ftfstype.c",
            "thirdparty/freetype/src/base/ftgasp.c",
            "thirdparty/freetype/src/base/ftglyph.c",
            "thirdparty/freetype/src/base/ftinit.c",
            "thirdparty/freetype/src/base/ftstroke.c",
            "thirdparty/freetype/src/base/ftsynth.c",
            "thirdparty/freetype/src/base/ftsystem.c",
            "thirdparty/freetype/src/base/fttype1.c",
            "thirdparty/freetype/src/cff/cff.c",
            "thirdparty/freetype/src/cid/type1cid.c",
            "thirdparty/freetype/src/psaux/psaux.c",
            "thirdparty/freetype/src/pshinter/pshinter.c",
            "thirdparty/freetype/src/psnames/psnames.c",
            "thirdparty/freetype/src/raster/raster.c",
            "thirdparty/freetype/src/sfnt/sfnt.c",
            "thirdparty/freetype/src/smooth/smooth.c",
            "thirdparty/freetype/src/truetype/truetype.c",
            "thirdparty/freetype/src/type1/type1.c",
        },
        .flags = &.{
            "-fno-strict-aliasing",
            "-fPIC",
            "-DNDEBUG",
            "-w",
            "-DFT_CONFIG_MODULES_H=\"slimftmodules.h\"",
            "-DFT_CONFIG_OPTIONS_H=\"slimftoptions.h\"",
            "-DFT2_BUILD_LIBRARY",
        },
    });

    // ============================================
    // LIBJPEG sources
    // ============================================
    mupdf_c_module.addCSourceFiles(.{
        .root = mupdf_path,
        .files = &.{
            "thirdparty/libjpeg/jaricom.c",
            "thirdparty/libjpeg/jcapimin.c",
            "thirdparty/libjpeg/jcapistd.c",
            "thirdparty/libjpeg/jcarith.c",
            "thirdparty/libjpeg/jccoefct.c",
            "thirdparty/libjpeg/jccolor.c",
            "thirdparty/libjpeg/jcdctmgr.c",
            "thirdparty/libjpeg/jchuff.c",
            "thirdparty/libjpeg/jcinit.c",
            "thirdparty/libjpeg/jcmainct.c",
            "thirdparty/libjpeg/jcmarker.c",
            "thirdparty/libjpeg/jcmaster.c",
            "thirdparty/libjpeg/jcomapi.c",
            "thirdparty/libjpeg/jcparam.c",
            "thirdparty/libjpeg/jcprepct.c",
            "thirdparty/libjpeg/jcsample.c",
            "thirdparty/libjpeg/jdapimin.c",
            "thirdparty/libjpeg/jdapistd.c",
            "thirdparty/libjpeg/jdarith.c",
            "thirdparty/libjpeg/jdatadst.c",
            "thirdparty/libjpeg/jdatasrc.c",
            "thirdparty/libjpeg/jdcoefct.c",
            "thirdparty/libjpeg/jdcolor.c",
            "thirdparty/libjpeg/jddctmgr.c",
            "thirdparty/libjpeg/jdhuff.c",
            "thirdparty/libjpeg/jdinput.c",
            "thirdparty/libjpeg/jdmainct.c",
            "thirdparty/libjpeg/jdmarker.c",
            "thirdparty/libjpeg/jdmaster.c",
            "thirdparty/libjpeg/jdmerge.c",
            "thirdparty/libjpeg/jdpostct.c",
            "thirdparty/libjpeg/jdsample.c",
            "thirdparty/libjpeg/jdtrans.c",
            "thirdparty/libjpeg/jerror.c",
            "thirdparty/libjpeg/jfdctflt.c",
            "thirdparty/libjpeg/jfdctfst.c",
            "thirdparty/libjpeg/jfdctint.c",
            "thirdparty/libjpeg/jidctflt.c",
            "thirdparty/libjpeg/jidctfst.c",
            "thirdparty/libjpeg/jidctint.c",
            "thirdparty/libjpeg/jmemmgr.c",
            "thirdparty/libjpeg/jquant1.c",
            "thirdparty/libjpeg/jquant2.c",
            "thirdparty/libjpeg/jutils.c",
        },
        .flags = &.{
            "-fno-strict-aliasing",
            "-fPIC",
            "-DNDEBUG",
            "-w",
        },
    });

    // ============================================
    // OPENJPEG sources
    // ============================================
    mupdf_c_module.addCSourceFiles(.{
        .root = mupdf_path,
        .files = &.{
            "thirdparty/openjpeg/src/lib/openjp2/bio.c",
            "thirdparty/openjpeg/src/lib/openjp2/cio.c",
            "thirdparty/openjpeg/src/lib/openjp2/dwt.c",
            "thirdparty/openjpeg/src/lib/openjp2/event.c",
            "thirdparty/openjpeg/src/lib/openjp2/function_list.c",
            "thirdparty/openjpeg/src/lib/openjp2/ht_dec.c",
            "thirdparty/openjpeg/src/lib/openjp2/image.c",
            "thirdparty/openjpeg/src/lib/openjp2/invert.c",
            "thirdparty/openjpeg/src/lib/openjp2/j2k.c",
            "thirdparty/openjpeg/src/lib/openjp2/jp2.c",
            "thirdparty/openjpeg/src/lib/openjp2/mct.c",
            "thirdparty/openjpeg/src/lib/openjp2/mqc.c",
            "thirdparty/openjpeg/src/lib/openjp2/openjpeg.c",
            "thirdparty/openjpeg/src/lib/openjp2/pi.c",
            "thirdparty/openjpeg/src/lib/openjp2/sparse_array.c",
            "thirdparty/openjpeg/src/lib/openjp2/t1.c",
            "thirdparty/openjpeg/src/lib/openjp2/t2.c",
            "thirdparty/openjpeg/src/lib/openjp2/tcd.c",
            "thirdparty/openjpeg/src/lib/openjp2/tgt.c",
            "thirdparty/openjpeg/src/lib/openjp2/thread.c",
        },
        .flags = &.{
            "-fno-strict-aliasing",
            "-fPIC",
            "-DNDEBUG",
            "-w",
            "-DOPJ_STATIC",
            "-DOPJ_HAVE_INTTYPES_H",
            "-DOPJ_HAVE_STDINT_H",
            "-DMUTEX_pthread=0",
        },
    });

    // ============================================
    // JBIG2DEC sources
    // ============================================
    mupdf_c_module.addCSourceFiles(.{
        .root = mupdf_path,
        .files = &.{
            "thirdparty/jbig2dec/jbig2.c",
            "thirdparty/jbig2dec/jbig2_arith.c",
            "thirdparty/jbig2dec/jbig2_arith_iaid.c",
            "thirdparty/jbig2dec/jbig2_arith_int.c",
            "thirdparty/jbig2dec/jbig2_generic.c",
            "thirdparty/jbig2dec/jbig2_halftone.c",
            "thirdparty/jbig2dec/jbig2_huffman.c",
            "thirdparty/jbig2dec/jbig2_hufftab.c",
            "thirdparty/jbig2dec/jbig2_image.c",
            "thirdparty/jbig2dec/jbig2_mmr.c",
            "thirdparty/jbig2dec/jbig2_page.c",
            "thirdparty/jbig2dec/jbig2_refinement.c",
            "thirdparty/jbig2dec/jbig2_segment.c",
            "thirdparty/jbig2dec/jbig2_symbol_dict.c",
            "thirdparty/jbig2dec/jbig2_text.c",
        },
        .flags = &.{
            "-fno-strict-aliasing",
            "-fPIC",
            "-DNDEBUG",
            "-w",
            "-DHAVE_STDINT_H",
            "-DJBIG_EXTERNAL_MEMENTO_H=\"mupdf/memento.h\"",
        },
    });

    // ============================================
    // LCMS2 sources
    // ============================================
    mupdf_c_module.addCSourceFiles(.{
        .root = mupdf_path,
        .files = &.{
            "thirdparty/lcms2/src/cmsalpha.c",
            "thirdparty/lcms2/src/cmscam02.c",
            "thirdparty/lcms2/src/cmscgats.c",
            "thirdparty/lcms2/src/cmscnvrt.c",
            "thirdparty/lcms2/src/cmserr.c",
            "thirdparty/lcms2/src/cmsgamma.c",
            "thirdparty/lcms2/src/cmsgmt.c",
            "thirdparty/lcms2/src/cmshalf.c",
            "thirdparty/lcms2/src/cmsintrp.c",
            "thirdparty/lcms2/src/cmsio0.c",
            "thirdparty/lcms2/src/cmsio1.c",
            "thirdparty/lcms2/src/cmslut.c",
            "thirdparty/lcms2/src/cmsmd5.c",
            "thirdparty/lcms2/src/cmsmtrx.c",
            "thirdparty/lcms2/src/cmsnamed.c",
            "thirdparty/lcms2/src/cmsopt.c",
            "thirdparty/lcms2/src/cmspack.c",
            "thirdparty/lcms2/src/cmspcs.c",
            "thirdparty/lcms2/src/cmsplugin.c",
            "thirdparty/lcms2/src/cmsps2.c",
            "thirdparty/lcms2/src/cmssamp.c",
            "thirdparty/lcms2/src/cmssm.c",
            "thirdparty/lcms2/src/cmstypes.c",
            "thirdparty/lcms2/src/cmsvirt.c",
            "thirdparty/lcms2/src/cmswtpnt.c",
            "thirdparty/lcms2/src/cmsxform.c",
        },
        .flags = &.{
            "-fno-strict-aliasing",
            "-fPIC",
            "-DNDEBUG",
            "-w",
            "-DHAVE_LCMS2MT",
            "-DLCMS2MT_PREFIX=lcms2mt_",
        },
    });

    // ============================================
    // GUMBO sources
    // ============================================
    mupdf_c_module.addCSourceFiles(.{
        .root = mupdf_path,
        .files = &.{
            "thirdparty/gumbo-parser/src/attribute.c",
            "thirdparty/gumbo-parser/src/char_ref.c",
            "thirdparty/gumbo-parser/src/error.c",
            "thirdparty/gumbo-parser/src/parser.c",
            "thirdparty/gumbo-parser/src/string_buffer.c",
            "thirdparty/gumbo-parser/src/string_piece.c",
            "thirdparty/gumbo-parser/src/tag.c",
            "thirdparty/gumbo-parser/src/tokenizer.c",
            "thirdparty/gumbo-parser/src/utf8.c",
            "thirdparty/gumbo-parser/src/util.c",
            "thirdparty/gumbo-parser/src/vector.c",
        },
        .flags = &.{
            "-fno-strict-aliasing",
            "-fPIC",
            "-DNDEBUG",
            "-w",
            "-std=c99",
        },
    });

    // ============================================
    // BROTLI sources
    // ============================================
    mupdf_c_module.addCSourceFiles(.{
        .root = mupdf_path,
        .files = &.{
            "thirdparty/brotli/c/common/constants.c",
            "thirdparty/brotli/c/common/context.c",
            "thirdparty/brotli/c/common/dictionary.c",
            "thirdparty/brotli/c/common/platform.c",
            "thirdparty/brotli/c/common/shared_dictionary.c",
            "thirdparty/brotli/c/common/transform.c",
            "thirdparty/brotli/c/dec/bit_reader.c",
            "thirdparty/brotli/c/dec/decode.c",
            "thirdparty/brotli/c/dec/huffman.c",
            "thirdparty/brotli/c/dec/state.c",
            "thirdparty/brotli/c/enc/backward_references.c",
            "thirdparty/brotli/c/enc/backward_references_hq.c",
            "thirdparty/brotli/c/enc/bit_cost.c",
            "thirdparty/brotli/c/enc/block_splitter.c",
            "thirdparty/brotli/c/enc/brotli_bit_stream.c",
            "thirdparty/brotli/c/enc/cluster.c",
            "thirdparty/brotli/c/enc/command.c",
            "thirdparty/brotli/c/enc/compound_dictionary.c",
            "thirdparty/brotli/c/enc/compress_fragment.c",
            "thirdparty/brotli/c/enc/compress_fragment_two_pass.c",
            "thirdparty/brotli/c/enc/dictionary_hash.c",
            "thirdparty/brotli/c/enc/encode.c",
            "thirdparty/brotli/c/enc/encoder_dict.c",
            "thirdparty/brotli/c/enc/entropy_encode.c",
            "thirdparty/brotli/c/enc/fast_log.c",
            "thirdparty/brotli/c/enc/histogram.c",
            "thirdparty/brotli/c/enc/literal_cost.c",
            "thirdparty/brotli/c/enc/memory.c",
            "thirdparty/brotli/c/enc/metablock.c",
            "thirdparty/brotli/c/enc/static_dict.c",
            "thirdparty/brotli/c/enc/utf8_util.c",
        },
        .flags = &.{
            "-fno-strict-aliasing",
            "-fPIC",
            "-DNDEBUG",
            "-w",
        },
    });

    // ============================================
    // MUJS sources
    // ============================================
    mupdf_c_module.addCSourceFiles(.{
        .root = mupdf_path,
        .files = &.{
            "thirdparty/mujs/one.c",
        },
        .flags = &.{
            "-fno-strict-aliasing",
            "-fPIC",
            "-DNDEBUG",
            "-w",
        },
    });

    // ============================================
    // EXTRACT sources
    // ============================================
    mupdf_c_module.addCSourceFiles(.{
        .root = mupdf_path,
        .files = &.{
            "thirdparty/extract/src/alloc.c",
            "thirdparty/extract/src/astring.c",
            "thirdparty/extract/src/boxer.c",
            "thirdparty/extract/src/buffer.c",
            "thirdparty/extract/src/document.c",
            "thirdparty/extract/src/docx.c",
            "thirdparty/extract/src/docx_template.c",
            "thirdparty/extract/src/extract.c",
            "thirdparty/extract/src/join.c",
            "thirdparty/extract/src/json.c",
            "thirdparty/extract/src/mem.c",
            "thirdparty/extract/src/html.c",
            "thirdparty/extract/src/odt.c",
            "thirdparty/extract/src/odt_template.c",
            "thirdparty/extract/src/outf.c",
            "thirdparty/extract/src/rect.c",
            "thirdparty/extract/src/sys.c",
            "thirdparty/extract/src/text.c",
            "thirdparty/extract/src/xml.c",
            "thirdparty/extract/src/zip.c",
        },
        .flags = &.{
            "-fno-strict-aliasing",
            "-fPIC",
            "-DNDEBUG",
            "-w",
        },
    });

    // ============================================
    // MuPDF Core C flags
    // Note: TOFU flags disable embedded fonts to avoid needing generated font symbols.
    // FZ_ENABLE_* flags disable optional format support that requires HarfBuzz or other deps.
    // This is a temporary measure - we can enable these features later with proper deps.
    // ============================================
    const mupdf_cflags: []const []const u8 = &.{
        "-fno-strict-aliasing",
        "-fPIC",
        "-DNDEBUG",
        "-w",
        "-DMEMENTO_MUPDF_HACKS",
        "-DHAVE_LCMS2MT",
        "-DLCMS2MT_PREFIX=lcms2mt_",
        // Disable embedded fonts except Base14.
        // TOFU: skip non-CJK noto fonts. TOFU_CJK: skip CJK fonts.
        // Base14 fonts (Helvetica, Courier, Times, etc.) are included via
        // generated C files from URW CFF fonts in generated/fonts/.
        "-DTOFU",
        "-DTOFU_CJK",
        // Disable features that require HarfBuzz text shaping
        "-DFZ_ENABLE_HTML=0",
        "-DFZ_ENABLE_EPUB=0",
        "-DFZ_ENABLE_MOBI=0",
        "-DFZ_ENABLE_FB2=0",
        "-DFZ_ENABLE_TXT=0",
        "-DFZ_ENABLE_OFFICE=0",
        // Disable OCR (requires Tesseract/Leptonica)
        "-DFZ_ENABLE_OCR=0",
        // Disable JavaScript (we can enable MuJS later if needed)
        "-DFZ_ENABLE_JS=0",
    };

    // ============================================
    // MuPDF Core - FITZ sources
    // Note: Some files excluded that require optional dependencies:
    // - harfbuzz.c (requires HarfBuzz C++ library - will add later)
    // - leptonica-wrap.c (requires Leptonica for OCR)
    // - ocr-device.c (requires Tesseract for OCR)
    // ============================================
    mupdf_c_module.addCSourceFiles(.{
        .root = mupdf_path,
        .files = &.{
            "source/fitz/archive.c",
            "source/fitz/barcode.c",
            "source/fitz/bbox-device.c",
            "source/fitz/bidi.c",
            "source/fitz/bidi-std.c",
            "source/fitz/bitmap.c",
            "source/fitz/brotli.c",
            "source/fitz/buffer.c",
            "source/fitz/color-fast.c",
            "source/fitz/color-icc-create.c",
            "source/fitz/color-lcms.c",
            "source/fitz/colorspace.c",
            "source/fitz/compress.c",
            "source/fitz/compressed-buffer.c",
            "source/fitz/context.c",
            "source/fitz/crypt-aes.c",
            "source/fitz/crypt-arc4.c",
            "source/fitz/crypt-md5.c",
            "source/fitz/crypt-sha2.c",
            "source/fitz/deskew.c",
            "source/fitz/device.c",
            "source/fitz/directory.c",
            "source/fitz/document.c",
            "source/fitz/document-all.c",
            "source/fitz/draw-affine.c",
            "source/fitz/draw-blend.c",
            "source/fitz/draw-device.c",
            "source/fitz/draw-edge.c",
            "source/fitz/draw-edgebuffer.c",
            "source/fitz/draw-glyph.c",
            "source/fitz/draw-mesh.c",
            "source/fitz/draw-paint.c",
            "source/fitz/draw-path.c",
            "source/fitz/draw-rasterize.c",
            "source/fitz/draw-scale-simple.c",
            "source/fitz/draw-unpack.c",
            "source/fitz/encode-basic.c",
            "source/fitz/encode-fax.c",
            "source/fitz/encode-jpx.c",
            "source/fitz/encodings.c",
            "source/fitz/error.c",
            "source/fitz/filter-basic.c",
            "source/fitz/filter-brotli.c",
            "source/fitz/filter-dct.c",
            "source/fitz/filter-fax.c",
            "source/fitz/filter-flate.c",
            "source/fitz/filter-jbig2.c",
            "source/fitz/filter-leech.c",
            "source/fitz/filter-lzw.c",
            "source/fitz/filter-predict.c",
            "source/fitz/filter-sgi.c",
            "source/fitz/filter-thunder.c",
            "source/fitz/font.c",
            "source/fitz/ftoa.c",
            "source/fitz/geometry.c",
            "source/fitz/getopt.c",
            "source/fitz/glyph.c",
            "source/fitz/glyphbox.c",
            "source/fitz/gz-doc.c",
            "source/fitz/halftone.c",
            "source/fitz/hash.c",
            "source/fitz/heap.c",
            "source/fitz/hyphen.c",
            "source/fitz/image.c",
            "source/fitz/jmemcust.c",
            "source/fitz/json.c",
            "source/fitz/link.c",
            "source/fitz/list-device.c",
            "source/fitz/load-bmp.c",
            "source/fitz/load-gif.c",
            "source/fitz/load-jbig2.c",
            "source/fitz/load-jpeg.c",
            "source/fitz/load-jpx.c",
            "source/fitz/load-jxr.c",
            "source/fitz/load-png.c",
            "source/fitz/load-pnm.c",
            "source/fitz/load-psd.c",
            "source/fitz/load-tiff.c",
            "source/fitz/log.c",
            "source/fitz/memento.c",
            "source/fitz/memory.c",
            "source/fitz/noto.c",
            "source/fitz/options.c",
            "source/fitz/outline.c",
            "source/fitz/output.c",
            "source/fitz/output-cbz.c",
            "source/fitz/output-csv.c",
            "source/fitz/output-docx.c",
            "source/fitz/output-jpeg.c",
            "source/fitz/output-pcl.c",
            "source/fitz/output-pclm.c",
            "source/fitz/output-pdfocr.c",
            "source/fitz/output-png.c",
            "source/fitz/output-pnm.c",
            "source/fitz/output-ps.c",
            "source/fitz/output-psd.c",
            "source/fitz/output-pwg.c",
            "source/fitz/output-svg.c",
            "source/fitz/path.c",
            "source/fitz/pixmap.c",
            "source/fitz/pool.c",
            "source/fitz/printf.c",
            "source/fitz/random.c",
            "source/fitz/regexp.c",
            "source/fitz/separation.c",
            "source/fitz/shade.c",
            "source/fitz/skew.c",
            "source/fitz/stext-boxer.c",
            "source/fitz/stext-classify.c",
            "source/fitz/stext-device.c",
            "source/fitz/stext-iterator.c",
            "source/fitz/stext-output.c",
            "source/fitz/stext-para.c",
            "source/fitz/stext-raft.c",
            "source/fitz/stext-search.c",
            "source/fitz/stext-table.c",
            "source/fitz/store.c",
            "source/fitz/stream-open.c",
            "source/fitz/stream-read.c",
            "source/fitz/string.c",
            "source/fitz/strtof.c",
            "source/fitz/subset-cff.c",
            "source/fitz/subset-ttf.c",
            "source/fitz/svg-device.c",
            "source/fitz/test-device.c",
            "source/fitz/text.c",
            "source/fitz/text-decoder.c",
            "source/fitz/time.c",
            "source/fitz/trace-device.c",
            "source/fitz/track-usage.c",
            "source/fitz/transition.c",
            "source/fitz/tree.c",
            "source/fitz/ucdn.c",
            "source/fitz/uncfb.c",
            "source/fitz/unlibarchive.c",
            "source/fitz/untar.c",
            "source/fitz/unzip.c",
            "source/fitz/util.c",
            "source/fitz/warp.c",
            "source/fitz/writer.c",
            "source/fitz/xml.c",
            "source/fitz/xml-write.c",
            "source/fitz/xmltext-device.c",
            "source/fitz/zip.c",
        },
        .flags = mupdf_cflags,
    });

    // ============================================
    // Base14 font data (generated from URW CFF fonts)
    // These provide Helvetica, Courier, Times, Symbol, etc.
    // ============================================
    mupdf_c_module.addCSourceFiles(.{
        .files = &.{
            "generated/fonts/Dingbats_cff.c",
            "generated/fonts/NimbusMonoPS_Bold_cff.c",
            "generated/fonts/NimbusMonoPS_BoldItalic_cff.c",
            "generated/fonts/NimbusMonoPS_Italic_cff.c",
            "generated/fonts/NimbusMonoPS_Regular_cff.c",
            "generated/fonts/NimbusRoman_Bold_cff.c",
            "generated/fonts/NimbusRoman_BoldItalic_cff.c",
            "generated/fonts/NimbusRoman_Italic_cff.c",
            "generated/fonts/NimbusRoman_Regular_cff.c",
            "generated/fonts/NimbusSans_Bold_cff.c",
            "generated/fonts/NimbusSans_BoldItalic_cff.c",
            "generated/fonts/NimbusSans_Italic_cff.c",
            "generated/fonts/NimbusSans_Regular_cff.c",
            "generated/fonts/StandardSymbolsPS_cff.c",
        },
        .flags = &.{ "-w" },
    });

    // ============================================
    // MuPDF PDF sources
    // ============================================
    mupdf_c_module.addCSourceFiles(.{
        .root = mupdf_path,
        .files = &.{
            "source/pdf/pdf-af.c",
            "source/pdf/pdf-annot.c",
            "source/pdf/pdf-appearance.c",
            "source/pdf/pdf-clean.c",
            "source/pdf/pdf-clean-file.c",
            "source/pdf/pdf-cmap.c",
            "source/pdf/pdf-cmap-load.c",
            "source/pdf/pdf-cmap-parse.c",
            "source/pdf/pdf-colorspace.c",
            "source/pdf/pdf-crypt.c",
            "source/pdf/pdf-device.c",
            "source/pdf/pdf-event.c",
            "source/pdf/pdf-font.c",
            "source/pdf/pdf-font-add.c",
            "source/pdf/pdf-form.c",
            "source/pdf/pdf-function.c",
            "source/pdf/pdf-graft.c",
            "source/pdf/pdf-image.c",
            "source/pdf/pdf-image-rewriter.c",
            "source/pdf/pdf-interpret.c",
            "source/pdf/pdf-js.c",
            "source/pdf/pdf-label.c",
            "source/pdf/pdf-layer.c",
            "source/pdf/pdf-layout.c",
            "source/pdf/pdf-lex.c",
            "source/pdf/pdf-link.c",
            "source/pdf/pdf-metrics.c",
            "source/pdf/pdf-nametree.c",
            "source/pdf/pdf-object.c",
            "source/pdf/pdf-op-buffer.c",
            "source/pdf/pdf-op-color.c",
            "source/pdf/pdf-op-filter.c",
            "source/pdf/pdf-op-run.c",
            "source/pdf/pdf-op-vectorize.c",
            "source/pdf/pdf-outline.c",
            "source/pdf/pdf-page.c",
            "source/pdf/pdf-parse.c",
            "source/pdf/pdf-pattern.c",
            "source/pdf/pdf-recolor.c",
            "source/pdf/pdf-repair.c",
            "source/pdf/pdf-resources.c",
            "source/pdf/pdf-run.c",
            "source/pdf/pdf-shade.c",
            "source/pdf/pdf-shade-recolor.c",
            "source/pdf/pdf-signature.c",
            "source/pdf/pdf-store.c",
            "source/pdf/pdf-stream.c",
            "source/pdf/pdf-subset.c",
            "source/pdf/pdf-type3.c",
            "source/pdf/pdf-unicode.c",
            "source/pdf/pdf-util.c",
            "source/pdf/pdf-write.c",
            "source/pdf/pdf-xobject.c",
            "source/pdf/pdf-xref.c",
            "source/pdf/pdf-zugferd.c",
        },
        .flags = mupdf_cflags,
    });

    // ============================================
    // MuPDF XPS sources
    // ============================================
    mupdf_c_module.addCSourceFiles(.{
        .root = mupdf_path,
        .files = &.{
            "source/xps/xps-common.c",
            "source/xps/xps-doc.c",
            "source/xps/xps-glyphs.c",
            "source/xps/xps-gradient.c",
            "source/xps/xps-image.c",
            "source/xps/xps-link.c",
            "source/xps/xps-outline.c",
            "source/xps/xps-path.c",
            "source/xps/xps-resource.c",
            "source/xps/xps-tile.c",
            "source/xps/xps-util.c",
            "source/xps/xps-zip.c",
        },
        .flags = mupdf_cflags,
    });

    // ============================================
    // MuPDF SVG sources
    // ============================================
    mupdf_c_module.addCSourceFiles(.{
        .root = mupdf_path,
        .files = &.{
            "source/svg/svg-color.c",
            "source/svg/svg-doc.c",
            "source/svg/svg-parse.c",
            "source/svg/svg-run.c",
        },
        .flags = mupdf_cflags,
    });

    // ============================================
    // MuPDF HTML sources - DISABLED (requires HarfBuzz)
    // Enable when we add HarfBuzz support
    // ============================================
    // mupdf_c_module.addCSourceFiles(.{
    //     .root = mupdf_path,
    //     .files = &.{
    //         "source/html/css-apply.c",
    //         "source/html/css-parse.c",
    //         "source/html/epub-doc.c",
    //         "source/html/html-doc.c",
    //         "source/html/html-font.c",
    //         "source/html/html-layout.c",
    //         "source/html/html-outline.c",
    //         "source/html/html-parse.c",
    //         "source/html/mobi.c",
    //         "source/html/office.c",
    //         "source/html/story-writer.c",
    //         "source/html/txt.c",
    //         "source/html/xml-dom.c",
    //     },
    //     .flags = mupdf_cflags,
    // });

    // ============================================
    // MuPDF CBZ sources
    // ============================================
    mupdf_c_module.addCSourceFiles(.{
        .root = mupdf_path,
        .files = &.{
            "source/cbz/mucbz.c",
            "source/cbz/muimg.c",
        },
        .flags = mupdf_cflags,
    });

    // ============================================
    // MuPDF Reflow sources
    // ============================================
    mupdf_c_module.addCSourceFiles(.{
        .root = mupdf_path,
        .files = &.{
            "source/reflow/reflow-doc.c",
        },
        .flags = mupdf_cflags,
    });

    // ============================================
    // Shim for Zig compatibility (handles C bitfields)
    // ============================================
    mupdf_c_module.addIncludePath(b.path("src")); // For mupdf_shim.h
    mupdf_c_module.addCSourceFiles(.{
        .root = b.path("."),
        .files = &.{
            "src/mupdf_shim.c",
        },
        .flags = mupdf_cflags,
    });

    // ============================================
    // Create the MuPDF static library
    // ============================================
    const mupdf_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "mupdf",
        .root_module = mupdf_c_module,
    });

    // Link libc for C code
    mupdf_lib.linkLibC();

    // Platform-specific libraries
    const resolved_target = target.result;
    if (resolved_target.os.tag == .linux) {
        mupdf_lib.linkSystemLibrary("m");
        mupdf_lib.linkSystemLibrary("pthread");
    }

    // Install the library
    b.installArtifact(mupdf_lib);

    // ============================================
    // Zig wrapper module (publicly exposed)
    // ============================================
    const mupdf_module = b.addModule("mupdf", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add include paths for @cImport
    mupdf_module.addIncludePath(b.path("src")); // For mupdf_shim.h
    mupdf_module.addIncludePath(b.path(".context/mupdf/include"));

    // Link the MuPDF C library
    mupdf_module.linkLibrary(mupdf_lib);

    // ============================================
    // Tests
    // ============================================
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    test_module.addIncludePath(b.path("src")); // For mupdf_shim.h
    test_module.addIncludePath(b.path(".context/mupdf/include"));
    test_module.linkLibrary(mupdf_lib);

    const lib_unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // ============================================
    // Example executable
    // ============================================
    const example_module = b.createModule(.{
        .root_source_file = b.path("examples/pdf_info.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Import the mupdf module
    example_module.addImport("mupdf", mupdf_module);

    const example_exe = b.addExecutable(.{
        .name = "pdf-info",
        .root_module = example_module,
    });

    b.installArtifact(example_exe);

    const run_example = b.addRunArtifact(example_exe);
    run_example.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_example.addArgs(args);
    }

    const run_step = b.step("run", "Run the pdf-info example");
    run_step.dependOn(&run_example.step);

    // ============================================
    // Server executable
    // ============================================
    const server_module = b.createModule(.{
        .root_source_file = b.path("examples/server.zig"),
        .target = target,
        .optimize = optimize,
    });

    server_module.addImport("mupdf", mupdf_module);

    const server_exe = b.addExecutable(.{
        .name = "mupdf-server",
        .root_module = server_module,
    });

    b.installArtifact(server_exe);

    const run_server = b.addRunArtifact(server_exe);
    run_server.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_server.addArgs(args);
    }

    const run_server_step = b.step("run-server", "Run the zig-mupdf HTTP server");
    run_server_step.dependOn(&run_server.step);

    // ============================================
    // Fuzz loop executable
    // ============================================
    const fuzz_module = b.createModule(.{
        .root_source_file = b.path("tests/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });

    fuzz_module.addImport("mupdf", mupdf_module);

    const fuzz_exe = b.addExecutable(.{
        .name = "mupdf-fuzz",
        .root_module = fuzz_module,
    });

    b.installArtifact(fuzz_exe);

    const run_fuzz = b.addRunArtifact(fuzz_exe);
    run_fuzz.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_fuzz.addArgs(args);
    }

    const fuzz_step = b.step("fuzz", "Run the mutation fuzz loop (args: iterations seed corpus_dir)");
    fuzz_step.dependOn(&run_fuzz.step);

    // ============================================
    // In-process engine benchmark
    // ============================================
    const bench_module = b.createModule(.{
        .root_source_file = b.path("benchmarks/engine_bench.zig"),
        .target = target,
        .optimize = optimize,
    });

    bench_module.addImport("mupdf", mupdf_module);

    const bench_exe = b.addExecutable(.{
        .name = "mupdf-engine-bench",
        .root_module = bench_module,
    });

    b.installArtifact(bench_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_bench.addArgs(args);
    }

    const bench_step = b.step("bench-engine", "Run the in-process engine benchmark (args: pdf iterations page)");
    bench_step.dependOn(&run_bench.step);
}

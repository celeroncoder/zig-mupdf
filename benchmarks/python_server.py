"""
PyMuPDF + FastAPI benchmark server.

Mirrors the zig-mupdf server endpoints for fair comparison.

Usage:
    pip install -r requirements.txt
    uvicorn python_server:app --host 0.0.0.0 --port 8081
"""

import io
import fitz  # PyMuPDF
from fastapi import FastAPI, UploadFile, File, Form
from fastapi.responses import JSONResponse, Response

app = FastAPI(title="PyMuPDF Benchmark Server")


@app.get("/health")
async def health():
    return {"status": "ok", "service": "pymupdf"}


@app.get("/")
async def root():
    return Response(
        content=(
            "PyMuPDF Benchmark Server\n\n"
            "Endpoints:\n"
            "  GET  /health              Health check\n"
            "  POST /info                PDF metadata\n"
            "  POST /text                Extract text\n"
            "  POST /search              Search text\n"
            "  POST /render              Render PNG\n"
        ),
        media_type="text/plain",
    )


@app.post("/info")
async def info(file: UploadFile = File(...)):
    data = await file.read()
    doc = fitz.open(stream=data, filetype="pdf")

    pages = []
    for i in range(min(doc.page_count, 50)):
        page = doc.load_page(i)
        rect = page.rect
        pages.append({
            "page": i,
            "width": round(rect.width, 1),
            "height": round(rect.height, 1),
            "rotation": page.rotation,
        })

    metadata = doc.metadata or {}

    result = {
        "page_count": doc.page_count,
        "is_pdf": doc.is_pdf,
        "needs_password": doc.needs_pass,
        "format": metadata.get("format", ""),
        "title": metadata.get("title", ""),
        "author": metadata.get("author", ""),
        "subject": metadata.get("subject", ""),
        "creator": metadata.get("creator", ""),
        "producer": metadata.get("producer", ""),
        "pages": pages,
    }
    doc.close()
    return result


@app.post("/text")
async def text(file: UploadFile = File(...), page: int = Form(0)):
    data = await file.read()
    doc = fitz.open(stream=data, filetype="pdf")

    if page < 0 or page >= doc.page_count:
        doc.close()
        return JSONResponse(
            status_code=400,
            content={"error": "Page number out of range"},
        )

    pg = doc.load_page(page)
    extracted = pg.get_text("text")
    doc.close()

    return {"page": page, "text": extracted}


@app.post("/search")
async def search(
    file: UploadFile = File(...),
    page: int = Form(0),
    query: str = Form(...),
):
    data = await file.read()
    doc = fitz.open(stream=data, filetype="pdf")

    if page < 0 or page >= doc.page_count:
        doc.close()
        return JSONResponse(
            status_code=400,
            content={"error": "Page number out of range"},
        )

    pg = doc.load_page(page)
    hits_raw = pg.search_for(query)
    doc.close()

    hits = []
    for rect in hits_raw:
        hits.append({
            "x": round(rect.x0, 1),
            "y": round(rect.y0, 1),
            "width": round(rect.width, 1),
            "height": round(rect.height, 1),
        })

    return {
        "page": page,
        "query": query,
        "hit_count": len(hits),
        "hits": hits,
    }


@app.post("/render")
async def render(
    file: UploadFile = File(...),
    page: int = Form(0),
    scale: float = Form(1.0),
):
    data = await file.read()
    doc = fitz.open(stream=data, filetype="pdf")

    if page < 0 or page >= doc.page_count:
        doc.close()
        return JSONResponse(
            status_code=400,
            content={"error": "Page number out of range"},
        )

    pg = doc.load_page(page)
    mat = fitz.Matrix(scale, scale)
    pix = pg.get_pixmap(matrix=mat)
    png_data = pix.tobytes("png")
    doc.close()

    return Response(content=png_data, media_type="image/png")

"""Extract text per page from every book in the inventory into the text cache, text/<sha1(key)>.jsonl.

Each line: {"src": "pdf"|"md"|"epub"|"txt", "page": int, "text": str, "images": [rel paths]}
Re-runnable: a book is skipped while its sources are the files, at the sizes, its cache was built from.
DjVu needs djvutxt (brew install djvulibre); Word, RTF and OpenDocument files go through macOS's textutil.
A PDF whose pages are mostly images is marked for text recognition (ocr.py), in <cache>.ocr.

Books whose file name does not name the author also get their embedded title and author, in
metadata.json (see metadata.py).
"""
import hashlib
import html
import json
import re
import subprocess
import zipfile
from concurrent.futures import ThreadPoolExecutor, as_completed

import metadata
from config import CACHE, DATA, INVENTORY, METADATA, ROOT

PDF_TIMEOUT_S = 600
WORKERS = 4
MD_CHUNK_CHARS = 3000
MIN_PAGE_CHARS = 3
TOOL_TIMEOUT_S = 300
# A page with less text than this counts as an image for text recognition.
OCR_MIN_CHARS = 20
OCR_MIN_MISSING = 3
OCR_MISSING_SHARE = 0.1

PAGE_MARK = re.compile(r'_page_(\d+)_|<span id="page-(\d+)-')
IMG_REF = re.compile(r"!\[[^\]]*\]\(([^)]+)\)")
TAG = re.compile(r"<[^>]+>")


def needs_ocr(pages: int, with_text: int) -> bool:
    """Worth recognising: more than a few pages, and a tenth of the book, are images without text."""
    missing = pages - with_text
    return missing >= max(OCR_MIN_MISSING, pages * OCR_MISSING_SHARE)


def paged(src, text):
    """Rows of a text whose pages are separated by form feeds (pdftotext, djvutxt)."""
    return [{"src": src, "page": i + 1, "text": t.strip(), "images": []}
            for i, t in enumerate(text.split("\f")) if len(t.strip()) >= MIN_PAGE_CHARS]


def pdf_text(path):
    out = subprocess.run(["pdftotext", "-q", "-enc", "UTF-8", str(path), "-"],
                         capture_output=True, timeout=PDF_TIMEOUT_S, check=False)
    return out.stdout.decode("utf-8", errors="replace")


def pdf_pages(path):
    return paged("pdf", pdf_text(path))


def djvu_pages(path):
    out = subprocess.run(["djvutxt", str(path)], capture_output=True, timeout=PDF_TIMEOUT_S, check=True)
    return paged("djvu", decode(out.stdout))


def textutil_pages(path):
    """Word, RTF and OpenDocument text, through macOS's textutil."""
    out = subprocess.run(["textutil", "-convert", "txt", "-stdout", str(path)], capture_output=True,
                         timeout=TOOL_TIMEOUT_S, check=True)
    return chunked("txt", out.stdout.decode("utf-8", errors="replace"))


def decode(raw: bytes) -> str:
    """UTF-8 (or UTF-16 with its byte-order mark); anything else is read as Windows-1252."""
    if raw.startswith((b"\xff\xfe", b"\xfe\xff")):
        return raw.decode("utf-16", errors="replace")
    try:
        return raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        return raw.decode("cp1252", errors="replace")


def chunked(src, text):
    return [{"src": src, "page": i + 1, "text": text[j:j + MD_CHUNK_CHARS], "images": []}
            for i, j in enumerate(range(0, len(text), MD_CHUNK_CHARS)) if text[j:j + MD_CHUNK_CHARS].strip()]


def md_pages(path):
    """Split marker output into chunks, inferring the page from image refs and page spans."""
    raw = path.read_text(encoding="utf-8", errors="replace")
    folder = path.parent.relative_to(ROOT)
    chunks, buf, imgs, page = [], [], [], 1

    def flush():
        text = TAG.sub(" ", IMG_REF.sub(" ", "".join(buf))).strip()
        if len(text) >= MIN_PAGE_CHARS or imgs:
            chunks.append({"src": "md", "page": page, "text": text, "images": list(imgs)})

    for line in raw.splitlines(keepends=True):
        m = PAGE_MARK.search(line)
        new_page = int(m.group(1) or m.group(2)) + 1 if m else page
        size = sum(len(b) for b in buf)
        if (new_page != page and buf) or size > MD_CHUNK_CHARS:
            flush()
            buf, imgs = [], []
        page = new_page
        buf.append(line)
        imgs.extend(str(folder / ref) for ref in IMG_REF.findall(line) if "://" not in ref)
    if buf:
        flush()
    return chunks


def epub_pages(path):
    pages = []
    with zipfile.ZipFile(path) as z:
        names = sorted(n for n in z.namelist() if n.lower().endswith((".xhtml", ".html", ".htm")))
        for i, n in enumerate(names):
            body = z.read(n).decode("utf-8", errors="replace")
            text = html.unescape(TAG.sub(" ", re.sub(r"(?is)<(script|style).*?</\1>", " ", body)))
            text = re.sub(r"\s+", " ", text).strip()
            if len(text) >= MIN_PAGE_CHARS:
                pages.append({"src": "epub", "page": i + 1, "text": text, "images": []})
    return pages


def txt_pages(path):
    return chunked("txt", decode(path.read_bytes()))


HANDLERS = {".pdf": pdf_pages, ".md": md_pages, ".epub": epub_pages, ".txt": txt_pages, ".djvu": djvu_pages,
            ".docx": textutil_pages, ".doc": textutil_pages, ".rtf": textutil_pages, ".odt": textutil_pages}


def sources(book):
    return [ROOT / f for f in book["files"]] + [ROOT / m for m in book["md"]]


def cache_path(book):
    return CACHE / (hashlib.sha1(book["key"].encode()).hexdigest()[:16] + ".jsonl")


def signature(srcs):
    """Which files, at which size, a cache was built from. Finder keeps old mtimes on copy, so
    a newly added md folder can be older than the cache; the file list catches that."""
    return [[str(s.relative_to(ROOT)), s.stat().st_size] for s in srcs if s.exists()]


def is_fresh(out, srcs):
    sig = out.with_suffix(".sig")
    if not out.exists():
        return False
    if not sig.exists():  # caches from before signatures existed: trust them once and record
        sig.write_text(json.dumps(signature(srcs), ensure_ascii=False))
        return True
    return json.loads(sig.read_text()) == signature(srcs)


def ocr_status(out) -> dict:
    try:
        return json.loads(out.with_suffix(".ocr").read_text())
    except (OSError, ValueError):
        return {}


def write_ocr_status(out, status: dict) -> None:
    out.with_suffix(".ocr").write_text(json.dumps(status, ensure_ascii=False))


def ocr_plan(srcs, page_counts: dict) -> dict:
    """The OCR state for a book; page_counts: {path: (pages, pages with text)} of its PDFs.

    "share" is the part of the pages that have text, so books that are scans through and through
    are recognised before picture books with a few captions to find."""
    scanned = [s for s in srcs if str(s) in page_counts and needs_ocr(*page_counts[str(s)])]
    if not scanned:
        return {"state": "none"}
    pages = sum(page_counts[str(s)][0] for s in scanned)
    share = sum(page_counts[str(s)][1] for s in scanned) / max(pages, 1)
    return {"state": "pending", "files": [str(s.relative_to(ROOT)) for s in scanned], "share": round(share, 3)}


def extract_book(book):
    out = cache_path(book)
    srcs = sources(book)
    if is_fresh(out, srcs):
        return book["id"], "cached", None
    rows, errors, counts = [], [], {}
    for s in srcs:
        handler = HANDLERS.get(s.suffix.lower())
        if handler is None:
            continue
        try:
            if handler is pdf_pages:
                text = pdf_text(s)
                counts[str(s)] = (text.count("\f"), sum(len(p.strip()) >= OCR_MIN_CHARS for p in text.split("\f")))
                rows.extend(paged("pdf", text))
            else:
                rows.extend(handler(s))
        except Exception as e:  # noqa: BLE001 — keep going; record which file failed and why
            errors.append(f"{s.relative_to(ROOT)}: {type(e).__name__}: {e}")
    tmp = out.with_suffix(".tmp")
    tmp.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")
    tmp.replace(out)
    out.with_suffix(".sig").write_text(json.dumps(signature(srcs), ensure_ascii=False))
    # Books with a Markdown folder already carry recognised text (marker's); Vision would only compete with it.
    write_ocr_status(out, ocr_plan(srcs, counts) if not book["md"] else {"state": "none"})
    return book["id"], f"{len(rows)} pages", errors


def prune(inv):
    """Remove cache files of books that are no longer in the library."""
    keep = {cache_path(b).stem for b in inv}
    for f in CACHE.iterdir():
        if f.suffix in (".jsonl", ".sig", ".ocr") and f.stem not in keep:
            f.unlink()


def refresh_metadata(inv, pool) -> None:
    """Embedded titles for the books whose file name names no author, read once per set of files."""
    try:
        known = json.loads(METADATA.read_text())
    except (OSError, ValueError):
        known = {}
    wanted = [b for b in inv if not b["author"] and b["files"]]
    stale = [b for b in wanted if known.get(b["key"], {}).get("files") != b["files"]]
    found = dict(zip((b["key"] for b in stale),
                     pool.map(lambda b: dict(metadata.read([ROOT / f for f in b["files"]]), files=b["files"]), stale)))
    keep = {b["key"] for b in wanted}
    current = {k: v for k, v in {**known, **found}.items() if k in keep}
    if current != known:
        tmp = METADATA.with_suffix(".tmp")
        tmp.write_text(json.dumps(current, ensure_ascii=False, indent=1))
        tmp.replace(METADATA)


def main():
    """Extract every stale book; returns how many were (re)extracted."""
    CACHE.mkdir(parents=True, exist_ok=True)
    inv = json.loads(INVENTORY.read_text())
    changed = 0
    prune(inv)
    with open(DATA / "extract.log", "a", encoding="utf-8") as log, ThreadPoolExecutor(WORKERS) as pool:
        futures = [pool.submit(extract_book, b) for b in inv]
        for n, f in enumerate(as_completed(futures), 1):
            bid, status, errors = f.result()
            log.writelines(f"ERROR book {bid}: {e}\n" for e in errors or [])
            if status != "cached":
                changed += 1
                print(f"text: book {bid} ({status})", flush=True)
            if n == len(inv):
                print(f"{n}/{len(inv)} done", flush=True)
        refresh_metadata(inv, pool)
    return changed


if __name__ == "__main__":
    main()

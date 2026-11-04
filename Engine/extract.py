"""Extract text per page from every book in the inventory into the text cache, text/<sha1(key)>.jsonl.

Each line: {"src": "pdf"|"md"|"epub"|"txt", "page": int, "text": str, "images": [rel paths]}
Re-runnable: a book is skipped while its sources are the files, at the sizes, its cache was built from.
"""
import hashlib
import html
import json
import re
import subprocess
import zipfile
from concurrent.futures import ThreadPoolExecutor, as_completed

from config import CACHE, DATA, INVENTORY, ROOT

PDF_TIMEOUT_S = 600
WORKERS = 4
MD_CHUNK_CHARS = 3000
MIN_PAGE_CHARS = 3

PAGE_MARK = re.compile(r'_page_(\d+)_|<span id="page-(\d+)-')
IMG_REF = re.compile(r"!\[[^\]]*\]\(([^)]+)\)")
TAG = re.compile(r"<[^>]+>")


def pdf_pages(path):
    out = subprocess.run(["pdftotext", "-q", "-enc", "UTF-8", str(path), "-"],
                         capture_output=True, timeout=PDF_TIMEOUT_S, check=False)
    text = out.stdout.decode("utf-8", errors="replace")
    return [{"src": "pdf", "page": i + 1, "text": t.strip(), "images": []}
            for i, t in enumerate(text.split("\f")) if len(t.strip()) >= MIN_PAGE_CHARS]


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
    text = path.read_text(encoding="utf-8", errors="replace")
    return [{"src": "txt", "page": i + 1, "text": text[j:j + MD_CHUNK_CHARS], "images": []}
            for i, j in enumerate(range(0, len(text), MD_CHUNK_CHARS))]


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


def extract_book(book):
    out = cache_path(book)
    srcs = sources(book)
    if is_fresh(out, srcs):
        return book["id"], "cached", None
    rows, errors = [], []
    for s in srcs:
        ext = s.suffix.lower()
        handler = {".pdf": pdf_pages, ".md": md_pages, ".epub": epub_pages, ".txt": txt_pages}.get(ext)
        if handler is None:
            continue
        try:
            rows.extend(handler(s))
        except Exception as e:  # noqa: BLE001 — keep going; record which file failed and why
            errors.append(f"{s.relative_to(ROOT)}: {type(e).__name__}: {e}")
    tmp = out.with_suffix(".tmp")
    tmp.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")
    tmp.replace(out)
    out.with_suffix(".sig").write_text(json.dumps(signature(srcs), ensure_ascii=False))
    return book["id"], f"{len(rows)} pages", errors


def prune(inv):
    """Remove cache files of books that are no longer in the library."""
    keep = {cache_path(b).stem for b in inv}
    for f in CACHE.iterdir():
        if f.suffix in (".jsonl", ".sig") and f.stem not in keep:
            f.unlink()


def main():
    """Extract every stale book; returns how many were (re)extracted."""
    CACHE.mkdir(exist_ok=True)
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
                print(f"κείμενο: βιβλίο {bid} ({status})", flush=True)
            if n == len(inv):
                print(f"{n}/{len(inv)} done", flush=True)
    return changed


if __name__ == "__main__":
    main()

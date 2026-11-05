"""Recognise the text of scanned PDF pages, one book at a time, with the app's helper (macOS Vision).

extract.py marks a PDF whose pages are mostly images in <cache>.ocr as {"state": "pending"}. Text
caches made before that mark existed are assessed here once: the PDF's page count (pdfinfo) against
the pages that came out with text. Recognised pages replace the empty ones in the text cache, which
the next index sync picks up, so a book becomes searchable as soon as it is done. The work stops
between books whenever should_stop() says so (the library changed): new books come first.

Vision reads no Greek. When Tesseract with its Greek model is installed, the helper hands it the
pages Vision is unsure of that Tesseract sees as Greek, and every page of a book with a Greek title.
Without Tesseract, books with Greek titles wait rather than get Vision's guesses.
"""
import json
import logging
import re
import shutil
import subprocess
from collections.abc import Callable
from functools import cache
from pathlib import Path

from config import INVENTORY, OCR_TOOL, ROOT
from extract import (
    MIN_PAGE_CHARS,
    OCR_MIN_CHARS,
    cache_path,
    ocr_plan,
    ocr_status,
    write_ocr_status,
)

BOOK_TIMEOUT_S = 3 * 3600
# Long books get more: the helper read a page in 0.4–1.7 s in the tests, so this is far above that.
PAGE_TIMEOUT_S = 30
# Checking for library changes walks the whole tree, so it is done only every so many books.
STOP_CHECK_EVERY = 50
INFO_TIMEOUT_S = 30
GREEK = re.compile(r"[\u0370-\u03ff\u1f00-\u1fff]")
LETTER = re.compile(r"[^\W\d_]")
# Tesseract's models for Greek, for English (in Greek books) and for script detection.
TESSERACT_MODELS = {"ell", "eng", "osd"}

log = logging.getLogger("library-update")


def page_count(pdf: Path) -> int:
    out = subprocess.run(["pdfinfo", str(pdf)], capture_output=True, timeout=INFO_TIMEOUT_S, check=False)
    for line in out.stdout.decode("utf-8", errors="replace").splitlines():
        if line.startswith("Pages:"):
            return int(line.split(":", 1)[1])
    return 0


@cache
def tesseract() -> str | None:
    """Tesseract's path, if it is installed with the models the helper uses."""
    path = shutil.which("tesseract")
    if not path:
        return None
    langs = subprocess.run([path, "--list-langs"], capture_output=True, timeout=INFO_TIMEOUT_S, check=False)
    return path if TESSERACT_MODELS <= set(langs.stdout.decode(errors="replace").split()) else None


def greek_title(book: dict) -> bool:
    """Most of the title's letters are Greek (a "λ-calculus" or "α-synuclein" is not a Greek book)."""
    letters = LETTER.findall(book["title"])
    return bool(letters) and len(GREEK.findall(book["title"])) * 2 > len(letters)


def runnable(todo: list, tesseract: str | None) -> tuple[list, int]:
    """([(book, files, helper arguments)], how many Greek books wait for Tesseract)."""
    runs, waiting = [], 0
    for book, files in todo:
        greek = greek_title(book)
        if greek and not tesseract:
            waiting += 1
            continue
        args = ["--tesseract", tesseract] if tesseract else []
        runs.append((book, files, args + ["--greek"] if greek else args))
    return runs, waiting


def cached_rows(book: dict) -> list:
    path = cache_path(book)
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def assess(book: dict) -> dict:
    """The OCR state of a book whose text cache predates the mark."""
    pdfs = [ROOT / f for f in book["files"] if f.lower().endswith(".pdf")]
    if not pdfs or book["md"] or not cache_path(book).exists():
        return {"state": "none"}
    # The cache does not say which PDF a page came from; with several, the text is counted for each.
    with_text = sum(r["src"] == "pdf" and len(r["text"]) >= OCR_MIN_CHARS for r in cached_rows(book))
    return ocr_plan(pdfs, {str(p): (page_count(p), with_text) for p in pdfs})


def recognise(pdf: Path, args: list) -> dict:
    """{page: text} for the pages of pdf the helper read."""
    timeout = max(BOOK_TIMEOUT_S, page_count(pdf) * PAGE_TIMEOUT_S)
    out = subprocess.run([OCR_TOOL, str(pdf), "--min-chars", str(OCR_MIN_CHARS), *args], capture_output=True,
                         timeout=timeout, check=True)
    pages = {}
    for line in out.stdout.decode("utf-8", errors="replace").splitlines():
        row = json.loads(line)
        pages[row["page"]] = row["text"].strip()
    return pages


def merged(rows: list, found: dict) -> list:
    """The cache rows with the recognised pages in place of the PDF's empty ones."""
    # Tesseract writes the micro sign for the Greek μ (NFKC would also flatten footnote marks into words).
    found = {p: t.replace("\u00b5", "\u03bc") for p, t in found.items() if len(t) >= MIN_PAGE_CHARS}
    kept = [r for r in rows if not (r["src"] == "pdf" and r["page"] in found)]
    added = [{"src": "pdf", "page": p, "text": t, "images": []} for p, t in found.items()]
    return sorted(kept + added, key=lambda r: (r["page"], r["src"]))


def write_rows(book: dict, rows: list) -> None:
    out = cache_path(book)
    tmp = out.with_suffix(".tmp")
    tmp.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")
    tmp.replace(out)


def pending(inventory: list, should_stop: Callable[[], bool]) -> list:
    todo, assessed = [], 0
    for book in inventory:
        out = cache_path(book)
        status = ocr_status(out)
        if not status and out.exists():
            assessed += 1
            if assessed % STOP_CHECK_EVERY == 0 and should_stop():
                break
            try:
                status = assess(book)
            except Exception as e:  # noqa: BLE001 — one unreadable book must not stop the others
                status = {"state": "failed", "error": f"{type(e).__name__}: {e}"}
            write_ocr_status(out, status)
        if status.get("state") == "pending":
            todo.append((status.get("share", 0), book, status["files"]))
    return [(book, files) for _, book, files in sorted(todo, key=lambda t: t[0])]


def main(should_stop: Callable[[], bool], on_book: Callable[[], None]) -> int:
    """Recognise pending books until done or should_stop(); on_book() runs after each. Returns how many."""
    if not OCR_TOOL or not Path(OCR_TOOL).exists():
        return 0
    todo, waiting = runnable(pending(json.loads(INVENTORY.read_text()), should_stop), tesseract())
    # Always sent, so the app's notice goes away once Tesseract is installed.
    print(f"@ocr-waiting {waiting}", flush=True)
    if waiting:
        log.info("%d books with Greek titles wait for Tesseract (brew install tesseract tesseract-lang)", waiting)
    done = 0
    for n, (book, files, args) in enumerate(todo):
        if should_stop():
            break
        print(f"@ocr {n} {len(todo)}", flush=True)
        try:
            found = {}
            for f in files:
                found.update(recognise(ROOT / f, args))
            write_rows(book, merged(cached_rows(book), found))
            write_ocr_status(cache_path(book), {"state": "done"})
            log.info("text recognised: %s (%d pages)", book["key"], len(found))
        except Exception as e:  # noqa: BLE001 — record it and go on with the next book
            write_ocr_status(cache_path(book), {"state": "failed", "error": f"{type(e).__name__}: {e}"})
            log.info("text recognition failed: %s: %s", book["key"], e)
        done += 1
        on_book()
    return done

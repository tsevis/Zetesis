"""Titles, authors and subjects stored inside the books, for books whose file name does not say them.

File names of the form "Title (Author)" are taken as they are. Otherwise the book's own metadata is
read: a Calibre `metadata.opf` beside the file, the OPF package inside an EPUB, or the PDF's info
dictionary. PDF titles are often left over from the program that made the file ("Microsoft Word -
draft.docx", "untitled"), so those are ignored.
"""
import re
import subprocess
import xml.etree.ElementTree as ET
import zipfile
from collections import Counter
from pathlib import Path

PDFINFO_TIMEOUT_S = 30
MIN_TITLE = 3
DC = "{http://purl.org/dc/elements/1.1/}"
JUNK_TITLE = re.compile(
    r"^(untitled|unknown|title|document\d*|doc\d*|book\d*|print|scan\w*|layout \d+|\d+)$"
    r"|^microsoft (word|powerpoint)|\.(docx?|indd|qxd|pdf|tex|dvi|ps|rtf|odt)$"
    r"|^c:\\|^/|^\s*$",
    re.IGNORECASE,
)


def clean(value: str | None) -> str:
    return re.sub(r"\s+", " ", value or "").strip()


JUNK_AUTHOR = re.compile(r"^(my pc|user|admin(istrator)?|owner|unknown|author|[^\w]*)$", re.IGNORECASE)
# File names that say nothing about the book: numbers, catalogue ids, scanner output.
ID_LIKE = re.compile(r"^[\W\d_]*$|^[\w.-]*\d[\w.-]*$")


WORD = re.compile(r"[^\W\d_]{3,}")
VOWEL = re.compile(r"[aeiouyàáâäèéêëìíîïòóôöùúûü]", re.IGNORECASE)


def is_real_title(title: str) -> bool:
    """Not a placeholder, and at least one pronounceable word (codes like "g1_prnt" or "RSGJ_A" have none)."""
    words = WORD.findall(title)
    has_word = any(VOWEL.search(w) or not w.isascii() for w in words)
    return len(title) >= MIN_TITLE and has_word and not JUNK_TITLE.search(title)


def real_author(author: str) -> str:
    return "" if JUNK_AUTHOR.search(author) else author


def from_opf(xml: bytes) -> dict:
    """{"title", "author", "subjects"} from an OPF package document; empty fields when absent."""
    try:
        root = ET.fromstring(xml)
    except ET.ParseError:
        return {}
    title = next((clean(e.text) for e in root.iter(f"{DC}title") if clean(e.text)), "")
    authors = [clean(e.text) for e in root.iter(f"{DC}creator") if clean(e.text)]
    subjects = [clean(e.text) for e in root.iter(f"{DC}subject") if clean(e.text)]
    return {"title": title, "author": ", ".join(authors), "subjects": subjects}


def epub_opf(path: Path) -> bytes | None:
    with zipfile.ZipFile(path) as z:
        try:
            container = ET.fromstring(z.read("META-INF/container.xml"))
        except (KeyError, ET.ParseError):
            container = None
        if container is not None:
            for e in container.iter():
                if e.tag.endswith("rootfile") and e.get("full-path"):
                    try:
                        return z.read(e.get("full-path"))
                    except KeyError:
                        break
        name = next((n for n in z.namelist() if n.lower().endswith(".opf")), None)
        return z.read(name) if name else None


def from_pdfinfo(output: str) -> dict:
    fields = {}
    for line in output.splitlines():
        key, _, value = line.partition(":")
        if key in ("Title", "Author"):
            fields[key.lower()] = clean(value)
    title = fields.get("title", "")
    return {"title": title if is_real_title(title) else "", "author": real_author(fields.get("author", "")),
            "subjects": []}


def pdf_info(path: Path) -> dict:
    out = subprocess.run(["pdfinfo", "-enc", "UTF-8", str(path)], capture_output=True,
                         timeout=PDFINFO_TIMEOUT_S, check=False)
    return from_pdfinfo(out.stdout.decode("utf-8", errors="replace"))


def read(files: list[Path]) -> dict:
    """The first usable metadata among a book's files, Calibre's OPF first."""
    candidates = []
    for f in files:
        calibre = f.parent / "metadata.opf"
        if calibre.exists():
            candidates.append(lambda c=calibre: from_opf(c.read_bytes()))
    for f in files:
        ext = f.suffix.lower()
        if ext == ".epub":
            candidates.append(lambda f=f: from_opf(epub_opf(f) or b""))
        elif ext == ".pdf":
            candidates.append(lambda f=f: pdf_info(f))
    for get in candidates:
        try:
            meta = get()
        except Exception:  # noqa: BLE001, S112 — a damaged book must never stop the update; try the next source
            continue
        if meta.get("title") and is_real_title(meta["title"]):
            return meta
    return {}


# A title found in this many books or more is the stamp of whoever made the files, not a title.
SHARED_TITLE_BOOKS = 3


def with_metadata(inventory: list, found: dict) -> list:
    """The inventory with titles and authors from inside the books, where the file name gave no author."""
    shared = Counter((m or {}).get("title") for m in found.values())
    result = []
    for book in inventory:
        meta = found.get(book["key"]) or {}
        # The embedded title wins only when it comes with an author or the file name is an id:
        # a plain file name is usually better than a stray title left in the file.
        title = meta.get("title", "")
        usable = is_real_title(title) and shared[title] < SHARED_TITLE_BOOKS and not ID_LIKE.search(title)
        if not book["author"] and usable and (meta.get("author") or ID_LIKE.search(book["title"])):
            book = dict(book, title=meta["title"], author=meta.get("author", ""))
        result.append(book)
    return result

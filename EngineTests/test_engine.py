"""Engine rules that decide what a library's books are called, where they belong and what gets OCR.

Run from the repository root:  python3 EngineTests/test_engine.py  (or with pytest)
"""
import os
import sys
import tempfile
from pathlib import Path

os.environ.setdefault("ZETESIS_LIBRARY", tempfile.mkdtemp())
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Engine"))

import classify_new
import extract
import inventory
import metadata
import ocr


def test_cyrillic_and_greek_names_keep_their_letters():
    # An md folder is matched to its book by normalised name; a name reduced to nothing matches anything.
    assert inventory.norm("Кобзар (Тарас Шевченко)") == "кобзартарасшевченко"
    assert inventory.norm("Ιστορία της Τέχνης") == "ιστορίατηςτέχνης"


def test_calibre_opf_gives_title_author_and_subjects():
    opf = b"""<?xml version='1.0'?><package xmlns="http://www.idpf.org/2007/opf"
      xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata>
      <dc:title>Le Rouge et le Noir</dc:title><dc:creator>Stendhal</dc:creator>
      <dc:subject>Fiction</dc:subject><dc:subject>France</dc:subject></metadata></package>"""
    assert metadata.from_opf(opf) == {"title": "Le Rouge et le Noir", "author": "Stendhal",
                                      "subjects": ["Fiction", "France"]}


def test_pdf_titles_left_by_the_authoring_program_are_ignored():
    for junk in ("Microsoft Word - draft3.docx", "untitled", "layout 1", "C:\\temp\\book.pdf", "0123"):
        assert metadata.from_pdfinfo(f"Title:          {junk}\nAuthor: X\n")["title"] == ""
    assert metadata.from_pdfinfo("Title: Die Traumdeutung\nAuthor: Sigmund Freud\n")["title"] == "Die Traumdeutung"


def test_folders_holding_several_books_become_topics():
    keys = ["Physics/Feynman Lectures", "Physics/QED", "Physics/Optics",
            "Kobzar (Shevchenko)", "Kobzar (Shevchenko)/Kobzar",  # a book's own md folder is not a topic
            "Art/One Book"]
    assert classify_new.folder_topics(keys) == {"Physics/Feynman Lectures": "Physics", "Physics/QED": "Physics",
                                                "Physics/Optics": "Physics"}


def test_ocr_is_wanted_only_when_many_pages_have_no_text():
    assert extract.needs_ocr(pages=300, with_text=0)
    assert extract.needs_ocr(pages=300, with_text=200)
    assert not extract.needs_ocr(pages=300, with_text=296)  # a few blank or plate pages
    assert not extract.needs_ocr(pages=2, with_text=1)



def test_recognised_pages_replace_only_the_empty_pdf_pages():
    rows = [{"src": "pdf", "page": 1, "text": "Title page", "images": []},
            {"src": "pdf", "page": 2, "text": "", "images": []},
            {"src": "md", "page": 2, "text": "marker text", "images": ["a.jpg"]}]
    out = ocr.merged(rows, {2: "recognised words", 3: "more words", 4: ""})
    assert [(r["src"], r["page"], r["text"]) for r in out] == [
        ("pdf", 1, "Title page"), ("md", 2, "marker text"), ("pdf", 2, "recognised words"), ("pdf", 3, "more words")]



def test_a_damaged_epub_does_not_stop_the_update():
    # Its metadata is read on every run until something is stored, so one bad file would fail them all.
    import zipfile
    path = Path(tempfile.mkdtemp()) / "broken.epub"
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("content.opf", "<package>" + "x" * 5000 + "</package>")
    raw = bytearray(path.read_bytes())
    start = raw.index(b"content.opf") + len("content.opf")  # just past the local header's name
    raw[start + 10:start + 40] = b"\xff" * 30  # corrupt the deflate stream
    path.write_bytes(bytes(raw))
    assert metadata.read([path]) == {}


def test_embedded_titles_replace_only_uninformative_file_names():
    found = {"a": {"title": "BNCR Tecadigitale", "author": ""},
             "b": {"title": "Die Traumdeutung", "author": "Sigmund Freud"},
             "c": {"title": "Le Rouge et le Noir", "author": ""}}
    inv = [{"key": "a", "title": "Storia della stampa", "author": ""},
           {"key": "b", "title": "traumdeutung scan", "author": ""},
           {"key": "c", "title": "10787525", "author": ""}]
    assert [b["title"] for b in metadata.with_metadata(inv, found)] == [
        "Storia della stampa", "Die Traumdeutung", "Le Rouge et le Noir"]


def test_titles_shared_by_several_books_or_shaped_like_codes_are_not_titles():
    # Digitisation projects stamp their own name into every file; some tools leave a code.
    found = {f"r{i}": {"title": "BNCR Tecadigitale", "author": ""} for i in range(3)}
    found["g"] = {"title": "g1_prnt", "author": "Ralph E. Griswold"}
    found["j"] = {"title": "RSGJ_A_549344 231..257 ++", "author": "Taylor & Francis"}
    inv = [{"key": k, "title": f"larivista-19{k}", "author": ""} for k in found]
    assert [b["title"] for b in metadata.with_metadata(inv, found)] == [b["title"] for b in inv]


if __name__ == "__main__":
    failed = 0
    for name, test in [(n, f) for n, f in globals().items() if n.startswith("test_")]:
        try:
            test()
            print("ok  ", name)
        except Exception as e:  # noqa: BLE001 — report every failing test, not only the first
            failed += 1
            print("FAIL", name, type(e).__name__, e)
    sys.exit(1 if failed else 0)

"""Engine rules that decide what a library's books are called, where they belong and what gets OCR.

Run from the repository root:  python3 EngineTests/test_engine.py  (or with pytest)
"""
import os
import signal
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import zipfile
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


def test_recognised_greek_mu_is_the_greek_letter():
    # Tesseract writes the micro sign for μ; left alone, no search for a word with μ would find it.
    out = ocr.merged([], {1: "σκονισ\u00b5ένα βιβλία"})
    assert out[0]["text"] == "σκονισμένα βιβλία"


def test_greek_books_wait_for_tesseract_instead_of_getting_vision_junk():
    greek = {"key": "g", "title": "Η τέχνη της τυπογραφίας", "author": ""}
    latin = {"key": "l", "title": "The art of printing", "author": ""}
    symbol = {"key": "s", "title": "The λ-calculus and α-synuclein", "author": "Ιωάννης Π."}
    runs, waiting = ocr.runnable([(symbol, ["s.pdf"])], tesseract=None)
    assert [b["key"] for b, _, _ in runs] == ["s"] and waiting == 0
    todo = [(greek, ["g.pdf"]), (latin, ["l.pdf"])]
    runs, waiting = ocr.runnable(todo, tesseract=None)
    assert [(b["key"], args) for b, _, args in runs] == [("l", [])] and waiting == 1
    runs, waiting = ocr.runnable(todo, tesseract="/bin/tesseract")
    assert [(b["key"], args) for b, _, args in runs] == [
        ("g", ["--tesseract", "/bin/tesseract", "--greek"]), ("l", ["--tesseract", "/bin/tesseract"])]
    assert waiting == 0


def test_stopping_the_engine_also_stops_the_program_it_is_waiting_for():
    # The app stops the engine with SIGTERM when it quits; the OCR helper must not run on, orphaned.
    engine = Path(__file__).resolve().parent.parent / "Engine"
    script = f"import sys; sys.path.insert(0, {str(engine)!r}); import update, subprocess; " \
             "update.stop_on_sigterm(); subprocess.run(['sleep', '30'])"
    parent = subprocess.Popen([sys.executable, "-c", script])
    child = None
    for _ in range(100):
        found = subprocess.run(["pgrep", "-P", str(parent.pid), "sleep"], capture_output=True, text=True,
                               check=False).stdout.split()
        if found:
            child = int(found[0])
            break
        time.sleep(0.05)
    assert child, "the engine did not start its program"
    parent.send_signal(signal.SIGTERM)
    parent.wait(timeout=5)
    time.sleep(0.2)
    alive = subprocess.run(["kill", "-0", str(child)], capture_output=True, check=False).returncode == 0
    if alive:
        os.kill(child, signal.SIGKILL)
    assert not alive, "the program outlived the engine"


def test_a_huge_entry_in_an_epub_is_not_inflated_into_memory():
    # 30 MB of one letter compresses to a few KB: a hostile EPUB could hold gigabytes like this.
    path = Path(tempfile.mkdtemp()) / "bomb.epub"
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("META-INF/container.xml", "<container/>")
        z.writestr("a.opf", "<package>" + " " * 30_000_000 + "</package>")
        z.writestr("ch1.xhtml", "<p>a real chapter of the book</p>")
        z.writestr("ch2.xhtml", "<p>" + "a" * 30_000_000 + "</p>")
    assert [p["text"] for p in extract.epub_pages(path)] == ["a real chapter of the book"]
    assert metadata.epub_opf(path) is None


def test_a_topic_named_dot_dot_stays_inside_the_topic_folder():
    import make_topic_folders
    book = {"key": "k", "files": ["Some Book.pdf"], "folder": ""}
    for name in ("..", ".", "../../etc"):
        links = make_topic_folders.wanted_links([book], {"k": {"topic": name}})
        out = os.path.normpath(make_topic_folders.OUT)
        assert all(os.path.normpath(link).startswith(out + os.sep) for link in links), (name, links)


def test_the_index_folder_is_readable_by_its_owner_only():
    # It holds the full text of every book in the library.
    import update
    folder = Path(tempfile.mkdtemp()) / "Zetesis"
    update.make_private(folder)
    assert stat.S_IMODE(folder.stat().st_mode) == 0o700


def test_a_stopped_engine_says_so_in_the_log():
    # A run of text recognition that ends without a line in the log looks like a crash.
    engine = Path(__file__).resolve().parent.parent / "Engine"
    logfile = Path(tempfile.mkdtemp()) / "engine.log"
    script = f"import sys; sys.path.insert(0, {str(engine)!r}); import logging, time, update; " \
             f"logging.basicConfig(filename={str(logfile)!r}, level=logging.INFO); " \
             "update.stop_on_sigterm(); print('ready', flush=True); time.sleep(30)"
    parent = subprocess.Popen([sys.executable, "-c", script], stdout=subprocess.PIPE)
    parent.stdout.readline()
    parent.send_signal(signal.SIGTERM)
    parent.wait(timeout=5)
    parent.stdout.close()
    assert "stopped" in logfile.read_text()


def test_pages_read_before_the_helper_ran_out_of_time_are_kept():
    # A book that hits the time limit after hours of reading must not lose the pages already read.
    tool = Path(tempfile.mkdtemp()) / "helper"
    tool.write_text('#!/bin/sh\necho \'{"page": 1, "text": "read before the limit"}\'\n'
                    'printf \'{"page": 2, "te\'\nexec sleep 30\n')
    tool.chmod(0o755)
    saved = ocr.OCR_TOOL, ocr.BOOK_TIMEOUT_S, ocr.page_count
    ocr.OCR_TOOL, ocr.BOOK_TIMEOUT_S, ocr.page_count = str(tool), 1, lambda pdf: 0
    try:
        ocr.recognise(Path("book.pdf"), [])
        raise AssertionError("the helper was not stopped at the limit")
    except ocr.CutShort as e:
        assert e.pages == {1: "read before the limit"}
    finally:
        ocr.OCR_TOOL, ocr.BOOK_TIMEOUT_S, ocr.page_count = saved


def test_pages_read_before_the_helper_gave_up_are_kept():
    # The helper ends itself when a page gets no answer from the system; what it read stays.
    tool = Path(tempfile.mkdtemp()) / "helper"
    tool.write_text('#!/bin/sh\necho \'{"page": 1, "text": "read before it gave up"}\'\n'
                    'echo "page 2: no answer" >&2\nexit 3\n')
    tool.chmod(0o755)
    saved = ocr.OCR_TOOL, ocr.page_count
    ocr.OCR_TOOL, ocr.page_count = str(tool), lambda pdf: 0
    try:
        ocr.recognise(Path("book.pdf"), [])
        raise AssertionError("a helper that gave up was taken for one that finished")
    except ocr.CutShort as e:
        assert e.pages == {1: "read before it gave up"}
        assert "page 2: no answer" in str(e)
    finally:
        ocr.OCR_TOOL, ocr.page_count = saved


def test_a_line_separator_inside_a_page_does_not_lose_the_page():
    # The helper leaves U+2028 unescaped in its JSON; only a newline ends one of its lines.
    out = '{"page": 1, "text": "first\u2028second"}\n{"page": 2, "text": "next"}\n'.encode()
    assert ocr.helper_pages(out) == {1: "first\u2028second", 2: "next"}


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


def _index_with_vectors(path: Path, stamps: dict) -> "sqlite3.Connection":
    """An index with one page per book, each page described by a vector."""
    import build_index
    con = build_index.connect(path)
    con.executescript(build_index.SCHEMA)
    con.execute(f"PRAGMA user_version = {build_index.SCHEMA_VERSION}")
    for book, stamp in stamps.items():
        con.execute("INSERT INTO books(id, key, text_stamp) VALUES(?, ?, ?)", (book, f"book{book}", stamp))
        build_index.insert_pages(con, book, [{"src": "pdf", "page": 1, "text": f"text of book {book}"}])
        con.execute("INSERT INTO vectors VALUES(?, ?)", (book << build_index.PAGE_BITS, b"v"))
        con.execute("INSERT INTO embedded VALUES(?, ?, 'bge-m3')", (book, stamp))
    con.commit()
    return con


def test_a_full_rebuild_keeps_the_vectors_of_books_whose_text_did_not_change():
    # Describing a large library takes hours: a rebuild must not throw that away, nor keep a changed book's.
    import build_index
    folder = Path(tempfile.mkdtemp())
    _index_with_vectors(folder / "old.db", {1: "same", 2: "before"}).close()
    new = build_index.connect(folder / "new.db")
    new.executescript(build_index.SCHEMA)
    new.execute(f"PRAGMA user_version = {build_index.SCHEMA_VERSION}")
    new.executemany("INSERT INTO books(id, key, text_stamp) VALUES(?, ?, ?)", [(1, "book1", "same"), (2, "book2", "after")])
    build_index.carry_vectors(new, folder / "old.db")
    assert [r[0] for r in new.execute("SELECT book FROM embedded")] == [1]
    assert [r[0] >> build_index.PAGE_BITS for r in new.execute("SELECT id FROM vectors")] == [1]


def test_reindexing_a_book_drops_the_vectors_of_its_old_pages():
    # Page ids are reused when a book's text changes: an old vector would describe the wrong page.
    import build_index
    con = _index_with_vectors(Path(tempfile.mkdtemp()) / "index.db", {1: "a", 2: "b"})
    build_index.delete_pages(con, 1)
    assert [r[0] >> build_index.PAGE_BITS for r in con.execute("SELECT id FROM vectors")] == [2]
    # The app trusts a book's embedded row: while it stays, the app keeps searching the old vectors.
    assert [r[0] for r in con.execute("SELECT book FROM embedded")] == [2]


def test_filing_several_books_keeps_their_tags_and_drops_the_auto_mark():
    # Books dragged onto a topic are written in one locked rewrite; their tags must survive the move.
    import set_topic
    topics = {"a": {"topic": "Old", "tags": ["x"], "auto": True}, "b": {"topic": "Old", "tags": []},
              "c": {"topic": "Other", "tags": ["y"]}}
    filed = set_topic.filed(topics, "New", ["a", "b", "d"])
    assert filed == {"a": {"topic": "New", "tags": ["x"]}, "b": {"topic": "New", "tags": []},
                     "c": {"topic": "Other", "tags": ["y"]}, "d": {"topic": "New", "tags": []}}
    assert topics["a"]["topic"] == "Old"

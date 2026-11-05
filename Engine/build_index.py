"""Keep the library index (SQLite FTS5) in step with the inventory, the topics and the text cache.

Incremental: a book is rewritten only when its cached text, its files or its topic changed, so adding
ten books to a library of fifty thousand costs ten books. --full rebuilds from scratch into a new
file and points to it (see config.POINTER), which is also what happens when the schema version changes.

Schema 3:
- books: one row per book. Its id is fixed for as long as the book stays in the library.
- pages: one row per page, id = book_id << PAGE_BITS | n. The book of any matching page is therefore
  rowid >> PAGE_BITS, with no lookup: counting matches per book only decodes the FTS doclist. For
  "the" (166.507 pages) selecting rowids took 0.07s where grouping by a book_id column took 0.58s.
  Text is stored raw-deflate compressed in pages.z.
- pages_fts: external-content FTS5 over the view pages_text, which inflates z through unz(). Every
  connection that reads page text or snippets must register unz(). The index holds fold(text)
  (textfold.py); snippets re-tokenize the unfolded text, which has the same token positions, so
  deletes must pass fold(unz(z)) to remove exactly what was inserted.
"""
import json
import os
import sqlite3
import sys
import time
import zlib
from pathlib import Path

from config import (
    APP_SUPPORT,
    INVENTORY,
    METADATA,
    ROOT,
    TOPICS,
    UNSORTED,
    current_db,
    new_db_path,
    point_to,
)
from extract import cache_path
from metadata import with_metadata
from textfold import fold

SCHEMA_VERSION = 3  # 3: text folded before indexing (textfold.py)
PAGE_BITS = 17
MAX_PAGES = 1 << PAGE_BITS
PDF_TEXT_ENOUGH = 200  # chars on a PDF page before its md duplicate is dropped
COMMIT_EVERY = 50  # books per transaction; readers see progress as it is committed
DEFLATE_LEVEL = 6
TOKENIZE = "tokenize='unicode61 remove_diacritics 2'"
META_COLS = "title, author, topic, tags, key"
META_FIELDS = ("title", "author", "topic", "tags", "auto_topic", "files", "md", "folder",
               "extra_folders", "images")

SCHEMA = f"""
CREATE TABLE books(id INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT UNIQUE NOT NULL,
    title TEXT, author TEXT, topic TEXT, tags TEXT, auto_topic INTEGER,
    files TEXT, md TEXT, folder TEXT, extra_folders TEXT, images INTEGER,
    pages INTEGER, added REAL, text_stamp TEXT);
CREATE VIRTUAL TABLE meta_fts USING fts5({META_COLS}, content='books', content_rowid='id', {TOKENIZE});
CREATE TRIGGER books_ai AFTER INSERT ON books BEGIN
    INSERT INTO meta_fts(rowid, {META_COLS})
    VALUES (new.id, fold(new.title), fold(new.author), fold(new.topic), fold(new.tags), fold(new.key));
END;
CREATE TRIGGER books_ad AFTER DELETE ON books BEGIN
    INSERT INTO meta_fts(meta_fts, rowid, {META_COLS})
    VALUES ('delete', old.id, fold(old.title), fold(old.author), fold(old.topic), fold(old.tags), fold(old.key));
END;
CREATE TRIGGER books_au AFTER UPDATE OF {META_COLS} ON books BEGIN
    INSERT INTO meta_fts(meta_fts, rowid, {META_COLS})
    VALUES ('delete', old.id, fold(old.title), fold(old.author), fold(old.topic), fold(old.tags), fold(old.key));
    INSERT INTO meta_fts(rowid, {META_COLS})
    VALUES (new.id, fold(new.title), fold(new.author), fold(new.topic), fold(new.tags), fold(new.key));
END;
CREATE TABLE pages(id INTEGER PRIMARY KEY, src TEXT, page INTEGER, images TEXT, z BLOB);
CREATE VIEW pages_text AS SELECT id, unz(z) AS text FROM pages;
CREATE VIRTUAL TABLE pages_fts USING fts5(text, content='pages_text', content_rowid='id', {TOKENIZE}, prefix='3');
CREATE TABLE info(name TEXT PRIMARY KEY, value);
"""


def deflate(text: str) -> bytes:
    c = zlib.compressobj(DEFLATE_LEVEL, zlib.DEFLATED, -15)
    return c.compress(text.encode("utf-8")) + c.flush()


def unz(blob: bytes | None) -> str | None:
    return None if blob is None else zlib.decompress(blob, -15).decode("utf-8")


def connect(path: Path) -> sqlite3.Connection:
    con = sqlite3.connect(path)
    con.create_function("unz", 1, unz, deterministic=True)
    con.create_function("fold", 1, fold, deterministic=True)
    con.execute("PRAGMA journal_mode=WAL")
    return con


def page_range(book_id: int) -> tuple[int, int]:
    lo = book_id << PAGE_BITS
    return lo, lo | (MAX_PAGES - 1)


def dedupe(rows: list) -> list:
    """One copy of each page's text, preferring the PDF's (its page numbers are the real ones).

    md chunks are dropped for a page only when the PDF page holds at least half as much text: md
    without page markers files everything under one page, and a PDF with only a text cover must not
    hide that OCR text. EPUB/txt chapters are dropped when the PDF has at least half their text,
    since their numbers are chapters, not pages.
    """
    pdf_len = {r["page"]: len(r["text"]) for r in rows if r["src"] == "pdf"}
    md_len: dict = {}
    for r in rows:
        if r["src"] == "md":
            md_len[r["page"]] = md_len.get(r["page"], 0) + len(r["text"])
    covered = {p for p, n in md_len.items() if pdf_len.get(p, 0) >= max(PDF_TEXT_ENOUGH, n / 2)}
    chapters = sum(len(r["text"]) for r in rows if r["src"] in ("epub", "txt"))
    drop_chapters = chapters and sum(pdf_len.values()) >= chapters / 2
    pdf = {r["page"]: dict(r, images=list(r.get("images", []))) for r in rows if r["src"] == "pdf"}
    kept = []
    for r in rows:
        if r["src"] == "md" and r["page"] in covered:
            pdf[r["page"]]["images"].extend(r.get("images", []))
        elif r["src"] in ("epub", "txt") and drop_chapters:
            continue
        elif r["src"] != "pdf":
            kept.append(r)
    return sorted(kept + list(pdf.values()), key=lambda r: (r["page"], r["src"]))


def text_stamp(book: dict) -> str:
    try:
        st = cache_path(book).stat()
    except OSError:
        return "none"
    return f"{st.st_size}:{st.st_mtime_ns}"


def book_meta(book: dict, topic: dict) -> tuple:
    return (book["title"], book["author"], topic.get("topic", UNSORTED), ", ".join(topic.get("tags", [])),
            int(topic.get("auto", not topic)), json.dumps(book["files"], ensure_ascii=False),
            json.dumps(book["md"], ensure_ascii=False), book["folder"],
            json.dumps(book.get("extra_folders", []), ensure_ascii=False), book["images"])


def first_seen(book: dict) -> float:
    """When the book's files arrived on this disk: their earliest status-change time."""
    times = []
    for rel in book["files"] + book["md"]:
        try:
            times.append(os.stat(ROOT / rel).st_ctime)
        except OSError:
            pass
    return min(times, default=time.time())


def load_pages(book: dict) -> list:
    cache = cache_path(book)
    if not cache.exists():
        return []
    rows = dedupe([json.loads(line) for line in cache.read_text(encoding="utf-8").splitlines() if line])
    if len(rows) > MAX_PAGES:
        print(f"{book['key']}: {len(rows)} pages, keeping the first {MAX_PAGES}", file=sys.stderr)
    return rows[:MAX_PAGES]


def delete_pages(con: sqlite3.Connection, book_id: int) -> None:
    lo, hi = page_range(book_id)
    con.execute("INSERT INTO pages_fts(pages_fts, rowid, text) "
                "SELECT 'delete', id, fold(unz(z)) FROM pages WHERE id BETWEEN ? AND ?", (lo, hi))
    con.execute("DELETE FROM pages WHERE id BETWEEN ? AND ?", (lo, hi))


def insert_pages(con: sqlite3.Connection, book_id: int, rows: list) -> None:
    lo, _ = page_range(book_id)
    for n, r in enumerate(rows):
        images = r.get("images") or []
        con.execute("INSERT INTO pages(id, src, page, images, z) VALUES(?,?,?,?,?)",
                    (lo + n, r["src"], r["page"], json.dumps(images, ensure_ascii=False) if images else None,
                     deflate(r["text"])))
        con.execute("INSERT INTO pages_fts(rowid, text) VALUES(?,?)", (lo + n, fold(r["text"])))


def add_book(con: sqlite3.Connection, book: dict, meta: tuple, stamp: str, keep: tuple | None) -> None:
    """keep: (id, added) the book had in the previous index file, so a rebuild does not renumber it."""
    rows = load_pages(book)
    book_id, added = keep or (None, first_seen(book))
    cur = con.execute(f"INSERT INTO books(id, key, {', '.join(META_FIELDS)}, pages, added, text_stamp) "
                      f"VALUES(?, ?{', ?' * len(META_FIELDS)}, ?, ?, ?)",
                      (book_id, book["key"], *meta, len(rows), added, stamp))
    insert_pages(con, cur.lastrowid, rows)


def update_meta(con: sqlite3.Connection, book_id: int, meta: tuple) -> None:
    sets = ", ".join(f"{f} = ?" for f in META_FIELDS)
    con.execute(f"UPDATE books SET {sets} WHERE id = ?", (*meta, book_id))


def reindex_text(con: sqlite3.Connection, book_id: int, book: dict, stamp: str) -> None:
    rows = load_pages(book)
    delete_pages(con, book_id)
    insert_pages(con, book_id, rows)
    con.execute("UPDATE books SET pages = ?, text_stamp = ? WHERE id = ?", (len(rows), stamp, book_id))


def remove_book(con: sqlite3.Connection, book_id: int) -> None:
    delete_pages(con, book_id)
    con.execute("DELETE FROM books WHERE id = ?", (book_id,))


def sync(con: sqlite3.Connection, inv: list, topics: dict, keep: dict | None = None) -> int:
    """Bring the index in line with the inventory; returns how many books were written."""
    keep = keep or {}
    select = f"SELECT key, id, text_stamp, {', '.join(META_FIELDS)} FROM books"
    known = {r[0]: (r[1], r[2], tuple(r[3:])) for r in con.execute(select)}
    changed = 0
    for book in inv:
        meta = book_meta(book, topics.get(book["key"], {}))
        stamp = text_stamp(book)
        row = known.pop(book["key"], None)
        if row is None:
            add_book(con, book, meta, stamp, keep.get(book["key"]))
        elif row[1] != stamp or row[2] != meta:
            if row[2] != meta:
                update_meta(con, row[0], meta)
            if row[1] != stamp:
                reindex_text(con, row[0], book, stamp)
        else:
            continue
        changed += 1
        if changed % COMMIT_EVERY == 0:
            con.commit()
    for book_id, _, _ in known.values():
        remove_book(con, book_id)
        changed += 1
    con.execute("INSERT OR REPLACE INTO info VALUES('updated', ?)", (time.time(),))
    con.execute("INSERT OR REPLACE INTO info VALUES('library', ?)", (str(ROOT),))
    con.commit()
    return changed


def current_version(path: Path | None) -> int:
    if path is None or not path.exists():
        return 0
    with sqlite3.connect(f"file:{path}?mode=ro", uri=True) as con:
        return con.execute("PRAGMA user_version").fetchone()[0]


def previous_ids(path: Path | None) -> dict:
    """{key: (id, added)} from an earlier index file, of any schema that has them."""
    if path is None or not path.exists():
        return {}
    try:
        with sqlite3.connect(f"file:{path}?mode=ro", uri=True) as con:
            return {k: (i, a) for k, i, a in con.execute("SELECT key, id, added FROM books")}
    except sqlite3.Error:
        return {}


def build_fresh(inv: list, topics: dict, previous: Path | None) -> int:
    keep = previous_ids(previous)
    # Books added since the last full build keep their ids too; new ones are numbered after them.
    inv = sorted(inv, key=lambda b: (b["key"] not in keep, keep.get(b["key"], (0,))[0]))
    db = new_db_path()
    for leftover in (db, Path(f"{db}-wal"), Path(f"{db}-shm")):
        leftover.unlink(missing_ok=True)
    con = connect(db)
    con.executescript(SCHEMA)
    con.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
    changed = sync(con, inv, topics, keep)
    con.execute("INSERT INTO pages_fts(pages_fts) VALUES('optimize')")
    con.commit()
    con.close()
    point_to(db)
    return changed


def main(full: bool = False) -> int:
    found = json.loads(METADATA.read_text()) if METADATA.exists() else {}
    inv = with_metadata(json.loads(INVENTORY.read_text()), found)
    topics = json.loads(TOPICS.read_text()) if TOPICS.exists() else {}
    APP_SUPPORT.mkdir(parents=True, exist_ok=True)
    started = time.time()
    db = current_db()
    if full or current_version(db) != SCHEMA_VERSION:
        changed = build_fresh(inv, topics, db)
        how = "rebuilt"
    else:
        con = connect(db)
        changed = sync(con, inv, topics)
        con.close()
        how = "updated"
    print(f"index {how}: {changed} books written in {time.time() - started:.1f}s", file=sys.stderr)
    return changed


if __name__ == "__main__":
    main("--full" in sys.argv)
    sys.exit(0)

"""Give newly added books a topic, from the way the library is already organised.

For each book in the inventory that has no entry in topics.json, in this order:
1. the topic most of the other books in its folder have;
2. the folder's name, when the folder holds several books (a category, not one book's own folder);
3. the topics of the books it resembles: the most distinctive words of its title and first pages
   (tf-idf against the current index) become an OR query, and the best matches vote, weighted by rank;
4. the first subject in its metadata (Calibre's tags, an EPUB's subjects), so a library that is
   already sorted is not given new topics by whoever catalogued the files.
Otherwise it stays unsorted. Results are stored with "auto": true so they can be told apart from
hand-checked ones, and are never overwritten once set. A Calibre library's folders are authors, so
steps 1 and 2 are skipped there.
"""
import fcntl
import json
import math
import re
import sqlite3
import sys
from collections import Counter

from config import (
    APP_SUPPORT,
    INVENTORY,
    LEGACY_UNSORTED,
    METADATA,
    ROOT,
    TOPICS,
    TOPICS_LOCK,
    UNSORTED,
    current_db,
)
from extract import cache_path
from ranking import ranked_books
from textfold import fold

SAMPLE_PAGES = 40
QUERY_WORDS = 14
NEIGHBOURS = 15
TITLE_WEIGHT = 3
MIN_WORD = 4
MIN_FOLDER_BOOKS = 3
WORD = re.compile(rf"[^\W\d_]{{{MIN_WORD},}}")


def index_form(text: str) -> str:
    """Words as the index stores them: folded, lower case, final sigma as σ (fts5vocab terms)."""
    return fold(text).lower().replace("ς", "σ")


def book_words(book: dict) -> Counter:
    words = Counter()
    for w in WORD.findall(index_form(book["title"])):
        words[w] += TITLE_WEIGHT
    cache = cache_path(book)
    if cache.exists():
        with cache.open(encoding="utf-8") as f:
            for i, line in enumerate(f):
                if i >= SAMPLE_PAGES:
                    break
                words.update(WORD.findall(index_form(json.loads(line)["text"])))
    return words


def distinctive(con: sqlite3.Connection, words: Counter, total_pages: int) -> list:
    """Top words by tf-idf; words unknown to the index or present on most pages are dropped."""
    candidates = [w for w, _ in words.most_common(300)]
    if not candidates:
        return []
    df = dict(con.execute(f"SELECT term, doc FROM temp.vocab WHERE term IN ({','.join('?' * len(candidates))})",
                          candidates).fetchall())
    scored = [(words[w] * math.log(total_pages / df[w]), w) for w in candidates
              if w in df and df[w] < total_pages * 0.2]
    return [w for _, w in sorted(scored, reverse=True)[:QUERY_WORDS]]


def vote(con: sqlite3.Connection, terms: list, exclude: int | None = None) -> dict:
    query = " OR ".join(f'"{t}"' for t in terms)
    ranked = [r for r in ranked_books(con, query) if r[0] != exclude][:NEIGHBOURS]
    ids = [r[0] for r in ranked]
    info = {r[0]: (r[1], r[2]) for r in con.execute(
        f"SELECT id, topic, tags FROM books WHERE id IN ({','.join('?' * len(ids))})", ids)}
    topics, tags = Counter(), Counter()
    for rank, bid in enumerate(ids):
        topic, tag_str = info[bid]
        if topic in (UNSORTED, LEGACY_UNSORTED):
            continue
        topics[topic] += 1 / (rank + 1)
        tags.update(t.strip() for t in tag_str.split(",") if t.strip())
    if not topics:
        return unsorted()
    return {"topic": topics.most_common(1)[0][0], "tags": [t for t, _ in tags.most_common(3)], "auto": True}


def unsorted() -> dict:
    return {"topic": UNSORTED, "tags": [], "auto": True}


def top_folder(key: str) -> str | None:
    parts = key.split("/")
    return parts[0] if len(parts) > 1 else None


def folder_topics(keys: list) -> dict:
    """{key: folder name} for books inside a top-level folder that holds MIN_FOLDER_BOOKS or more."""
    sizes = Counter(f for f in map(top_folder, keys) if f)
    return {k: top_folder(k) for k in keys if top_folder(k) and sizes[top_folder(k)] >= MIN_FOLDER_BOOKS}


def sibling_topics(inventory: list, topics: dict) -> dict:
    """{folder: the topic most of its books already have}."""
    votes: dict = {}
    for book in inventory:
        folder, topic = top_folder(book["key"]), topics.get(book["key"], {}).get("topic", UNSORTED)
        if folder and topic not in (UNSORTED, LEGACY_UNSORTED):
            votes.setdefault(folder, Counter())[topic] += 1
    return {f: c.most_common(1)[0][0] for f, c in votes.items()}


def from_folders(inventory: list, topics: dict) -> dict:
    """Topics for new books from their folders (steps 1 and 2 above)."""
    new = [b for b in inventory if b["key"] not in topics]
    calibre = (ROOT / "metadata.db").exists()
    siblings = {} if calibre else sibling_topics(inventory, topics)
    named = {} if calibre else folder_topics([b["key"] for b in inventory])
    result = {}
    for book in new:
        topic = siblings.get(top_folder(book["key"])) or named.get(book["key"])
        if topic:
            result[book["key"]] = {"topic": topic, "tags": [], "auto": True}
    return result


def from_subjects(book: dict, found: dict, unsorted_name: str) -> dict:
    subjects = (found.get(book["key"]) or {}).get("subjects") or []
    if not subjects:
        return {"topic": unsorted_name, "tags": [], "auto": True}
    return {"topic": subjects[0], "tags": subjects[1:4], "auto": True}


def classify(inventory: list, topics: dict, found: dict) -> dict:
    result = from_folders(inventory, topics)
    new = [b for b in inventory if b["key"] not in topics and b["key"] not in result]
    # A library sorted by an earlier version keeps its word for unsorted books.
    unsorted_name = LEGACY_UNSORTED if any(t.get("topic") == LEGACY_UNSORTED for t in topics.values()) else UNSORTED
    db = current_db()
    if not new or db is None or not db.exists():
        return {**result, **{b["key"]: from_subjects(b, found, unsorted_name) for b in new}}
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    con.execute("CREATE VIRTUAL TABLE temp.vocab USING fts5vocab(main, pages_fts, row)")
    total = con.execute("SELECT count(*) FROM pages").fetchone()[0] or 1
    for book in new:
        terms = distinctive(con, book_words(book), total)
        voted = vote(con, terms) if terms else unsorted()
        result[book["key"]] = voted if voted["topic"] != UNSORTED else from_subjects(book, found, unsorted_name)
    con.close()
    return result


def main() -> int:
    inventory = json.loads(INVENTORY.read_text())
    topics = json.loads(TOPICS.read_text()) if TOPICS.exists() else {}
    found = json.loads(METADATA.read_text()) if METADATA.exists() else {}
    added = classify(inventory, topics, found)
    if added:
        APP_SUPPORT.mkdir(parents=True, exist_ok=True)
        with open(TOPICS_LOCK, "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            # Re-read: a topic may have been set by hand while the classifier was working.
            current = json.loads(TOPICS.read_text()) if TOPICS.exists() else {}
            merged = {**{k: v for k, v in added.items() if k not in current}, **current}
            tmp = TOPICS.with_suffix(".tmp")
            tmp.write_text(json.dumps(merged, ensure_ascii=False, indent=1))
            tmp.replace(TOPICS)
    for key, t in added.items():
        print(f"new: {key} → {t['topic'] or 'unsorted'}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

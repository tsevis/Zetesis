"""Give newly added books a topic by asking the existing index which books they resemble.

For each book in the inventory that has no entry in topics.json, the most distinctive words of its
title and first pages (tf-idf against the current index) become an OR query; the topics of the best
matching books vote, weighted by rank. Results are stored with "auto": true so they can be told
apart from hand-checked ones, and are never overwritten once set.
"""
import fcntl
import json
import math
import re
import sqlite3
import sys
from collections import Counter

from config import APP_SUPPORT, INVENTORY, TOPICS, TOPICS_LOCK, current_db
from extract import cache_path
from ranking import ranked_books
from textfold import fold

SAMPLE_PAGES = 40
QUERY_WORDS = 14
NEIGHBOURS = 15
TITLE_WEIGHT = 3
MIN_WORD = 4
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
    if not ranked:
        return {"topic": "Άλλα", "tags": [], "auto": True}
    ids = [r[0] for r in ranked]
    info = {r[0]: (r[1], r[2]) for r in con.execute(
        f"SELECT id, topic, tags FROM books WHERE id IN ({','.join('?' * len(ids))})", ids)}
    topics, tags = Counter(), Counter()
    for rank, bid in enumerate(ids):
        topic, tag_str = info[bid]
        topics[topic] += 1 / (rank + 1)
        tags.update(t.strip() for t in tag_str.split(",") if t.strip())
    return {"topic": topics.most_common(1)[0][0], "tags": [t for t, _ in tags.most_common(3)], "auto": True}


def classify(inventory: list, topics: dict) -> dict:
    new = [b for b in inventory if b["key"] not in topics]
    db = current_db()
    if not new or db is None or not db.exists():
        return {}
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    con.execute("CREATE VIRTUAL TABLE temp.vocab USING fts5vocab(main, pages_fts, row)")
    total = con.execute("SELECT count(*) FROM pages").fetchone()[0] or 1
    result = {}
    for book in new:
        terms = distinctive(con, book_words(book), total)
        result[book["key"]] = vote(con, terms) if terms else {"topic": "Άλλα", "tags": [], "auto": True}
    con.close()
    return result


def main() -> int:
    inventory = json.loads(INVENTORY.read_text())
    topics = json.loads(TOPICS.read_text()) if TOPICS.exists() else {}
    added = classify(inventory, topics)
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
        print(f"νέο: {key} → {t['topic']}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

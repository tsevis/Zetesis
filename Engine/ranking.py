"""Book-level ranking from matching page rowids. The app ranks with the same formula (Ranking.swift).

A book is scored like a BM25 document whose term frequency is its number of matching pages and whose
length is its number of pages: many hits help, with diminishing returns, and a hit in a short book
counts for more than one in a long one. Only rowids are read, so no per-page score is computed.
"""
import sqlite3
from collections import Counter

from build_index import PAGE_BITS

K1 = 1.2
B = 0.75


def book_score(hits: int, pages: int, avg_pages: float) -> float:
    norm = K1 * (1 - B + B * pages / max(avg_pages, 1.0))
    return hits * (K1 + 1) / (hits + norm)


def ranked_books(con: sqlite3.Connection, query: str) -> list[tuple[int, int, float]]:
    """(book_id, matching pages, score) for every book with a match, best first."""
    hits = Counter(rowid >> PAGE_BITS for (rowid,) in
                   con.execute("SELECT rowid FROM pages_fts WHERE pages_fts MATCH ?", [query]))
    if not hits:
        return []
    avg = con.execute("SELECT avg(pages) FROM books").fetchone()[0] or 1.0
    pages = dict(con.execute("SELECT id, pages FROM books"))
    scored = [(b, n, book_score(n, pages.get(b, 1), avg)) for b, n in hits.items()]
    return sorted(scored, key=lambda r: (-r[2], -r[1]))

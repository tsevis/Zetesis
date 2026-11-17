"""Describe every page by meaning, for search by meaning: one bge-m3 vector per page, in the index.

The model runs in llama.cpp's llama-server, started here on a private port for the length of the
step. The app finds the server and the model and passes them as ZETESIS_LLAMA_SERVER and
ZETESIS_EMBED_MODEL; the step runs only when ZETESIS_SEMANTIC=1 (switched on in Settings).

Books are described newest first, one transaction each, and a book is described again only when its
text changes (build_index drops its vectors then). Between books the work stops whenever
should_stop() says so (the library changed): new books are indexed first. A book becomes searchable by
meaning as soon as it is done; the app picks up new vectors at its next search.
"""
import json
import logging
import secrets
import socket
import sqlite3
import struct
import subprocess
import time
import urllib.error
import urllib.request
from array import array
from collections.abc import Callable
from pathlib import Path

from build_index import connect, page_range, unz
from config import EMBED_MODEL, LLAMA_SERVER, current_db

MODEL_NAME = "bge-m3"
DIMS = 1024
# Only the start of a long page is read: the bake-off measured 11 pages a second at this length.
EMBED_CHARS = 2000
MIN_CHARS = 50  # shorter pages (blank, plates, a running head) get no vector
BATCH = 32
CONTEXT = 32768
SLOTS = 8
START_TIMEOUT_S = 120
REQUEST_TIMEOUT_S = 300
STOP_CHECK_S = 60
# Names the server so one left behind by a killed engine (its parent is then launchd) can be stopped.
ALIAS = "zetesis-engine"

log = logging.getLogger("library-update")


class ServerError(RuntimeError):
    pass


def quantize(vector: list[float]) -> bytes:
    """Unit-length vector → float32 scale + int8 components, so that component ≈ int8 × scale."""
    norm = sum(x * x for x in vector) ** 0.5 or 1.0
    unit = [x / norm for x in vector]
    peak = max(abs(x) for x in unit) or 1.0
    scale = peak / 127
    return struct.pack("<f", scale) + array("b", (round(x / scale) for x in unit)).tobytes()


class Server:
    """llama-server with the model, on 127.0.0.1 behind a random key, for the life of a `with` block."""

    def __init__(self, binary: str, model: str) -> None:
        self.binary, self.model = binary, model
        self.key = secrets.token_hex(16)
        self.port = free_port()
        self.process: subprocess.Popen | None = None

    def __enter__(self) -> "Server":  # noqa: PYI034 (typing.Self needs Python 3.11; the engine runs on 3.10)
        self.process = subprocess.Popen(
            [self.binary, "-m", self.model, "--embedding", "--pooling", "cls", "--host", "127.0.0.1",
             "--port", str(self.port), "--api-key", self.key, "-c", str(CONTEXT), "-np", str(SLOTS),
             "-b", "8192", "-ub", "8192", "-ngl", "99", "--alias", ALIAS],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + START_TIMEOUT_S
        while time.time() < deadline:
            if self.process.poll() is not None:
                raise ServerError(f"llama-server exited with code {self.process.returncode}")
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{self.port}/health", timeout=2)
                return self
            except (urllib.error.URLError, OSError):
                time.sleep(0.5)
        self.__exit__()
        raise ServerError(f"llama-server did not start within {START_TIMEOUT_S}s")

    def __exit__(self, *_: object) -> None:
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()

    def alive(self) -> bool:
        return self.process is not None and self.process.poll() is None

    def embed(self, texts: list[str]) -> list[list[float]]:
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/v1/embeddings", data=json.dumps({"input": texts}).encode(),
            headers={"Content-Type": "application/json", "Authorization": f"Bearer {self.key}"})
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_S) as response:
            data = json.load(response)["data"]
        vectors = [d["embedding"] for d in sorted(data, key=lambda d: d["index"])]
        if len(vectors) != len(texts) or any(len(v) != DIMS for v in vectors):
            raise ServerError("llama-server returned vectors of the wrong number or size")
        return vectors


def stop_orphans() -> None:
    """Stops a server left behind by an engine that was killed (its parent is then launchd)."""
    subprocess.run(["/usr/bin/pkill", "-P", "1", "-f", f"alias {ALIAS}"], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def waiting(con: sqlite3.Connection) -> list[tuple[int, str]]:
    """(book, text_stamp) of the books not yet described with their current text, newest first."""
    return con.execute("SELECT b.id, b.text_stamp FROM books b LEFT JOIN embedded e ON e.book = b.id "
                       "WHERE e.book IS NULL OR e.stamp != b.text_stamp OR e.model != ? "
                       "ORDER BY b.added DESC", (MODEL_NAME,)).fetchall()


def page_texts(con: sqlite3.Connection, book: int) -> list[tuple[int, str]]:
    lo, hi = page_range(book)
    rows = con.execute("SELECT id, z FROM pages WHERE id BETWEEN ? AND ?", (lo, hi))
    texts = ((i, " ".join((unz(z) or "").split())) for i, z in rows)
    return [(i, t[:EMBED_CHARS]) for i, t in texts if len(t) >= MIN_CHARS]


def describe_book(con: sqlite3.Connection, server: Server, book: int, stamp: str) -> None:
    pages = page_texts(con, book)
    rows = []
    for k in range(0, len(pages), BATCH):
        chunk = pages[k:k + BATCH]
        rows += [(i, quantize(v)) for (i, _), v in zip(chunk, server.embed([t for _, t in chunk]))]
    lo, hi = page_range(book)
    with con:
        con.execute("DELETE FROM vectors WHERE id BETWEEN ? AND ?", (lo, hi))
        con.executemany("INSERT INTO vectors VALUES(?, ?)", rows)
        con.execute("INSERT OR REPLACE INTO embedded VALUES(?, ?, ?)", (book, stamp, MODEL_NAME))


def main(should_stop: Callable[[], bool]) -> None:
    """Describes the waiting books. A book the server fails on is skipped (and tried again next run);
    a server that will not start or that dies raises ServerError, which the update reports."""
    stop_orphans()
    db = current_db()
    if not (LLAMA_SERVER and EMBED_MODEL and db and Path(EMBED_MODEL).is_file()):
        log.info("search by meaning: llama-server or the %s model is missing, skipped", MODEL_NAME)
        return
    con = connect(db)
    try:
        books = waiting(con)
        if not books:
            return
        log.info("search by meaning: %d books to describe", len(books))
        with Server(LLAMA_SERVER, EMBED_MODEL) as server:
            checked = time.time()
            for done, (book, stamp) in enumerate(books, 1):
                print(f"@meaning {done - 1} {len(books)}", flush=True)
                try:
                    describe_book(con, server, book, stamp)
                except (urllib.error.URLError, ServerError, ValueError, KeyError) as error:
                    if not server.alive():
                        raise ServerError(f"llama-server stopped while describing book {book}") from error
                    log.warning("search by meaning: book %d skipped: %s", book, error)
                if time.time() - checked >= STOP_CHECK_S:
                    checked = time.time()
                    if should_stop():
                        log.info("search by meaning: the library changed, stopping after %d books", done)
                        return
            print(f"@meaning {len(books)} {len(books)}", flush=True)
    finally:
        con.close()

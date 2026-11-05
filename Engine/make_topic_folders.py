"""Keep <library>/_Topics/<topic>/ (or an existing _ΘΕΜΑΤΑ) filled with symlinks to each book's files and md folder. Nothing is moved.

Incremental: only links that should not be there are removed and only missing ones are made, so an
update touches the links of the books that changed, not every link. The folder must only ever
contain symlinks; anything else stops the run.
"""
import json
import os
import sys
import unicodedata
from pathlib import Path

from config import INVENTORY, ROOT, TOPIC_FOLDER, TOPICS, UNSORTED

OUT = TOPIC_FOLDER
UNSORTED_FOLDER = "Unsorted"


def safe_name(s: str) -> str:
    """A single file name: no separators or control characters, and no leading dot ("..", hidden files)."""
    name = "".join(c for c in s.replace("/", "-").replace(":", "-") if unicodedata.category(c)[0] != "C")
    return name.strip().lstrip(".").strip() or "untitled"


def wanted_links(inv: list, topics: dict) -> dict:
    """{link path: relative target} for every book."""
    links = {}
    for book in inv:
        topic_dir = OUT / safe_name(topics.get(book["key"], {}).get("topic", UNSORTED) or UNSORTED_FOLDER)
        for rel in book["files"] + ([book["folder"]] if book["folder"] else []):
            link = topic_dir / safe_name(Path(rel).name)
            links.setdefault(link, os.path.relpath(ROOT / rel, topic_dir))
    return links


def nfc(path: Path) -> str:
    """HFS+ hands back decomposed names (NFD); compare paths in one normal form."""
    return unicodedata.normalize("NFC", str(path))


def existing_links() -> dict | None:
    """{link path: target} now in OUT, or None when OUT holds anything but symlinks and folders."""
    found = {}
    for dirpath, dirnames, files in os.walk(OUT):
        for name in files + [d for d in dirnames if (Path(dirpath) / d).is_symlink()]:
            if name.startswith("."):  # Finder's .DS_Store
                continue
            path = Path(dirpath) / name
            if not path.is_symlink():
                return None
            found[path] = os.readlink(path)
        dirnames[:] = [d for d in dirnames if not (Path(dirpath) / d).is_symlink()]
    return found


def main() -> int:
    inv = json.loads(INVENTORY.read_text())
    topics = json.loads(TOPICS.read_text()) if TOPICS.exists() else {}
    have = existing_links() if OUT.exists() else {}
    if have is None:
        print(f"{OUT} holds real files, not only links: left alone.", file=sys.stderr)
        return 1
    want = wanted_links(inv, topics)
    wanted_by_name = {nfc(p): t for p, t in want.items()}
    have_by_name = {nfc(p): t for p, t in have.items()}
    stale = [p for p, target in have.items() if wanted_by_name.get(nfc(p)) != target]
    for path in stale:
        path.unlink()
    stale_names = {nfc(p) for p in stale}
    for path, target in want.items():
        if nfc(path) not in have_by_name or nfc(path) in stale_names:
            path.parent.mkdir(parents=True, exist_ok=True)
            try:
                path.symlink_to(target)
            except FileExistsError:  # a name differing only in case or accents, on this volume
                continue
    for folder in OUT.iterdir() if OUT.exists() else []:
        if folder.is_dir() and not folder.is_symlink() and not any(folder.iterdir()):
            folder.rmdir()
    if stale or len(want) != len(have):
        print(f"topic folders: {len(stale)} links removed, {len(want) - len(have) + len(stale)} added", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""Build inventory.json: one entry per book, linking PDF/EPUB and its md/json/image folder."""
import json
import os
import re
import sys
import time
from pathlib import Path

from config import DATA, INVENTORY, ROOT, SKIP_DIRS

DIR_CACHE = DATA / "dirs.json"
BOOK_EXT = {".pdf", ".epub", ".djvu", ".txt"}
IMG_EXT = {".jpg", ".jpeg", ".png", ".gif", ".webp"}
FRESH_S = 3


def parse_title_author(stem):
    s = re.sub(r"\s*\(\)\s*$", "", stem).strip()
    m = re.match(r"^(.*?)\s*\(([^()]*)\)\s*$", s)
    if m and m.group(1):
        return m.group(1).strip(), m.group(2).strip()
    return s, ""


def norm(s):
    s = s.replace("()", "")
    return re.sub(r"[^0-9a-z\u0370-\u03ff\u4e00-\u9fff\u3040-\u30ff]", "", s.lower())


def is_main_md(rel_dir, name):
    return "machine" not in rel_dir.parts and name.lower() != "readme.md"


def find_owner(md_dir, file_index):
    """Return key of the book file this md folder belongs to (deepest match first), or None."""
    parts = md_dir.parts
    for i in range(len(parts), 0, -1):
        anc = Path(*parts[:i])
        full, title = norm(anc.name), norm(parse_title_author(anc.name)[0])
        for key, fnorm, ftitle in file_index.get(str(anc.parent), []):
            if fnorm == full or (len(title) >= 6 and ftitle == title):
                return key
    return None


def merge_orphans(books):
    """Attach md-only folders to a book file with the same title anywhere in the tree."""
    with_files = [(k, norm(Path(k).name), norm(parse_title_author(Path(k).name)[0]))
                  for k, b in books.items() if b["files"]]
    merged = {k: dict(v, md=list(v["md"])) for k, v in books.items()}
    for key, b in books.items():
        if b["files"]:
            continue
        name = re.sub(r"-[0-9a-f]{12}-(verified|balanced)$", "", Path(key).name)
        full, title = norm(name), norm(parse_title_author(name)[0])
        target = next((k for k, f, t in with_files if f == full or (len(title) >= 6 and t == title)), None)
        target = target or next((k for k, f, t in with_files if len(full) >= 15 and t.startswith(full)), None)
        if target:
            merged[target]["md"].extend(b["md"])
            merged[target]["folder"] = merged[target]["folder"] or b["folder"]
            merged[target].setdefault("extra_folders", []).append(b["folder"])
            del merged[key]
    return merged


def wanted(name: str) -> bool:
    ext = os.path.splitext(name)[1].lower()
    return ext in BOOK_EXT or ext == ".md"


def list_dir(path: str) -> dict:
    subdirs, files, images = [], [], 0
    with os.scandir(path) as it:
        for e in it:
            if e.name.startswith("."):
                continue
            if e.is_dir(follow_symlinks=False):
                subdirs.append(e.name)
            elif wanted(e.name):
                files.append(e.name)
            elif os.path.splitext(e.name)[1].lower() in IMG_EXT:
                images += 1
    return {"d": subdirs, "f": files, "i": images}


def walk(cache: dict) -> dict:
    """{rel dir: {"d": subdirs, "f": book/md files, "i": image count}} for the whole library.

    A folder is listed again only when its modification time changed (that happens whenever an
    entry inside it is added, removed or renamed); otherwise the cached listing is reused. At tens
    of thousands of books this turns a scan of every file name into a stat of every folder.
    """
    found, stack = {}, [""]
    while stack:
        rel = stack.pop()
        path = os.path.join(ROOT, rel) if rel else str(ROOT)
        try:
            mtime = os.stat(path).st_mtime_ns
        except OSError:
            continue
        entry = cache.get(rel)
        if entry is None or entry["m"] != mtime:
            entry = dict(list_dir(path), m=mtime)
        found[rel] = entry
        # Reverse-sorted onto the stack, so folders are visited in sorted pre-order like os.walk.
        stack.extend(os.path.join(rel, d) if rel else d for d in sorted(entry["d"], reverse=True)
                     if d not in SKIP_DIRS and not d.endswith("_jp2"))
    return found


def load_dir_cache() -> dict:
    try:
        return json.loads(DIR_CACHE.read_text())
    except (OSError, ValueError):
        return {}


def scan():
    books = {}
    md_files = []
    dirs = walk(load_dir_cache())
    for rel, entry in dirs.items():
        rel_dir = Path(rel)
        for name in sorted(entry["f"]):
            ext = os.path.splitext(name)[1].lower()
            path = os.path.join(rel, name) if rel else name
            if ext in BOOK_EXT and not (ext == ".txt" and rel):
                key = str(rel_dir / os.path.splitext(name)[0])
                books.setdefault(key, {"files": [], "md": [], "folder": None})
                books[key]["files"].append(path)
            elif ext == ".md" and rel and is_main_md(rel_dir, name):
                md_files.append((rel_dir, path))
    file_index = {}
    for key in books:
        k = Path(key)
        file_index.setdefault(str(k.parent), []).append((key, norm(k.name), norm(parse_title_author(k.name)[0])))
    for rel_dir, rel in md_files:
        owner = find_owner(rel_dir, file_index) or str(rel_dir)
        b = books.setdefault(owner, {"files": [], "md": [], "folder": None})
        b["md"].append(rel)
        if b["folder"] is None or len(str(rel_dir)) < len(b["folder"]):
            b["folder"] = str(rel_dir)
    books = merge_orphans(books)
    result = []
    for key in sorted(books):
        b = books[key]
        title, author = parse_title_author(Path(key).name)
        folder = b["folder"]
        result.append({
            "id": len(result), "key": key, "title": title, "author": author,
            "files": sorted(b["files"]), "md": sorted(b["md"]),
            "folder": folder, "extra_folders": b.get("extra_folders", []),
            "images": dirs[folder]["i"] if folder in dirs else 0,
        })
    save_dir_cache(dirs)
    return result


def save_dir_cache(dirs: dict) -> None:
    """Folders changed in the last FRESH_S are stored without their time, so they are listed again:
    HFS+ keeps whole seconds, so a file added later in the same second would leave the time as is."""
    DATA.mkdir(exist_ok=True)
    fresh = time.time_ns() - FRESH_S * 1_000_000_000
    stored = {rel: e if e["m"] < fresh else dict(e, m=-1) for rel, e in dirs.items()}
    tmp = DIR_CACHE.with_suffix(".tmp")
    tmp.write_text(json.dumps(stored, ensure_ascii=False))
    tmp.replace(DIR_CACHE)


if __name__ == "__main__":
    inv = scan()
    INVENTORY.write_text(json.dumps(inv, ensure_ascii=False, indent=1))
    print(len(inv), "books;", sum(1 for b in inv if b["md"]), "with md;",
          sum(1 for b in inv if not b["files"]), "md-only", file=sys.stderr)

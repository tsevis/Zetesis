"""Where the library, its working data and its index live. Every engine script reads its paths here.

The library folder comes from PINAKES_LIBRARY (the app sets it); its working data (inventory, topics,
text cache) sits inside it in _SEARCH, and the index on the internal disk, one file per library.
"""
import hashlib
import json
import os
import sys
import time
from pathlib import Path

DATA_DIRNAME = "_SEARCH"
TOPICS_DIRNAME = "_ΘΕΜΑΤΑ"
APP_SUPPORT = Path.home() / "Library" / "Application Support" / "Pinakes"
LOG = Path.home() / "Library" / "Logs" / "Pinakes.log"


def _library() -> Path:
    raw = os.environ.get("PINAKES_LIBRARY")
    if not raw:
        sys.exit("PINAKES_LIBRARY is not set: the path of the library folder is needed.")
    return Path(raw).expanduser().resolve()


ROOT = _library()
DATA = ROOT / DATA_DIRNAME
CACHE = DATA / "text"
INVENTORY = DATA / "inventory.json"
TOPICS = DATA / "topics.json"
LIBRARY_ID = hashlib.sha1(str(ROOT).encode()).hexdigest()[:12]
LOCK = APP_SUPPORT / f"{LIBRARY_ID}.lock"
# Held only while topics.json is read and rewritten, so setting a topic never waits for an update.
TOPICS_LOCK = APP_SUPPORT / f"{LIBRARY_ID}.topics.lock"
# The pointer names the index file in use. A full rebuild writes a new file and moves the pointer,
# so a reader holding the old file open never shares its WAL with the new one.
POINTER = APP_SUPPORT / f"{LIBRARY_ID}.json"
SKIP_DIRS = {DATA_DIRNAME, TOPICS_DIRNAME}


def current_db() -> Path | None:
    if os.environ.get("PINAKES_DB"):
        return Path(os.environ["PINAKES_DB"])
    try:
        return APP_SUPPORT / json.loads(POINTER.read_text())["db"]
    except (OSError, ValueError, KeyError):
        return None


def new_db_path() -> Path:
    if os.environ.get("PINAKES_DB"):
        return Path(os.environ["PINAKES_DB"])
    return APP_SUPPORT / f"{LIBRARY_ID}-{time.strftime('%Y%m%d-%H%M%S')}.db"


def point_to(db: Path) -> None:
    """Make db the index in use and delete older ones (open readers keep their file until they close)."""
    if os.environ.get("PINAKES_DB"):
        return
    tmp = POINTER.with_suffix(".tmp")
    tmp.write_text(json.dumps({"db": db.name, "library": str(ROOT)}, ensure_ascii=False))
    tmp.replace(POINTER)
    for old in APP_SUPPORT.glob(f"{LIBRARY_ID}-*.db*"):
        if not old.name.startswith(db.name):
            old.unlink(missing_ok=True)

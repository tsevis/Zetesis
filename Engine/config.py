"""Where the library, its working data and its index live. Every engine script reads its paths here.

The library folder comes from ZETESIS_LIBRARY (the app sets it). Nothing is written into the library:
its working data (inventory, topics, text cache) and its index live on the internal disk, one folder
and one index file per library, so read-only folders and network shares work too. A library that
already keeps its data in a _SEARCH folder inside it goes on using that folder.

Optional, from the app: ZETESIS_TOPIC_FOLDERS=1 keeps a folder of topic symlinks inside the library,
and ZETESIS_OCR names the text-recognition helper for scanned books.
"""
import hashlib
import json
import os
import sys
import time
from pathlib import Path

LEGACY_DATA_DIRNAME = "_SEARCH"
LEGACY_TOPICS_DIRNAME = "_ΘΕΜΑΤΑ"
TOPICS_DIRNAME = "_Topics"
APP_SUPPORT = Path.home() / "Library" / "Application Support" / "Zetesis"
LOG = Path.home() / "Library" / "Logs" / "Zetesis.log"


def _library() -> Path:
    raw = os.environ.get("ZETESIS_LIBRARY")
    if not raw:
        sys.exit("ZETESIS_LIBRARY is not set: the path of the library folder is needed.")
    return Path(raw).expanduser().resolve()


ROOT = _library()
LIBRARY_ID = hashlib.sha1(str(ROOT).encode()).hexdigest()[:12]
_legacy_data = ROOT / LEGACY_DATA_DIRNAME
DATA = _legacy_data if _legacy_data.is_dir() else APP_SUPPORT / LIBRARY_ID
CACHE = DATA / "text"
INVENTORY = DATA / "inventory.json"
TOPICS = DATA / "topics.json"
METADATA = DATA / "metadata.json"
_legacy_topics = ROOT / LEGACY_TOPICS_DIRNAME
TOPIC_FOLDER = _legacy_topics if _legacy_topics.is_dir() else ROOT / TOPICS_DIRNAME
# Unset: kept only where the folder already exists.
TOPIC_FOLDERS = os.environ.get("ZETESIS_TOPIC_FOLDERS", "1" if TOPIC_FOLDER.is_dir() else "0") == "1"
OCR_TOOL = os.environ.get("ZETESIS_OCR") or None
LOCK = APP_SUPPORT / f"{LIBRARY_ID}.lock"
# Held only while topics.json is read and rewritten, so setting a topic never waits for an update.
TOPICS_LOCK = APP_SUPPORT / f"{LIBRARY_ID}.topics.lock"
# The pointer names the index file in use. A full rebuild writes a new file and moves the pointer,
# so a reader holding the old file open never shares its WAL with the new one.
POINTER = APP_SUPPORT / f"{LIBRARY_ID}.json"
# Books without a topic; the app shows them under its own word for "unsorted".
UNSORTED = ""
# What earlier versions called unsorted books; still read as unsorted.
LEGACY_UNSORTED = "Άλλα"
SKIP_DIRS = {LEGACY_DATA_DIRNAME, LEGACY_TOPICS_DIRNAME, TOPICS_DIRNAME}


def current_db() -> Path | None:
    if os.environ.get("ZETESIS_DB"):
        return Path(os.environ["ZETESIS_DB"])
    try:
        return APP_SUPPORT / json.loads(POINTER.read_text())["db"]
    except (OSError, ValueError, KeyError):
        return None


def new_db_path() -> Path:
    if os.environ.get("ZETESIS_DB"):
        return Path(os.environ["ZETESIS_DB"])
    return APP_SUPPORT / f"{LIBRARY_ID}-{time.strftime('%Y%m%d-%H%M%S')}.db"


def point_to(db: Path) -> None:
    """Make db the index in use and delete older ones (open readers keep their file until they close)."""
    if os.environ.get("ZETESIS_DB"):
        return
    tmp = POINTER.with_suffix(".tmp")
    tmp.write_text(json.dumps({"db": db.name, "library": str(ROOT)}, ensure_ascii=False))
    tmp.replace(POINTER)
    for old in APP_SUPPORT.glob(f"{LIBRARY_ID}-*.db*"):
        if not old.name.startswith(db.name):
            old.unlink(missing_ok=True)

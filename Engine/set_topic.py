"""Set a book's topic by hand:  python3 set_topic.py BOOK_KEY TOPIC

The entry loses its "auto" mark, so it is treated as checked. topics.json is rewritten atomically
under the topics lock, which the classifier holds only while it writes; the next update re-indexes
the book.
"""
import fcntl
import json
import sys

from config import APP_SUPPORT, TOPICS, TOPICS_LOCK


def main() -> int:
    if len(sys.argv) != 3 or not sys.argv[2].strip():
        print(__doc__, file=sys.stderr)
        return 2
    key, topic = sys.argv[1], sys.argv[2].strip()
    APP_SUPPORT.mkdir(parents=True, exist_ok=True)
    with open(TOPICS_LOCK, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        topics = json.loads(TOPICS.read_text()) if TOPICS.exists() else {}
        entry = {"topic": topic, "tags": topics.get(key, {}).get("tags", [])}
        merged = {**topics, key: entry}
        tmp = TOPICS.with_suffix(".tmp")
        tmp.write_text(json.dumps(merged, ensure_ascii=False, indent=1))
        tmp.replace(TOPICS)
    return 0


if __name__ == "__main__":
    sys.exit(main())

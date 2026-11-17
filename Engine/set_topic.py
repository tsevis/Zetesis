"""File books under a topic by hand:  python3 set_topic.py TOPIC BOOK_KEY [BOOK_KEY ...]

The entries lose their "auto" mark, so they are treated as checked. topics.json is rewritten once,
atomically, under the topics lock, which the classifier holds only while it writes; the next update
re-indexes the books.
"""
import fcntl
import json
import sys

from config import APP_SUPPORT, TOPICS, TOPICS_LOCK


def filed(topics: dict, topic: str, keys: list[str]) -> dict:
    """topics with every key under topic, keeping each book's tags."""
    moved = {key: {"topic": topic, "tags": topics.get(key, {}).get("tags", [])} for key in keys}
    return {**topics, **moved}


def main() -> int:
    if len(sys.argv) < 3 or not sys.argv[1].strip():
        print(__doc__, file=sys.stderr)
        return 2
    topic, keys = sys.argv[1].strip(), sys.argv[2:]
    APP_SUPPORT.mkdir(parents=True, exist_ok=True)
    with open(TOPICS_LOCK, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        topics = json.loads(TOPICS.read_text()) if TOPICS.exists() else {}
        tmp = TOPICS.with_suffix(".tmp")
        tmp.write_text(json.dumps(filed(topics, topic, keys), ensure_ascii=False, indent=1))
        tmp.replace(TOPICS)
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""Bring the index up to date with the library folder. Safe to run any time, as often as you like.

Waits until nothing in the folder has changed for SETTLE_S seconds (so a copy in progress is not
indexed half-way), then: inventory → extract new/changed books → classify new books → rebuild the
index → refresh _ΘΕΜΑΤΑ. Does nothing when the folder is unchanged. Repeats if books were added
while it was working. Only one copy runs at a time.

Started by the app when it opens and when the folder changes, and by the LaunchAgent (install_watcher.py)
while the app is closed. --now skips the wait; --full rebuilds the index from scratch.
"""
import fcntl
import json
import logging
import os
import sys
import time

import build_index
import classify_new
import extract
import inventory
import make_topic_folders
from config import APP_SUPPORT, DATA, INVENTORY, LOCK, LOG, ROOT, SKIP_DIRS

SETTLE_S = 90
POLL_S = 15
MAX_WAIT_S = 3 * 3600
MAX_ROUNDS = 5
RECENT_S = 24 * 3600
IGNORED = SKIP_DIRS | {".DS_Store"}

log = logging.getLogger("library-update")


def last_change() -> float:
    """Newest change anywhere in the library: every folder's times, and the files of folders that
    changed within RECENT_S (a file being copied into an existing folder changes only itself)."""
    newest, stack, recent = 0.0, [str(ROOT)], time.time() - RECENT_S
    while stack:
        path = stack.pop()
        try:
            st = os.stat(path)
            with os.scandir(path) as it:
                entries = list(it)
        except OSError:
            continue
        newest = max(newest, st.st_mtime, st.st_ctime)
        look_at_files = max(st.st_mtime, st.st_ctime) >= recent
        for e in entries:
            if e.name in IGNORED or e.name.startswith(".") or e.name.endswith("_jp2"):
                continue
            if e.is_dir(follow_symlinks=False):
                stack.append(e.path)
            elif look_at_files:
                try:
                    fst = e.stat(follow_symlinks=False)
                except OSError:
                    continue
                newest = max(newest, fst.st_mtime, fst.st_ctime)
    return newest


def wait_until_quiet(settle: float) -> bool:
    start = time.time()
    while time.time() - start < MAX_WAIT_S:
        idle = time.time() - last_change()
        if idle >= settle:
            return True
        phase("waiting")
        log.info("ο φάκελος αλλάζει ακόμα, περιμένω (%ds)", int(settle - idle))
        time.sleep(min(POLL_S, settle - idle + 1))
    return False


def refresh_inventory() -> bool:
    """Rescan the folder; True when the set of books or their files changed."""
    old = json.loads(INVENTORY.read_text()) if INVENTORY.exists() else []
    new = inventory.scan()
    tmp = INVENTORY.with_suffix(".tmp")
    tmp.write_text(json.dumps(new, ensure_ascii=False, indent=1))
    tmp.replace(INVENTORY)
    strip = [{k: v for k, v in b.items() if k != "id"} for b in old]
    return strip != [{k: v for k, v in b.items() if k != "id"} for b in new]


def phase(name: str) -> None:
    """A line the app reads to show what the update is doing."""
    print(f"@phase {name}", flush=True)


def one_round(full: bool) -> bool:
    """One pass; True if anything was re-indexed."""
    phase("inventory")
    changed = refresh_inventory()
    phase("text")
    extracted = extract.main()
    if changed or extracted:
        phase("classify")
        classify_new.main()
    # Always run: it is cheap when nothing changed, and it is what picks up topics set by hand.
    phase("index")
    written = build_index.main(full)
    if written:
        phase("topics")
        make_topic_folders.main()
    return bool(written)


def main() -> int:
    APP_SUPPORT.mkdir(parents=True, exist_ok=True)
    DATA.mkdir(exist_ok=True)
    full = "--full" in sys.argv
    settle = 0 if "--now" in sys.argv else SETTLE_S
    logging.basicConfig(filename=LOG, level=logging.INFO, format="%(asctime)s %(message)s")
    log.addHandler(logging.StreamHandler(sys.stderr))
    if not ROOT.exists():
        log.info("ο δίσκος της βιβλιοθήκης δεν είναι συνδεδεμένος")
        return 0
    with open(LOCK, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log.info("τρέχει ήδη άλλη ενημέρωση")
            print("@busy", flush=True)
            return 0
        for _ in range(MAX_ROUNDS):
            if not wait_until_quiet(settle):
                log.info("ο φάκελος δεν ησύχασε μέσα σε %d ώρες, σταματώ", MAX_WAIT_S // 3600)
                return 1
            started = time.time()
            try:
                did = one_round(full)
                full = False
            except Exception:
                log.exception("η ενημέρωση απέτυχε")
                return 1
            log.info("ευρετήριο ενημερώθηκε" if did else "καμία αλλαγή")
            print(f"@done {int(did)}", flush=True)
            if last_change() < started:
                return 0
            log.info("προστέθηκαν αρχεία κατά την ενημέρωση, ξανά")
    return 0


if __name__ == "__main__":
    sys.exit(main())

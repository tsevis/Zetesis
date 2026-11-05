"""Install (or with --remove, uninstall) the LaunchAgent that keeps the index up to date.

It runs update.py whenever the library folder changes, plus once an hour to catch changes deeper
inside existing book folders, while the app is closed. One agent per library.
"""
import os
import plistlib
import subprocess
import sys
from pathlib import Path

from config import LIBRARY_ID, LOG, ROOT

HERE = Path(__file__).resolve().parent
LABEL = f"com.tsevis.zetesis.update.{LIBRARY_ID}"
PLIST = Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"
HOURLY_S = 3600
THROTTLE_S = 60
TOOL_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"


def launchctl(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["launchctl", *args], capture_output=True, text=True, check=False)


def remove() -> None:
    launchctl("bootout", f"gui/{os.getuid()}/{LABEL}")
    PLIST.unlink(missing_ok=True)
    print("Background updates switched off.")


def passed_on() -> dict:
    """The app's choices (topic folders, the OCR helper) as the app set them for this run."""
    return {k: os.environ[k] for k in ("ZETESIS_TOPIC_FOLDERS", "ZETESIS_OCR") if os.environ.get(k)}


def install() -> int:
    agent = {
        "Label": LABEL,
        "ProgramArguments": [sys.executable, str(HERE / "update.py")],
        "WorkingDirectory": str(HERE),
        "WatchPaths": [str(ROOT)],
        "StartInterval": HOURLY_S,
        "ThrottleInterval": THROTTLE_S,
        "EnvironmentVariables": {"PATH": TOOL_PATH, "ZETESIS_LIBRARY": str(ROOT), **passed_on()},
        "StandardOutPath": str(LOG),
        "StandardErrorPath": str(LOG),
        "Nice": 10,
        "LowPriorityIO": True,
        "ProcessType": "Background",
    }
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    launchctl("bootout", f"gui/{os.getuid()}/{LABEL}")
    PLIST.write_bytes(plistlib.dumps(agent))
    r = launchctl("bootstrap", f"gui/{os.getuid()}", str(PLIST))
    if r.returncode != 0:
        print(f"Could not switch on background updates: {r.stderr.strip()}", file=sys.stderr)
        return 1
    print(f"Background updates switched on. Log: {LOG}")
    return 0


if __name__ == "__main__":
    if "--remove" in sys.argv:
        remove()
        sys.exit(0)
    sys.exit(install())

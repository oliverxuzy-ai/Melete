"""Where the app keeps its files.

Sessions live under ~/Library/Application Support/SpeechPractice so the packaged
app and the dev server share one history. Override with SPEECH_DATA_DIR.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

APP_NAME = "SpeechPractice"
FROZEN = bool(getattr(sys, "frozen", False))  # True inside the PyInstaller bundle

_env = os.environ.get("SPEECH_DATA_DIR")
DATA_DIR = Path(_env).expanduser() if _env else Path.home() / "Library" / "Application Support" / APP_NAME
SESSIONS_DIR = DATA_DIR / "sessions"
PRACTICES_DIR = DATA_DIR / "practices"
ACTIVITY_DIR = DATA_DIR / "activity"
LOG_DIR = DATA_DIR / "logs"

# Bundled resources (static/) sit next to the source in dev and in sys._MEIPASS when frozen.
RESOURCE_DIR = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))
STATIC_DIR = RESOURCE_DIR / "static"


def ensure_dirs() -> None:
    SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
    PRACTICES_DIR.mkdir(parents=True, exist_ok=True)
    ACTIVITY_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)

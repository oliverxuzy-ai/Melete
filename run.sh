#!/bin/sh
# Start the recorder at http://127.0.0.1:8765 (first run downloads the Whisper model, ~500 MB).
cd "$(dirname "$0")"
[ -d .venv ] || { uv venv .venv -p 3.12 && uv pip install -p .venv/bin/python -r requirements.txt; }
exec .venv/bin/python server.py

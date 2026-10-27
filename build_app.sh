#!/bin/sh
# Build dist/SpeechPractice.app. Add --install to copy it into /Applications.
set -e
cd "$(dirname "$0")"
[ -d .venv ] || { uv venv .venv -p 3.12 && uv pip install -p .venv/bin/python -r requirements.txt; }
.venv/bin/python -c "import webview, PyInstaller" 2>/dev/null || uv pip install -p .venv/bin/python pywebview pyinstaller
.venv/bin/pyinstaller --noconfirm --clean SpeechPractice.spec
echo "built: $(pwd)/dist/SpeechPractice.app"
if [ "$1" = "--install" ]; then
  dest=/Applications
  [ -w "$dest" ] || dest="$HOME/Applications"
  mkdir -p "$dest"
  rm -rf "$dest/SpeechPractice.app"
  cp -R dist/SpeechPractice.app "$dest/"
  echo "installed: $dest/SpeechPractice.app"
fi

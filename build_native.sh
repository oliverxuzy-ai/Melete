#!/bin/sh
# Build the native SwiftUI app with the Python analysis server bundled inside.
#   ./build_native.sh            build dist/Melete.app
#   ./build_native.sh --install  also copy it to /Applications, replacing SpeechPractice.app (refuses while the app is running)
#   SKIP_SERVER=1 ./build_native.sh   reuse the existing dist/SpeechPracticeServer sidecar
set -e
cd "$(dirname "$0")"
APP=dist/Melete.app

if [ -z "$SKIP_SERVER" ] || [ ! -d dist/SpeechPracticeServer ]; then
  [ -d .venv ] || { uv venv .venv -p 3.12 && uv pip install -p .venv/bin/python -r requirements.txt; }
  .venv/bin/python -m PyInstaller --noconfirm --clean SpeechPracticeServer.spec
fi

swift build -c release --package-path native

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp native/.build/release/SpeechPractice "$APP/Contents/MacOS/SpeechPractice"
cp native/Resources/Info.plist "$APP/Contents/Info.plist"
cp build_assets/Assets.car build_assets/AppIcon.icns "$APP/Contents/Resources/"
cp -R native/Resources/*.lproj "$APP/Contents/Resources/"   # permission prompts in Chinese and English
cp -R dist/SpeechPracticeServer "$APP/Contents/Resources/server"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
# Ad-hoc signing names the build by its hash, so macOS took every update for a new app and asked
# for the microphone again. Re-sign the app itself with a requirement that names its bundle id,
# so a permission given to one version holds for the next.
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")
codesign --force --sign - -r="designated => identifier \"$BUNDLE_ID\"" "$APP" >/dev/null 2>&1 || true
echo "built: $(pwd)/$APP"

if [ "$1" = "--install" ]; then
  if pgrep -f "(SpeechPractice|Melete).app/Contents/MacOS/SpeechPractice" >/dev/null; then
    echo "App is running; quit it and run again with --install"; exit 1
  fi
  dest=/Applications; [ -w "$dest" ] || dest="$HOME/Applications"; mkdir -p "$dest"
  # Same bundle id as the old SpeechPractice.app, so settings and history carry over; replace it.
  rm -rf "$dest/SpeechPractice.app" "$dest/Melete.app" && cp -R "$APP" "$dest/" && echo "installed: $dest/Melete.app"
fi

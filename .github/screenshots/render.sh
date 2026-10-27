#!/bin/sh
# Draw the README screenshots from made-up practice data (see seed.py): English and Chinese,
# light and dark. Needs macOS, dist/Melete.app and the .venv that build_native.sh makes.
# The Screenshots workflow runs this on a clean GitHub runner. Locally it uses its own data
# folder and port, so your history is not touched.
#
#   .github/screenshots/render.sh                        writes .github/assets/screenshots/{en,zh}/
#   PAGES=window-home,history .github/screenshots/render.sh   other pages (names in RenderHarness.swift)
set -eu
cd "$(dirname "$0")/../.."

OUT=.github/assets/screenshots
PAGES=${PAGES:-window-home,window-shadow-min,window-retell-listen-min,window-verdict-min}
PORT=${SCREENSHOT_PORT:-8790}
APP=dist/Melete.app/Contents/MacOS/SpeechPractice
PY=.venv/bin/python
WORK=$(mktemp -d "${TMPDIR:-/tmp}/melete-screens.XXXXXX")

if [ ! -x "$APP" ] || [ ! -x "$PY" ]; then
  echo "Build the app first: ./build_native.sh" >&2
  exit 1
fi

server=""
cleanup() { if [ -n "$server" ]; then kill "$server" 2>/dev/null || true; fi; }
trap cleanup EXIT

for lang in en zh; do
  data="$WORK/data-$lang"
  mkdir -p "$data"

  echo "== $lang: analysis server on port $PORT, data in $data"
  SPEECH_DATA_DIR="$data" SPEECH_NO_DAILY=1 PORT="$PORT" "$PY" server.py >"$WORK/server-$lang.log" 2>&1 &
  server=$!
  if ! SPEECH_DATA_DIR="$data" SPEECH_SERVER_URL="http://127.0.0.1:$PORT" \
      "$PY" .github/screenshots/seed.py --lang "$lang" --audio "$WORK/audio"; then
    tail -n 60 "$WORK/server-$lang.log" >&2
    exit 1
  fi

  echo "== $lang: rendering $PAGES"
  # perl's alarm is a timeout that macOS has without coreutils.
  SPEECH_SERVER_URL="http://127.0.0.1:$PORT" RENDER_ONLY="$PAGES" \
    perl -e 'alarm shift; exec @ARGV or die "exec: $!"' 600 "$APP" --render "$WORK/png-$lang" --lang "$lang"
  kill "$server"
  wait "$server" 2>/dev/null || true
  server=""

  # The harness draws at 2x. The hero shot keeps 1600 px; the rest are shown half width.
  rm -rf "${OUT:?}/$lang"
  mkdir -p "$OUT/$lang"
  for f in "$WORK/png-$lang"/*.png; do
    name=$(basename "$f")
    case "$name" in
      window-home-light.png | window-home-dark.png) size=1600 ;;
      *) size=1040 ;;
    esac
    sips -Z "$size" "$f" --out "$OUT/$lang/$name" >/dev/null
  done
done

if command -v pngquant >/dev/null 2>&1; then
  pngquant --force --skip-if-larger --quality 85-98 --ext .png "$OUT"/*/*.png || true
fi
ls -l "$OUT"/en "$OUT"/zh

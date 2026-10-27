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
app=""
cleanup() {
  if [ -n "$app" ]; then kill "$app" 2>/dev/null || true; fi
  if [ -n "$server" ]; then kill "$server" 2>/dev/null || true; fi
}
trap cleanup EXIT

# Draws one language. Each run gets its own home folder, so the app's preferences
# (and anything a previous run left in them) stay out of it.
render() {
  lang=$1
  home="$WORK/home-$lang"
  mkdir -p "$home"
  CFFIXED_USER_HOME="$home" SPEECH_SERVER_URL="http://127.0.0.1:$PORT" RENDER_ONLY="$PAGES" \
    "$APP" --render "$WORK/png-$lang" --lang "$lang" >"$WORK/app-$lang.log" 2>&1 &
  app=$!
  waited=0
  while kill -0 "$app" 2>/dev/null; do
    if [ "$waited" -ge 300 ]; then
      echo "The app did not finish within 300 s. Its log:" >&2
      cat "$WORK/app-$lang.log" >&2
      echo "What it asked the server:" >&2
      tail -n 40 "$WORK/server-$lang.log" >&2
      echo "Where it is stuck:" >&2
      sample "$app" 2 -file "$WORK/sample-$lang.txt" >/dev/null 2>&1 || true
      sed -n '1,250p' "$WORK/sample-$lang.txt" >&2 || true
      return 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
  status=0
  wait "$app" || status=$?
  app=""
  cat "$WORK/app-$lang.log"
  return "$status"
}

failed=""
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
  ok=true
  render "$lang" || ok=false
  kill "$server"
  wait "$server" 2>/dev/null || true
  server=""
  if [ "$ok" = false ]; then
    failed="$failed $lang"
    continue   # keep this language's old screenshots; still draw the other one
  fi

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
ls -l "$OUT"/*/
if [ -n "$failed" ]; then
  echo "Could not draw:$failed" >&2
  exit 1
fi

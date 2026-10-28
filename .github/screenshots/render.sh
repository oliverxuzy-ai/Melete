#!/bin/sh
# Draw the README screenshots from made-up practice data (see seed.py): English and Chinese,
# in the light look (SCHEMES=light,dark draws dark as well). Needs macOS, dist/Melete.app
# and the .venv that build_native.sh makes.
# The Screenshots workflow runs this on a clean GitHub runner. Locally it uses its own data
# folder and port, so your history is not touched.
#
#   .github/screenshots/render.sh                        writes .github/assets/screenshots/{en,zh}/
#   PAGES=window-home,history .github/screenshots/render.sh   other pages (names in RenderHarness.swift)
#
# window-shadow-live is a moving picture: 180 frames, joined into an animated WebP
# with img2webp (brew install webp).
set -eu
cd "$(dirname "$0")/../.."

OUT=.github/assets/screenshots
# The README set: Shadowing mid-take as a moving picture, then Today, the Progress tray over
# it, Retell before speaking, and the critique card after today's impromptu take
# (window-verdict-min).
PAGES=${PAGES:-window-shadow-live,window-home-min,window-progress-min,window-retell-min,window-verdict-min}
SCHEMES=${SCHEMES:-light}
PORT=${SCREENSHOT_PORT:-8790}
APP=dist/Melete.app/Contents/MacOS/SpeechPractice
PY=.venv/bin/python
WORK=$(mktemp -d "${TMPDIR:-/tmp}/melete-screens.XXXXXX")

if [ ! -x "$APP" ] || [ ! -x "$PY" ]; then
  echo "Build the app first: ./build_native.sh" >&2
  exit 1
fi
case ",$PAGES," in
  *,window-shadow-live,*)
    if ! command -v img2webp >/dev/null 2>&1; then
      echo "window-shadow-live needs img2webp: brew install webp" >&2
      exit 1
    fi ;;
esac

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
  CFFIXED_USER_HOME="$home" SPEECH_SERVER_URL="http://127.0.0.1:$PORT" RENDER_ONLY="$PAGES" RENDER_SCHEMES="$SCHEMES" \
    "$APP" --render "$WORK/png-$lang" --lang "$lang" >"$WORK/app-$lang.log" 2>&1 &
  app=$!
  waited=0
  while kill -0 "$app" 2>/dev/null; do
    if [ "$waited" -ge 900 ]; then
      echo "The app did not finish within 900 s. Its log:" >&2
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

  ok=true
  if [ "$lang" = zh ]; then
    # Chinese text cascades to Songti SC and Kaiti SC, which macOS downloads on demand.
    # shellcheck disable=SC2046 # one argument per font name
    xcrun swift .github/screenshots/fetch-fonts.swift \
      $(grep -oE '"ST[A-Za-z-]+"' native/Sources/SpeechPractice/Theme.swift | tr -d '"' | sort -u) || ok=false
  fi
  echo "== $lang: rendering $PAGES"
  if [ "$ok" = true ]; then render "$lang" || ok=false; fi
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
  # Moving pictures: a folder of frames each, 12 a second (83 ms), drawn at the size shown.
  # Lossy at quality 92, which takes a change of 2 levels or less for no change. The harness
  # holds such changes back in the frames (FrameHold in RenderHarness.swift), so the halo
  # shows no patch edges; change the two together.
  for frames in "$WORK/png-$lang"/*/; do
    [ -d "$frames" ] || continue
    name=$(basename "$frames")
    # shellcheck disable=SC2046 # one argument per frame, in order
    img2webp -loop 0 -lossy -q 92 -m 6 -d 83 $(ls "$frames"*.png) -o "$OUT/$lang/$name.webp" >/dev/null
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

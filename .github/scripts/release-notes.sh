#!/usr/bin/env bash
# Write the release notes for a new tag to stdout.
#
#   .github/scripts/release-notes.sh <new-tag> [previous-tag]
#
# Lists the commits since the previous release; the first release just says so.
set -euo pipefail

tag=$1
previous=${2:-}
repo=${GITHUB_REPOSITORY:-oliverxuzy-ai/Melete}

cat <<'EOF'
## Install

Download **Melete.dmg**, open it, and drag Melete into Applications. Melete needs macOS 26 or later on Apple Silicon.

Melete is not notarized yet, so the first time you open it macOS says it cannot verify the developer. Open **System Settings → Privacy & Security** and click **Open Anyway**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/Melete.app
```

The first launch downloads the Whisper speech model (about 500 MB). For daily clips, also run `brew install yt-dlp ffmpeg`.

Once installed, Melete offers new versions itself and installs them in one click (**Settings → Updates**).

EOF

if [ -z "$previous" ]; then
  echo "## Changes"
  echo
  echo "First release."
else
  echo "## Changes"
  echo
  changes=$(git log --no-merges --format='- %s (%h)' "$previous..HEAD")
  if [ -n "$changes" ]; then echo "$changes"; else echo "Rebuilt with no code changes."; fi
  echo
  echo "**Full changelog**: https://github.com/$repo/compare/$previous...$tag"
fi

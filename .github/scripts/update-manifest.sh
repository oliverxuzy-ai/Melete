#!/usr/bin/env bash
# Write latest.json, the file the app reads to learn about new versions (Updater.swift).
# It is published with each release, so the app always finds the newest one at
#   https://github.com/<repo>/releases/latest/download/latest.json
#
#   .github/scripts/update-manifest.sh <version> <build> <zip> [previous-tag] > latest.json
#
# The zip's address is where the release job uploads it. Notes are the commit subjects since
# the previous tag; they are left out when there is no history to read (the build job's
# checkout is shallow, so only the release job's manifest has them).
set -euo pipefail

version=$1
build=$2
zip=$3
previous=${4:-}
repo=${GITHUB_REPOSITORY:-oliverxuzy-ai/Melete}

notes=""
if [ -n "$previous" ]; then
  notes=$(git log --no-merges --format='%s' "$previous..HEAD" 2>/dev/null || true)
fi

NOTES=$notes python3 - "$version" "$build" "$zip" "$repo" native/Resources/Info.plist <<'EOF'
import hashlib, json, os, plistlib, re, sys

version, build, zip_path, repo, plist_path = sys.argv[1:6]

# The update banner shows these to the person updating: leave out work they never see
# (docs, CI, chores, tests, build), and drop the "feat:" / "fix:" prefixes.
INTERNAL = re.compile(r"^(docs|ci|chore|test|tests|build|refactor|style)(\([^)]*\))?!?:", re.I)
PREFIX = re.compile(r"^(feat|fix|perf)(\([^)]*\))?!?:\s*", re.I)


def user_notes(text):
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line or INTERNAL.match(line):
            continue
        line = PREFIX.sub("", line)
        out.append(line[:1].upper() + line[1:])
    return out


digest = hashlib.sha256()
with open(zip_path, "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        digest.update(chunk)
with open(plist_path, "rb") as f:
    minimum = plistlib.load(f).get("LSMinimumSystemVersion")
tag = f"v{version}"
manifest = {
    "version": version,
    "build": build,
    "url": f"https://github.com/{repo}/releases/download/{tag}/Melete.zip",
    "sha256": digest.hexdigest(),
    "size": os.path.getsize(zip_path),
    "minimumSystemVersion": minimum,
    "releaseURL": f"https://github.com/{repo}/releases/tag/{tag}",
    "notes": user_notes(os.environ.get("NOTES", "")),
}
json.dump(manifest, sys.stdout, indent=2, ensure_ascii=False)
print()
EOF

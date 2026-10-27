#!/usr/bin/env bash
# Work out the next release version from git tags and commit messages.
#
#   .github/scripts/next-version.sh [auto|patch|minor|major]
#
# Prints key=value lines for $GITHUB_OUTPUT:
#   version   next version, e.g. 2.1.0
#   tag       v2.1.0
#   build     CFBundleVersion: the number of commits on HEAD, so it only goes up
#   previous  latest release tag before this one (empty on the first release)
#   skip      true when HEAD is already released, so there is nothing new to ship
#
# Rules:
#   1. The first release uses CFBundleShortVersionString from native/Resources/Info.plist.
#   2. Raising that version in Info.plist above the latest tag releases exactly that version.
#   3. Otherwise bump the latest vX.Y.Z tag, judged by the commit messages since it:
#        "BREAKING CHANGE", "type!:" or "#major"  -> major
#        "feat:" / "feat(scope):" or "#minor"      -> minor
#        anything else                              -> patch
#      Passing patch, minor or major overrides the commit messages.
set -euo pipefail

bump=${1:-auto}
plist=native/Resources/Info.plist

base=$(python3 -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))["CFBundleShortVersionString"])' "$plist")
build=$(git rev-list --count HEAD)
semver='^v[0-9]+\.[0-9]+\.[0-9]+$'
latest=$(git tag --list 'v*' --sort=-v:refname | grep -E "$semver" | awk 'NR == 1' || true)
released=$(git tag --points-at HEAD --list 'v*' | grep -E "$semver" | awk 'NR == 1' || true)

# true when $1 is a strictly higher version than $2
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]; }

skip=false
if [ -n "$released" ]; then
  skip=true
  version=${released#v}
  reason="HEAD is already released as $released"
elif [ -z "$latest" ]; then
  version=$base
  reason="first release, version from Info.plist"
elif newer "$base" "${latest#v}"; then
  version=$base
  reason="Info.plist was raised to $base"
else
  if [ "$bump" = auto ]; then
    log=$(git log --format=%B "$latest..HEAD")
    if grep -qE '^BREAKING[ -]CHANGE|^[a-zA-Z]+(\([^)]*\))?!:|#major' <<<"$log"; then
      bump="major"
    elif grep -qE '^feat(\([^)]*\))?:|#minor' <<<"$log"; then
      bump="minor"
    else
      bump="patch"
    fi
  fi
  IFS=. read -r major minor patch <<<"${latest#v}"
  case $bump in
    major) version="$((major + 1)).0.0" ;;
    minor) version="$major.$((minor + 1)).0" ;;
    patch) version="$major.$minor.$((patch + 1))" ;;
    *) echo "unknown bump: $bump (use auto, patch, minor or major)" >&2; exit 1 ;;
  esac
  reason="$bump bump from $latest"
fi

echo "next version: $version ($reason)" >&2
echo "version=$version"
echo "tag=v$version"
echo "build=$build"
echo "previous=$latest"
echo "skip=$skip"

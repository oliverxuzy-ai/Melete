#!/bin/sh
# Regenerate the app icon: write build_assets/AppIcon.icon from make_icon.swift, then compile it
# with actool into Assets.car (the layered macOS 26 icon) and AppIcon.icns (the flat fallback).
# Needs Xcode 26. The compiled files are kept here, so build_native.sh does not need Xcode.
#   ./build_assets/make_icon.sh            regenerate the shapes, then compile
#   KEEP_ICON=1 ./build_assets/make_icon.sh   compile AppIcon.icon as it is (after editing it in Icon Composer)
set -e
cd "$(dirname "$0")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [ -z "$KEEP_ICON" ]; then
  swiftc -O make_icon.swift -o "$tmp/make_icon"
  "$tmp/make_icon" .
fi
xcrun actool AppIcon.icon --compile "$tmp" --output-format human-readable-text --errors --warnings \
  --output-partial-info-plist "$tmp/partial.plist" --app-icon AppIcon --include-all-app-icons \
  --enable-on-demand-resources NO --development-region en --target-device mac \
  --minimum-deployment-target 26.0 --platform macosx >"$tmp/actool.log"
if grep -q -i -E "error|warning" "$tmp/actool.log"; then cat "$tmp/actool.log"; fi
cp "$tmp/Assets.car" "$tmp/AppIcon.icns" .
echo "icon compiled: build_assets/Assets.car, build_assets/AppIcon.icns"

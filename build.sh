#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
build_dir="$(mktemp -d /tmp/precision-mouse-build.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
app_dir="$build_dir/PrecisionMouse.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
MACOSX_DEPLOYMENT_TARGET=15.0 xcrun swiftc \
  -module-cache-path "$build_dir/module-cache" \
  "$project_dir/PrecisionMouse.swift" \
  -o "$app_dir/Contents/MacOS/PrecisionMouse"
codesign --force --sign - --identifier local.jackson.precisionmouse \
  --requirements '=designated => identifier "local.jackson.precisionmouse"' "$app_dir"
codesign --verify --deep --strict "$app_dir"
ditto --norsrc --noextattr "$app_dir" "$project_dir/PrecisionMouse.app"
# Finder/iCloud can attach metadata that invalidates bundle verification.
# Remove only these build-artifact metadata attributes, not quarantine/security attributes.
xattr -dr com.apple.FinderInfo "$project_dir/PrecisionMouse.app" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$project_dir/PrecisionMouse.app" 2>/dev/null || true
codesign --verify --deep --strict "$project_dir/PrecisionMouse.app"
print "Built $project_dir/PrecisionMouse.app"
print 'Quit any old helper instance before opening the rebuilt app.'


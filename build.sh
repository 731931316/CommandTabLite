#!/bin/sh
# Builds a local macOS application bundle with the active Xcode toolchain.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
bundle="$project_dir/CommandTabLite.app"
mkdir -p "$bundle/Contents/MacOS"
cp "$project_dir/Info.plist" "$bundle/Contents/Info.plist"
swiftc -O -framework AppKit -framework Carbon -framework ApplicationServices -framework ServiceManagement \
  "$project_dir"/Sources/*.swift -o "$bundle/Contents/MacOS/CommandTabLite"
# SMAppService requires a signed app; ad-hoc signing supports this local build.
codesign --force --sign - "$bundle"
printf 'Built %s\n' "$bundle"

#!/bin/sh
# Builds a local macOS application bundle with the active Xcode toolchain.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
bundle="$project_dir/轻跃.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$project_dir/Info.plist" "$bundle/Contents/Info.plist"
# Bundle the application's own icon; candidate icons continue to come from each running application.
cp "$project_dir/Assets/AppIcon.icns" "$bundle/Contents/Resources/AppIcon.icns"
swiftc -O -framework AppKit -framework Carbon -framework ApplicationServices -framework ServiceManagement \
  "$project_dir"/Sources/*.swift -o "$bundle/Contents/MacOS/CommandTabLite"
# SMAppService requires a signed app; ad-hoc signing supports this local build.
codesign --force --sign - "$bundle"
printf 'Built %s\n' "$bundle"

#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
bundle="$project_dir/dist/Codex Pulse.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$project_dir/dist/module-cache"
for architecture in arm64 x86_64; do
    swiftc "$project_dir/App.swift" -o "$project_dir/dist/CodexPulse-$architecture" \
        -target "$architecture-apple-macos13.0" -swift-version 5 -O \
        -module-cache-path "$project_dir/dist/module-cache" \
        -framework AppKit -framework SwiftUI -framework ServiceManagement -framework UserNotifications
done
lipo -create "$project_dir/dist/CodexPulse-arm64" "$project_dir/dist/CodexPulse-x86_64" \
    -output "$bundle/Contents/MacOS/CodexPulse"
swiftc "$project_dir/Icon.swift" -o "$project_dir/dist/make-icon" \
    -module-cache-path "$project_dir/dist/module-cache" -framework CoreGraphics -framework ImageIO
"$project_dir/dist/make-icon" "$project_dir/dist/AppIcon.iconset"
iconutil -c icns "$project_dir/dist/AppIcon.iconset" -o "$bundle/Contents/Resources/AppIcon.icns"
cp -X "$project_dir/Info.plist" "$bundle/Contents/Info.plist"
cp -X "$project_dir/Localizations.json" "$bundle/Contents/Resources/Localizations.json"
cp -X "$project_dir/USAGE.md" "$bundle/Contents/Resources/USAGE.md"
cp -X "$project_dir/backend.py" "$bundle/Contents/Resources/backend.py"
cp -X "$project_dir/KULLANIM.md" "$bundle/Contents/Resources/KULLANIM.md"
# Desktop may be synced by File Provider, which can add Finder metadata mid-build.
for attempt in 1 2 3; do
    xattr -cr "$bundle"
    if codesign --force --deep --sign - "$bundle"; then break; fi
    if [ "$attempt" = 3 ]; then exit 1; fi
    sleep 1
done
codesign --verify --deep --strict "$bundle"
printf 'Hazır: %s\n' "$bundle"

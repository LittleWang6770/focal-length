#!/bin/zsh
set -eu
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_APP="$TASK_ROOT/build/焦段统计.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources" "$TASK_ROOT/build/module-cache"
zsh "$TASK_ROOT/scripts/build-icon.sh"
cp "$TASK_ROOT/Resources/AppIcon.icns" "$TASK_ROOT/Resources/AppIcon.png" "$TASK_APP/Contents/Resources/"
swiftc -parse-as-library -swift-version 5 -O -target arm64-apple-macosx13.0 \
  -module-cache-path "$TASK_ROOT/build/module-cache" \
  "$TASK_ROOT/Sources/Scanner.swift" "$TASK_ROOT/Sources/FolderAccess.swift" \
  "$TASK_ROOT/Sources/AppModel.swift" "$TASK_ROOT/Sources/Theme.swift" "$TASK_ROOT/Sources/App.swift" \
  -o "$TASK_APP/Contents/MacOS/FocalLength"
cat > "$TASK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>FocalLength</string>
<key>CFBundleIdentifier</key><string>local.focallength.statistics</string>
<key>CFBundleName</key><string>焦段统计</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>4</string>
<key>CFBundleShortVersionString</key><string>0.3.1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPhotoLibraryUsageDescription</key><string>读取照片的焦距和镜头信息，生成使用统计。不会修改或删除照片。</string>
</dict></plist>
PLIST
codesign --force --sign - "$TASK_APP"
echo "$TASK_APP"

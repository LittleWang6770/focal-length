#!/bin/zsh
set -eu
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_ICONSET="$TASK_ROOT/build/icons/AppIcon.iconset"
TASK_SOURCE="$TASK_ROOT/Resources/AppIcon-source.png"
mkdir -p "$TASK_ICONSET"
sips -z 1024 1024 "$TASK_SOURCE" --out "$TASK_ROOT/Resources/AppIcon.png" >/dev/null
for task_size in 16 32 128 256 512; do
  sips -z "$task_size" "$task_size" "$TASK_SOURCE" --out "$TASK_ICONSET/icon_${task_size}x${task_size}.png" >/dev/null
  task_retina=$((task_size * 2))
  sips -z "$task_retina" "$task_retina" "$TASK_SOURCE" --out "$TASK_ICONSET/icon_${task_size}x${task_size}@2x.png" >/dev/null
done
iconutil -c icns "$TASK_ICONSET" -o "$TASK_ROOT/Resources/AppIcon.icns"

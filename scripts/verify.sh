#!/bin/zsh
set -eu
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
mkdir -p build/module-cache
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx13.0 -module-cache-path build/module-cache \
  Sources/Scanner.swift Sources/FolderAccess.swift Sources/AppModel.swift scripts/verify.swift -o build/verify
build/verify

#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
iconset="$project_root/Resources/Hushnote.iconset"
compiler_output=$(mktemp -d)
trap 'rm -rf "$compiler_output"' EXIT
export SWIFT_MODULECACHE_PATH="$compiler_output/module-cache"
export CLANG_MODULE_CACHE_PATH="$compiler_output/module-cache"
mkdir -p "$SWIFT_MODULECACHE_PATH"

# A lone file compiles as a script unless told otherwise, and script mode
# rejects the @main attribute the generator uses.
swiftc -parse-as-library \
    "$project_root/scripts/generate-app-icon.swift" \
    -o "$compiler_output/generate-app-icon"
"$compiler_output/generate-app-icon" \
    "$project_root/Resources/Hushnote-icon-source.png" \
    "$iconset" \
    "$project_root/Resources/Hushnote.icns"

echo "$project_root/Resources/Hushnote.icns"

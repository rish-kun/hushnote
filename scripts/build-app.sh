#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
configuration=${1:-debug}
requested_identity=${HUSHNOTE_SIGNING_IDENTITY:-}
build_root="$project_root/.build"
app_root="$build_root/Hushnote.app"
contents_root="$app_root/Contents"

export SWIFTPM_MODULECACHE_OVERRIDE="$build_root/module-cache"
export CLANG_MODULE_CACHE_PATH="$build_root/module-cache"

mkdir -p "$build_root/module-cache"
swift build --disable-sandbox --package-path "$project_root" -c "$configuration"

binary_path=$(swift build --disable-sandbox --package-path "$project_root" -c "$configuration" --show-bin-path)
mkdir -p "$contents_root/MacOS" "$contents_root/Resources"
cp "$project_root/Resources/Info.plist" "$contents_root/Info.plist"
cp "$binary_path/Hushnote" "$contents_root/MacOS/Hushnote"
if [[ -n "$requested_identity" ]]; then
    signing_identity="$requested_identity"
else
    signing_identity=$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Apple Development:.*\)".*/\1/p' \
        | head -n 1)
fi

if [[ -n "$signing_identity" ]]; then
    codesign --force --sign "$signing_identity" \
        --options runtime \
        --timestamp=none \
        --entitlements "$project_root/Resources/Hushnote.entitlements" \
        "$app_root"
    echo "Signed with: $signing_identity" >&2
else
    codesign --force --sign - \
        --requirements '=designated => identifier "dev.rishit.hushnote"' \
        --entitlements "$project_root/Resources/Hushnote.entitlements" \
        "$app_root"
    echo "Development fallback: ad-hoc signature with a stable local designated requirement." >&2
    echo "Use an Apple Development identity before distributing Hushnote." >&2
fi

echo "$app_root"

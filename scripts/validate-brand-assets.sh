#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
iconset="$project_root/Resources/Hushnote.iconset"

typeset -A expected=(
    icon_16x16.png 16
    icon_16x16@2x.png 32
    icon_32x32.png 32
    icon_32x32@2x.png 64
    icon_128x128.png 128
    icon_128x128@2x.png 256
    icon_256x256.png 256
    icon_256x256@2x.png 512
    icon_512x512.png 512
    icon_512x512@2x.png 1024
)

source_artwork="$project_root/Resources/Hushnote-icon-source.png"
[[ -s "$source_artwork" ]] || { echo "Missing $source_artwork" >&2; exit 1 }

for name pixels in ${(kv)expected}; do
    file="$iconset/$name"
    [[ -f "$file" ]] || { echo "Missing $file" >&2; exit 1 }
    width=$(sips -g pixelWidth "$file" | awk '/pixelWidth/ { print $2 }')
    height=$(sips -g pixelHeight "$file" | awk '/pixelHeight/ { print $2 }')
    [[ "$width" == "$pixels" && "$height" == "$pixels" ]] || {
        echo "$name is ${width}x${height}; expected ${pixels}x${pixels}" >&2
        exit 1
    }
    # The source artwork paints its corners opaque black. An output that lost
    # its alpha channel would put a black square behind the icon in the Dock.
    alpha=$(sips -g hasAlpha "$file" | awk '/hasAlpha/ { print $2 }')
    [[ "$alpha" == "yes" ]] || {
        echo "$name has no alpha channel; its corners would render black" >&2
        exit 1
    }
done

[[ -s "$project_root/Resources/Hushnote.icns" ]] || { echo "Missing Hushnote.icns" >&2; exit 1 }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$project_root/Resources/Info.plist")" == "Hushnote" ]]
grep -Fq 'cp "$project_root/Resources/Hushnote.icns" "$contents_root/Resources/Hushnote.icns"' "$project_root/scripts/build-app.sh"

echo "Brand assets are complete."

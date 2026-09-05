#!/bin/sh
# Assemble MacMusicPlugin.app from a release build. No Xcode required — this
# lays out the bundle by hand and ad-hoc signs it so macOS will run it and TCC
# prompts (Local Network, Files) attach to a stable identity.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

config=${CONFIG:-release}
version=${VERSION:-0.1.0}
build_number=${BUILD:-$(date +%Y%m%d%H%M)}
app="$root/dist/MacMusicPlugin.app"

echo "Building ($config)..."
swift build -c "$config" --product MacMusicPlugin

bin_path=$(swift build -c "$config" --product MacMusicPlugin --show-bin-path)

echo "Laying out $app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$bin_path/MacMusicPlugin" "$app/Contents/MacOS/MacMusicPlugin"

sed -e "s/__VERSION__/$version/g" -e "s/__BUILD__/$build_number/g" \
    "$root/Resources/Info.plist" > "$app/Contents/Info.plist"

if [ -f "$root/Resources/AppIcon.icns" ]; then
    cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
fi

printf 'APPL????' > "$app/Contents/PkgInfo"

echo "Ad-hoc signing"
codesign --force --deep --sign - --identifier org.sigmauno.mac-music-plugin "$app"

echo "Done: $app"

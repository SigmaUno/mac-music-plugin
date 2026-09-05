#!/bin/sh
# Build, bundle, and install MacMusicPlugin.app into ~/Applications, then launch it.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dest=${DEST:-"$HOME/Applications"}

sh "$root/scripts/bundle.sh"

mkdir -p "$dest"
# Quit a running copy so the file can be replaced.
osascript -e 'quit app "Mac Music Plugin"' 2>/dev/null || true
sleep 1
rm -rf "$dest/MacMusicPlugin.app"
cp -R "$root/dist/MacMusicPlugin.app" "$dest/MacMusicPlugin.app"

echo "Installed to $dest/MacMusicPlugin.app"
open "$dest/MacMusicPlugin.app"

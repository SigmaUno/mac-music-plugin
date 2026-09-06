#!/bin/sh
# Remove the installed app. The music library under
# ~/Library/Application Support/MacMusicPlugin is left untouched.
set -eu

dest=${DEST:-"$HOME/Applications"}
osascript -e 'quit app "Mac Music Plugin"' 2>/dev/null || true
sleep 1
rm -rf "$dest/MacMusicPlugin.app"
echo "Removed $dest/MacMusicPlugin.app"
echo "Your library is kept at ~/Library/Application Support/MacMusicPlugin"

#!/bin/sh
# Downloads the latest clippeek release and installs it into Applications.
set -e

if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 26 ]; then
    echo "clippeek needs macOS 26 or later." >&2
    exit 1
fi

dest=/Applications
[ -w "$dest" ] || dest="$HOME/Applications"
mkdir -p "$dest"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading clippeek..."
curl -fsSL https://github.com/tangheng05/clippeek/releases/latest/download/Clippeek.zip -o "$tmp/Clippeek.zip"
ditto -x -k "$tmp/Clippeek.zip" "$tmp"

pkill -x ClippeekApp 2>/dev/null || true
rm -rf "$dest/Clippeek.app"
mv "$tmp/Clippeek.app" "$dest/"
xattr -dr com.apple.quarantine "$dest/Clippeek.app" 2>/dev/null || true
open "$dest/Clippeek.app"

bin="$dest/Clippeek.app/Contents/MacOS/ClippeekApp"
if [ -w /usr/local/bin ]; then
    ln -sf "$bin" /usr/local/bin/clippeek
else
    echo "For the clippeek command, run: sudo ln -sf \"$bin\" /usr/local/bin/clippeek"
fi

echo "Installed to $dest. The welcome window walks you through connecting your Zipline server."

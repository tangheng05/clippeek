#!/bin/sh
# Tags the version in Info.plist and pushes it; the Release workflow does the rest.
# Usage: scripts/publish.sh
set -e
version=$(sed -n '/CFBundleShortVersionString/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' Resources/Info.plist)
git tag "v$version"
git push origin "v$version"
echo "Pushed v$version. Follow it at https://github.com/tangheng05/clippeek/actions"

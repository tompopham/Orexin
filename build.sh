#!/bin/zsh
# Builds build/Orexin.app. With --install, replaces /Applications/Orexin.app and opens it.
set -euo pipefail
cd "${0:A:h}"

app=build/Orexin.app
rm -rf build
mkdir -p "$app/Contents/MacOS"
swiftc -O -target arm64-apple-macosx14.0 main.swift -o "$app/Contents/MacOS/Orexin"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"

if [[ ${1:-} == --install ]]; then
  # SIGTERM lets Orexin restore lid sleep before exiting.
  pkill -TERM -x Orexin || true
  while pgrep -x Orexin >/dev/null; do sleep 0.2; done
  rm -rf /Applications/Orexin.app
  ditto "$app" /Applications/Orexin.app
  open /Applications/Orexin.app
fi

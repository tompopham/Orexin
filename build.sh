#!/bin/zsh
# Builds build/Awake.app. With --install, replaces /Applications/Awake.app and opens it.
set -euo pipefail
cd "${0:A:h}"

app=build/Awake.app
rm -rf build
mkdir -p "$app/Contents/MacOS"
swiftc -O -target arm64-apple-macosx14.0 main.swift -o "$app/Contents/MacOS/Awake"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"

if [[ ${1:-} == --install ]]; then
  # SIGTERM lets Awake restore lid sleep before exiting.
  pkill -TERM -x Awake || true
  while pgrep -x Awake >/dev/null; do sleep 0.2; done
  rm -rf /Applications/Awake.app
  ditto "$app" /Applications/Awake.app
  open /Applications/Awake.app
fi

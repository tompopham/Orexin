# Awake

A menu bar app that keeps this Mac awake, lid open or closed. Personal replacement for Amphetamine.

## How lid-closed mode works
It suppresses lid-close sleep with an unprivileged IOKit call — `IOPMrootDomain` user-client
selector 12 (`kPMSetClamshellSleepState`) — the same call Amphetamine's Closed-Display Mode
uses. No root, no `sudo`, no permissions file. The bit is never written to disk and clears
on reboot, so nothing can leave the Mac permanently unable to sleep. `powerd` re-computes the
same bit on wake / power-source change, so Awake re-applies it on a 10s timer, an IOPS
power-source notification, and on wake.

Safety cutoffs: turns itself off below 10% battery (on battery) or at critical thermal state.

## Build & install
    ./build.sh            # builds build/Awake.app
    ./build.sh --install  # builds, replaces /Applications/Awake.app, opens it

Requires the Xcode command line tools (`xcode-select --install`). Apple-silicon only as written.

## Files
- `main.swift`  — the whole app
- `Info.plist`  — bundle metadata (LSUIElement menu bar app)
- `build.sh`    — swiftc build + ad-hoc codesign, optional install

# Orexin

A menu bar app that keeps this Mac awake, lid open or closed, with no root, no `sudo` and no
permissions file. Personal replacement for Amphetamine.
Named after orexin (hypocretin), the brain peptide that holds you awake; losing the neurons
that make it causes narcolepsy.

## Requirements
macOS 14 Sonoma or later, on an Apple silicon Mac. `build.sh` builds for arm64 only and
`Info.plist` sets the minimum system to 14.0. Building needs the Xcode command line tools
(`xcode-select --install`).

## Build & install
    ./build.sh            # builds build/Orexin.app
    ./build.sh --install  # builds, replaces /Applications/Orexin.app, opens it

## First launch
On its first launch Orexin tries once to turn on Open at Login; check the tick in its menu.
Untick it there and it stays off.

The first time you pick a duration, it warns that it keeps the Mac awake with the lid closed
and that the Mac can overheat in a bag. Click Keep Awake to go on; after that it does not ask again. Cancel leaves Orexin off, and it
asks the next time.

## Use
Orexin sits in the menu bar as a pill icon, filled while it is on. Click it and pick how long
to keep the Mac awake: Until I Turn It Off, 30 Minutes, 1 Hour, 2 Hours, 4 Hours or 8 Hours.
Picking another duration while it is on starts that one from now. The top line of the menu
shows the time left, and Turn Off ends the session early.

Every session covers both lid states; there is no separate lid-closed switch.
- **Lid open:** it stops the Mac going to sleep when idle. The screen can still dim and turn
  off as usual.
- **Lid closed:** it stops closing the lid from sleeping the Mac, so it keeps running with
  the lid shut and no external display. Once the session ends, closing the lid sleeps the
  Mac as normal again.

Safety cutoffs: on battery power it won't start below 10% and turns itself off if the charge
falls below 10%. It also turns itself off if the Mac reaches a critical thermal state. The
menu then says why it stopped.

## How lid-closed mode works
It suppresses lid-close sleep with an unprivileged IOKit call — `IOPMrootDomain` user-client
selector 12 (`kPMSetClamshellSleepState`) — the same call Amphetamine's Closed-Display Mode
uses. The bit is never written to disk and clears on reboot, so nothing can leave the Mac
permanently unable to sleep. `powerd` re-computes the same bit on wake / power-source change,
so Orexin re-applies it on a 10s timer, an IOPS power-source notification, and on wake.

## Uninstall
1. If Open at Login is ticked in Orexin's menu, untick it.
2. Choose Quit Orexin. Quitting turns the lid-close bit back off, so the Mac sleeps normally.
3. Delete `/Applications/Orexin.app`.

Orexin changes no `pmset` settings and writes nothing about sleep to disk. The one thing it
leaves behind is its preferences file, `~/Library/Preferences/com.tompopham.Orexin.plist`.
It holds two first-run flags (login item set up, warning accepted) and the menu bar icon's
position. To remove it:

    defaults delete com.tompopham.Orexin

## Files
- `main.swift`  — the whole app
- `Info.plist`  — bundle metadata (LSUIElement menu bar app)
- `build.sh`    — swiftc build + ad-hoc codesign, optional install

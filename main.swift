// Awake — keeps this Mac awake from the menu bar, lid open or closed.
//
// Closing the lid is what sleeps a MacBook with no external display. Awake stops that with
// an unprivileged IOKit call — IOPMrootDomain user-client selector kPMSetClamshellSleepState
// (12) — the same call Amphetamine's Closed-Display Mode makes. No root, no sudo, no
// permissions file. Unlike `pmset disablesleep`, this suppresses only lid-close sleep (not
// all sleep) and is never written to disk, so a crash or reboot clears it automatically —
// there is no state that can leave the Mac permanently unable to sleep.
//
// The catch: powerd owns the same kernel bit and recomputes it on wake, power-source change
// and assertion churn, so Awake must re-apply it — on a timer and on those events — for as
// long as a session is running.

import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import ServiceManagement

// MARK: - Power

enum Power {
    /// Battery percentage and whether the Mac is running on it, or nil if unreadable.
    static func battery() -> (percent: Int, onBattery: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let capacity = description[kIOPSMaxCapacityKey] as? Int, capacity > 0
            else { continue }
            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            return (current * 100 / capacity, onBattery)
        }
        return nil
    }

    static var lidClosed: Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return false }
        defer { IOObjectRelease(rootDomain) }
        let state = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return state?.takeRetainedValue() as? Bool ?? false
    }
}

/// Holds a system-sleep power assertion (keeps the Mac awake with the lid open, on Macs that
/// idle-sleep) for the life of a session.
final class SleepAssertion {
    private var id: IOPMAssertionID = 0
    private var held = false

    func hold() {
        guard !held else { return }
        held = IOPMAssertionCreateWithName("PreventUserIdleSystemSleep" as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Awake is keeping your Mac awake" as CFString, &id) == kIOReturnSuccess
    }

    func release() {
        guard held else { return }
        IOPMAssertionRelease(id)
        held = false
    }
}

/// Suppresses lid-close sleep through IOPMrootDomain's user client. The kernel applies no
/// privilege check to this selector and the App Sandbox grants every app the user client,
/// so it needs neither root nor an entitlement.
final class ClamshellSuppressor {
    private static let kPMSetClamshellSleepState: UInt32 = 12  // from IOKit's IOPMLibDefs.h

    private var connection: io_connect_t = 0
    private var open = false

    private func ensureOpen() -> Bool {
        if open { return true }
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return false }
        defer { IOObjectRelease(rootDomain) }
        guard IOServiceOpen(rootDomain, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return false }
        open = true
        return true
    }

    /// Sets the clamshell-sleep-disable bit. Returns whether the call succeeded.
    @discardableResult
    func setDisabled(_ disabled: Bool) -> Bool {
        guard ensureOpen() else { return false }
        var input: UInt64 = disabled ? 1 : 0
        return IOConnectCallScalarMethod(connection, Self.kPMSetClamshellSleepState, &input, 1, nil, nil) == kIOReturnSuccess
    }

    func close() {
        guard open else { return }
        setDisabled(false)  // Best-effort restore before we let the connection go.
        IOServiceClose(connection)
        connection = 0
        open = false
    }
}

// MARK: - App

final class MenuAction: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let assertion = SleepAssertion()
    private let clamshell = ClamshellSuppressor()
    private let defaults = UserDefaults.standard
    private let batteryFloor = 10
    private let reapplyInterval: TimeInterval = 10  // powerd can clear the bit between ticks.
    private var isOn = false
    private var endsAt: Date?
    private var stopReason: String?
    private var ticker: Timer?
    private var powerSource: CFRunLoopSource?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        if !defaults.bool(forKey: "loginItemConfigured") {
            try? SMAppService.mainApp.register()
            defaults.set(true, forKey: "loginItemConfigured")
        }

        // A clean exit clears the bit; these catch a Terminal kill so it clears there too.
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reassert() }

        updateStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        assertion.release()
        clamshell.close()
    }

    // MARK: Session

    private func turnOn(for duration: TimeInterval?) {
        if let battery = Power.battery(), battery.onBattery, battery.percent < batteryFloor {
            alert("Your battery is below \(batteryFloor)%. Plug in your Mac to keep it awake.")
            return
        }
        guard confirmFirstUse() else { return }

        guard clamshell.setDisabled(true) else {
            alert("Couldn't keep your Mac awake with the lid closed. Please try again.")
            return
        }
        assertion.hold()
        isOn = true
        endsAt = duration.map { Date().addingTimeInterval($0) }
        stopReason = nil
        startWatching()
        updateStatus()
    }

    private func turnOff(reason: String?) {
        isOn = false
        endsAt = nil
        stopReason = reason
        assertion.release()
        clamshell.setDisabled(false)
        stopWatching()
        updateStatus()
    }

    /// Re-applies the clamshell bit powerd may have cleared. Cheap; safe to call often.
    private func reassert() {
        guard isOn else { return }
        clamshell.setDisabled(true)
    }

    private func tick() {
        guard isOn else { return }
        if let endsAt, Date() >= endsAt {
            turnOff(reason: nil)
        } else if let battery = Power.battery(), battery.onBattery, battery.percent < batteryFloor {
            turnOff(reason: "Off — battery fell below \(batteryFloor)%")
        } else if ProcessInfo.processInfo.thermalState == .critical {
            turnOff(reason: "Off — your Mac got too hot")
        } else {
            reassert()
            updateStatus()  // Keeps the tooltip countdown current.
        }
    }

    private func startWatching() {
        if ticker == nil {
            let timer = Timer(timeInterval: reapplyInterval, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }
        if powerSource == nil {
            // Re-apply the moment the power source changes — a common trigger for powerd
            // clearing the bit.
            let context = Unmanaged.passUnretained(self).toOpaque()
            let source = IOPSNotificationCreateRunLoopSource({ ctx in
                guard let ctx else { return }
                Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue().tick()
            }, context)?.takeRetainedValue()
            if let source {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
                powerSource = source
            }
        }
    }

    private func stopWatching() {
        ticker?.invalidate()
        ticker = nil
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode)
            self.powerSource = nil
        }
    }

    private func confirmFirstUse() -> Bool {
        if defaults.bool(forKey: "warningAccepted") { return true }
        let warning = NSAlert()
        warning.messageText = "Awake keeps your Mac awake even with the lid closed"
        warning.informativeText = """
            Don't put your Mac in a bag while Awake is on — it can overheat. \
            Awake turns itself off if the battery drops below \(batteryFloor)% or your Mac gets too hot, \
            and closing Awake (or restarting) lets your Mac sleep normally again.
            """
        warning.addButton(withTitle: "Keep Awake")
        warning.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard warning.runModal() == .alertFirstButtonReturn else { return false }
        defaults.set(true, forKey: "warningAccepted")
        return true
    }

    private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            alert("Couldn't change Open at Login: \(error.localizedDescription)")
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if isOn {
            menu.addItem(MenuAction("Turn Off") { [unowned self] in turnOff(reason: nil) })
        }
        menu.addItem(.separator())

        let header = NSMenuItem(title: "Keep Awake, Lid Open or Closed:", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let durations: [(String, TimeInterval?)] = [
            ("Until I Turn It Off", nil), ("30 Minutes", 30 * 60), ("1 Hour", 3600),
            ("2 Hours", 2 * 3600), ("4 Hours", 4 * 3600), ("8 Hours", 8 * 3600),
        ]
        for (title, duration) in durations {
            let item = MenuAction(title) { [unowned self] in turnOn(for: duration) }
            item.indentationLevel = 1
            menu.addItem(item)
        }
        menu.addItem(.separator())

        menu.addItem(MenuAction("Open at Login", checked: SMAppService.mainApp.status == .enabled) { [unowned self] in
            toggleLogin()
        })
        menu.addItem(MenuAction("Quit Awake") { NSApp.terminate(nil) })
    }

    private var statusText: String {
        guard isOn else { return stopReason ?? "Off — closing the lid sleeps your Mac" }
        guard let endsAt else { return "On until you turn it off" }
        let minutes = max(1, Int((endsAt.timeIntervalSinceNow / 60).rounded(.up)))
        return minutes >= 60 ? "On — \(minutes / 60) h \(minutes % 60) min left" : "On — \(minutes) min left"
    }

    private func updateStatus() {
        guard let button = statusItem?.button else { return }
        let image = NSImage(systemSymbolName: isOn ? "pills.fill" : "pills", accessibilityDescription: "Awake")
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = !isOn
        button.toolTip = "Awake: \(statusText)"
    }

    private func alert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Awake"
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

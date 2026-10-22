import Cocoa
import ApplicationServices
import ServiceManagement
import os

/// Enable with `defaults write tech.brickandclick.flipscroll debugLog -bool true`, then
/// `log stream --predicate 'subsystem == "tech.brickandclick.flipscroll"'`.
let log = Logger(subsystem: "tech.brickandclick.flipscroll", category: "scroll")
let debugLog = UserDefaults.standard.bool(forKey: "debugLog")

// MARK: - Settings

enum Key: String, CaseIterable {
    case enabled, mouseVertical, mouseHorizontal, trackpadVertical, trackpadHorizontal
}

enum Settings {
    static let defaults = UserDefaults.standard

    static func register() {
        defaults.register(defaults: [
            Key.enabled.rawValue: true,
            Key.mouseVertical.rawValue: true,
            Key.mouseHorizontal.rawValue: true,
            Key.trackpadVertical.rawValue: false,
            Key.trackpadHorizontal.rawValue: false,
        ])
    }

    static subscript(key: Key) -> Bool {
        get { defaults.bool(forKey: key.rawValue) }
        set { defaults.set(newValue, forKey: key.rawValue) }
    }
}

// MARK: - Scroll tap

enum Source { case mouse, trackpad }

/// Tracks finger count from gesture events so continuous scrolls can be
/// attributed to the trackpad (2+ fingers) or a Magic Mouse (1 finger).
/// The source is decided once when a scroll gesture begins and kept until it
/// and its momentum end, since fingers lift before the last events arrive.
final class ScrollTap {
    static let shared = ScrollTap()

    private static let phaseBegan: Int64 = 1
    private static let phaseMayBegin: Int64 = 128

    private var tap: CFMachPort?
    private var touchCount = 0
    /// macOS hides touch data unless Input Monitoring is granted; without it every
    /// gesture reports 0 touches and finger counting can't be trusted.
    private var touchesVisible = false
    private var lastSource: Source = .mouse

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() -> Bool {
        if tap != nil { return true }
        let gestureType = CGEventType(rawValue: UInt32(NSEvent.EventType.gesture.rawValue))!
        let mask = (CGEventMask(1) << CGEventType.scrollWheel.rawValue)
                 | (CGEventMask(1) << gestureType.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                ScrollTap.shared.handle(type: type, event: event)
            },
            userInfo: nil
        ) else { return false }
        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .scrollWheel:
            if Settings[.enabled] { reverse(event) }
        default:
            if type.rawValue == UInt32(NSEvent.EventType.gesture.rawValue),
               let ns = NSEvent(cgEvent: event) {
                let count = ns.touches(matching: .touching, in: nil).count
                if count > 0 { touchesVisible = true }
                if debugLog, count != touchCount { log.debug("gesture touches=\(count)") }
                touchCount = count
            }
        }
        return Unmanaged.passUnretained(event)
    }

    private func source(of event: CGEvent) -> Source {
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)

        // Classic notched wheel, or smooth-scrolling mouse drivers without phases.
        if !continuous || (phase == 0 && momentum == 0) { return .mouse }
        // Mid-gesture, ended, or momentum: keep whatever started the scroll.
        guard phase == Self.phaseBegan || phase == Self.phaseMayBegin else { return lastSource }
        // Phased scrolling only comes from multi-touch devices. Without touch data,
        // assume trackpad (a Magic Mouse then follows the trackpad settings).
        let src: Source = !touchesVisible || touchCount >= 2 ? .trackpad : .mouse
        if debugLog {
            log.debug("scroll begin phase=\(phase) touches=\(self.touchCount) visible=\(self.touchesVisible) -> \(src == .trackpad ? "trackpad" : "mouse")")
        }
        return src
    }

    private func reverse(_ event: CGEvent) {
        let src = source(of: event)
        lastSource = src
        let vertical = Settings[src == .mouse ? .mouseVertical : .trackpadVertical]
        let horizontal = Settings[src == .mouse ? .mouseHorizontal : .trackpadHorizontal]

        if vertical {
            let delta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let point = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            let fixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -delta)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -point)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixed)
        }
        if horizontal {
            let delta = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
            let point = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
            let fixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -delta)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -point)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -fixed)
        }
    }
}

// MARK: - Menu bar UI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.register()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        startTapWhenTrusted()
    }

    private func startTapWhenTrusted() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary), ScrollTap.shared.start() {
            updateIcon()
            return
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted(), ScrollTap.shared.start() {
                timer.invalidate()
                self?.updateIcon()
            }
        }
    }

    private func updateIcon() {
        let name = Settings[.enabled] && ScrollTap.shared.isRunning
            ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "FlipScroll")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(toggle("Enabled", .enabled))
        menu.addItem(.separator())
        menu.addItem(header("Mouse"))
        menu.addItem(toggle("Reverse Vertical", .mouseVertical, indent: true))
        menu.addItem(toggle("Reverse Horizontal", .mouseHorizontal, indent: true))
        menu.addItem(header("Trackpad"))
        menu.addItem(toggle("Reverse Vertical", .trackpadVertical, indent: true))
        menu.addItem(toggle("Reverse Horizontal", .trackpadHorizontal, indent: true))
        menu.addItem(.separator())

        if !ScrollTap.shared.isRunning {
            let item = NSMenuItem(title: "Grant Accessibility Access…",
                                  action: #selector(openAccessibility), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if !CGPreflightListenEventAccess() {
            let item = NSMenuItem(title: "Allow Input Monitoring (for Magic Mouse)…",
                                  action: #selector(requestInputMonitoring), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func toggle(_ title: String, _ key: Key, indent: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(toggleSetting(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = key.rawValue
        item.state = Settings[key] ? .on : .off
        item.indentationLevel = indent ? 1 : 0
        return item
    }

    @objc private func toggleSetting(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = Key(rawValue: raw) else { return }
        Settings[key].toggle()
        updateIcon()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func requestInputMonitoring() {
        if !CGRequestListenEventAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

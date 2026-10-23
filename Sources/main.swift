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

/// Private CoreGraphics and IOKit functions, looked up at runtime. They expose the
/// HID event behind a scroll event, and so the device that sent it. Scroll Reverser
/// relies on the same ones.
enum HID {
    typealias CopyEvent = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?
    typealias GetSender = @convention(c) (CFTypeRef) -> UInt64
    typealias GetFloat = @convention(c) (CFTypeRef, UInt32) -> Double
    typealias SetFloat = @convention(c) (CFTypeRef, UInt32, Double) -> Void

    private static let image = dlopen(nil, RTLD_NOW)
    private static func load<T>(_ name: String) -> T? {
        dlsym(image, name).map { unsafeBitCast($0, to: T.self) }
    }

    static let copyEvent: CopyEvent? = load("CGEventCopyIOHIDEvent")
    static let senderID: GetSender? = load("IOHIDEventGetSenderID")
    static let getFloat: GetFloat? = load("IOHIDEventGetFloatValue")
    static let setFloat: SetFloat? = load("IOHIDEventSetFloatValue")

    // (kIOHIDEventTypeScroll << 16) | axis
    static let fieldScrollX: UInt32 = 6 << 16
    static let fieldScrollY: UInt32 = 6 << 16 | 1
}

/// Reverses scroll events per device and axis. The device is identified from the HID
/// sender of each event: trackpads publish HIDTrackpadScrollAcceleration, while mice,
/// the Magic Mouse included, publish HIDMouseScrollAcceleration.
final class ScrollTap {
    static let shared = ScrollTap()

    private var tap: CFMachPort?
    private var lastSource: Source = .mouse
    /// Registry entry IDs are not reused within a boot, so lookups are cached per sender.
    private var sources: [UInt64: Source] = [:]
    /// Senders not yet in the registry (new virtual devices) are retried at most every 250ms.
    private var retryAfter: [UInt64: TimeInterval] = [:]

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() -> Bool {
        if tap != nil { return true }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << CGEventType.scrollWheel.rawValue,
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
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func source(of event: CGEvent, hidEvent: CFTypeRef?) -> Source {
        if let hidEvent, let senderID = HID.senderID?(hidEvent), senderID != 0,
           let src = source(forSender: senderID) {
            return src
        }
        // No device information: momentum keeps the device that started the scroll,
        // and continuous scrolling most likely comes from a trackpad.
        if event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 { return lastSource }
        return event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 ? .trackpad : .mouse
    }

    private func source(forSender senderID: UInt64) -> Source? {
        if let cached = sources[senderID] { return cached }
        let now = ProcessInfo.processInfo.systemUptime
        if let retry = retryAfter[senderID], now < retry { return nil }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(senderID))
        guard service != 0 else {
            retryAfter[senderID] = now + 0.25
            return nil
        }
        defer { IOObjectRelease(service) }

        let acceleration = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, "HIDScrollAccelerationType" as CFString, nil,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? String
        let src: Source = acceleration == "HIDTrackpadScrollAcceleration"
            || conformsToSelfOrParent(service, "AppleMultitouchTrackpadHIDEventDriver") ? .trackpad : .mouse
        sources[senderID] = src
        retryAfter[senderID] = nil
        if debugLog {
            log.debug("sender \(senderID) acceleration=\(acceleration ?? "none", privacy: .public) -> \(src == .trackpad ? "trackpad" : "mouse", privacy: .public)")
        }
        return src
    }

    /// The multitouch drivers publish an AppleMultitouchDevice child that sends the
    /// events, so the parent's class counts too.
    private func conformsToSelfOrParent(_ service: io_service_t, _ className: String) -> Bool {
        if IOObjectConformsTo(service, className) != 0 { return true }
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(parent) }
        return IOObjectConformsTo(parent, className) != 0
    }

    private func reverse(_ event: CGEvent) {
        let hidEvent = HID.copyEvent?(event)?.takeRetainedValue()
        let src = source(of: event, hidEvent: hidEvent)
        lastSource = src
        let vertical = Settings[src == .mouse ? .mouseVertical : .trackpadVertical]
        let horizontal = Settings[src == .mouse ? .mouseHorizontal : .trackpadHorizontal]

        // Point deltas go after DeltaAxis: setting DeltaAxis makes macOS recompute the
        // point and fixed-point values, which would lose smooth scrolling.
        if vertical {
            let delta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let fixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            let point = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -delta)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixed)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -point)
            if let hidEvent, let get = HID.getFloat, let set = HID.setFloat {
                set(hidEvent, HID.fieldScrollY, -get(hidEvent, HID.fieldScrollY))
            }
        }
        if horizontal {
            let delta = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
            let fixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
            let point = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -delta)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -fixed)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -point)
            if let hidEvent, let get = HID.getFloat, let set = HID.setFloat {
                set(hidEvent, HID.fieldScrollX, -get(hidEvent, HID.fieldScrollX))
            }
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

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

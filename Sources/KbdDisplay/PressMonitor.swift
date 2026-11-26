import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hid
import IOKit.hidsystem

/// Listen-only global key observer. Uses a CGEvent session tap (Input Monitoring / Accessibility)
/// and falls back to AppKit's global monitor when Accessibility access is granted.
final class PressMonitor {
    enum KeyEvent { case down, up, tap }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var globalMonitor: Any?
    private let onKeyEvent: (UInt16, KeyEvent) -> Void
    private let onReset: () -> Void
    private lazy var capsHID = KeyboardKeyHIDMonitor(usage: kHIDUsage_KeyboardCapsLock) { [weak self] held in
        self?.onKeyEvent(57, held ? .down : .up)
    }
    var usesEventTap: Bool { tap != nil }
    var isRunning: Bool { tap != nil || globalMonitor != nil }

    static var hasPermission: Bool {
        CGPreflightListenEventAccess() || AXIsProcessTrusted()
    }

    static func requestPermission() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        _ = CGRequestListenEventAccess()
    }

    init(onKeyEvent: @escaping (UInt16, KeyEvent) -> Void, onReset: @escaping () -> Void) {
        self.onKeyEvent = onKeyEvent
        self.onReset = onReset
    }

    @discardableResult
    func start() -> Bool {
        // macOS can return a non-nil CGEvent tap even without Input Monitoring or Accessibility
        // permission, which silently drops keyDown events from other apps. Require real permission first.
        guard Self.hasPermission else {
            stop()
            return false
        }
        if tap != nil { return true }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        let tapCallback: CGEventTapCallBack = { _, type, event, context in
            if let context {
                Unmanaged<PressMonitor>.fromOpaque(context).takeUnretainedValue().handle(type, event)
            }
            return Unmanaged.passUnretained(event)
        }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        if let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: mask, callback: tapCallback, userInfo: userInfo)
            ?? CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .listenOnly, eventsOfInterest: mask, callback: tapCallback, userInfo: userInfo),
            let source = CFMachPortCreateRunLoopSource(nil, port, 0) {
            removeFallbackMonitor()
            tap = port
            self.source = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            capsHID.start()
            return true
        }
        // Fallback to AppKit global monitor when Accessibility access is granted.
        guard AXIsProcessTrusted() else { return false }
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
                self?.handleLocalEvent(event)
            }
        }
        if globalMonitor != nil { capsHID.start() }
        return globalMonitor != nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            onReset()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard let code = UInt16(exactly: event.getIntegerValueField(.keyboardEventKeycode)) else { return }
        switch type {
        case .flagsChanged: handleModifier(code, rawFlags: event.flags.rawValue)
        case .keyDown where code != 57 && event.getIntegerValueField(.keyboardEventAutorepeat) == 0:
            onKeyEvent(code, .down)
        case .keyUp where code != 57: onKeyEvent(code, .up)
        default: break
        }
    }

    func handleLocalEvent(_ event: NSEvent) {
        let code = event.keyCode
        switch event.type {
        case .flagsChanged: handleModifier(code, rawFlags: event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue))
        case .keyDown where code != 57 && !event.isARepeat: onKeyEvent(code, .down)
        case .keyUp where code != 57: onKeyEvent(code, .up)
        default: break
        }
    }

    private func handleModifier(_ code: UInt16, rawFlags: UInt64) {
        let pressed = Self.isModifierPressed(code: code, rawFlags: rawFlags)
        if code == 57 {
            // Caps Lock flags describe the latch. HID reports the physical hold when available.
            if !capsHID.isRunning { onKeyEvent(code, .tap) }
        } else {
            onKeyEvent(code, pressed ? .down : .up)
        }
    }

    static func isModifierPressed(_ event: NSEvent) -> Bool {
        let rawFlags = event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue)
        return isModifierPressed(code: event.keyCode, rawFlags: rawFlags)
    }

    /// Detect modifier key-down from the event's IOKit device-dependent flags so right-side
    /// modifiers (Right Cmd 54, Right Shift 60, Right Option 61, Right Control 62) work reliably.
    /// `CGEventSource.keyState` returns false for right-side modifier keycodes on macOS.
    static func isModifierPressed(code: UInt16, rawFlags: UInt64) -> Bool {
        let deviceBits = rawFlags & 0xFFFF
        switch code {
        case 59: // Left Control
            return deviceBits != 0
                ? (rawFlags & UInt64(NX_DEVICELCTLKEYMASK)) != 0
                : (rawFlags & CGEventFlags.maskControl.rawValue) != 0
        case 62: // Right Control
            return deviceBits != 0
                ? (rawFlags & UInt64(NX_DEVICERCTLKEYMASK)) != 0
                : (rawFlags & CGEventFlags.maskControl.rawValue) != 0
        case 56: // Left Shift
            return deviceBits != 0
                ? (rawFlags & UInt64(NX_DEVICELSHIFTKEYMASK)) != 0
                : (rawFlags & CGEventFlags.maskShift.rawValue) != 0
        case 60: // Right Shift
            return deviceBits != 0
                ? (rawFlags & UInt64(NX_DEVICERSHIFTKEYMASK)) != 0
                : (rawFlags & CGEventFlags.maskShift.rawValue) != 0
        case 55: // Left Command
            return deviceBits != 0
                ? (rawFlags & UInt64(NX_DEVICELCMDKEYMASK)) != 0
                : (rawFlags & CGEventFlags.maskCommand.rawValue) != 0
        case 54: // Right Command
            return deviceBits != 0
                ? (rawFlags & UInt64(NX_DEVICERCMDKEYMASK)) != 0
                : (rawFlags & CGEventFlags.maskCommand.rawValue) != 0
        case 58: // Left Option
            return deviceBits != 0
                ? (rawFlags & UInt64(NX_DEVICELALTKEYMASK)) != 0
                : (rawFlags & CGEventFlags.maskAlternate.rawValue) != 0
        case 61: // Right Option
            return deviceBits != 0
                ? (rawFlags & UInt64(NX_DEVICERALTKEYMASK)) != 0
                : (rawFlags & CGEventFlags.maskAlternate.rawValue) != 0
        case 57: // Caps Lock
            return (rawFlags & CGEventFlags.maskAlphaShift.rawValue) != 0
                || CGEventSource.keyState(.combinedSessionState, key: code)
        case 63: // Fn
            return (rawFlags & CGEventFlags.maskSecondaryFn.rawValue) != 0
        default:
            return CGEventSource.keyState(.combinedSessionState, key: code)
        }
    }

    private func removeFallbackMonitor() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    func stop() {
        capsHID.stop()
        if isRunning { onReset() }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        removeFallbackMonitor()
    }

    deinit { stop() }
}

/// Physical key transitions below the AppKit modifier latch and global shortcut handlers.
final class KeyboardKeyHIDMonitor {
    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private var manager: IOHIDManager?
    private(set) var isHeld = false
    private let usage: Int
    private let onChange: (Bool) -> Void
    var isRunning: Bool { manager != nil }

    init(usage: Int, onChange: @escaping (Bool) -> Void) {
        self.usage = usage
        self.onChange = onChange
    }

    @discardableResult
    func start() -> Bool {
        guard !Self.isRunningTests else { return false }
        guard manager == nil else { return true }
        guard PressMonitor.hasPermission else { return false }

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = [
            [
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard
            ],
            [
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_Keypad
            ]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)

        IOHIDManagerSetInputValueMatching(mgr, [kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad,
                                               kIOHIDElementUsageKey: usage] as CFDictionary)
        let callback: IOHIDValueCallback = { context, _, _, value in
            guard let context else { return }
            let monitor = Unmanaged<KeyboardKeyHIDMonitor>.fromOpaque(context).takeUnretainedValue()
            let pressed = IOHIDValueGetIntegerValue(value) != 0
            monitor.reportState(pressed)
        }
        IOHIDManagerRegisterInputValueCallback(mgr, callback, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        let openResult = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            return false
        }
        manager = mgr
        return true
    }

    private func reportState(_ pressed: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.reportState(pressed) }
            return
        }
        guard isHeld != pressed else { return }
        isHeld = pressed
        onChange(pressed)
    }

    func stop() {
        if let mgr = manager {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            manager = nil
        }
        if isHeld {
            isHeld = false
            onChange(false)
        }
    }

    deinit { stop() }
}

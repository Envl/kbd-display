import AppKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
    var persistentID: String? {
        guard let id = displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
    var canCapture: Bool {
        guard let id = displayID else { return false }
        return CGDisplayIsActive(id) != 0 && CGDisplayIsBuiltin(id) == 0 &&
            CGDisplayIsMain(id) == 0 && CGDisplayIsInMirrorSet(id) == 0
    }
}

final class DisplayOutput: NSObject, NSWindowDelegate {
    let board = BoardView(canvasSizing: .fillDisplay)
    private(set) var activeDisplayID: CGDirectDisplayID?
    private var ownsCapture = false
    private var window: NSPanel?
    private var isReconfiguring = false

    func beginReconfiguration(of id: CGDirectDisplayID) {
        guard activeDisplayID == id else { return }
        isReconfiguring = true
        closePanel()
    }

    func endReconfiguration(of id: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) -> Bool {
        guard activeDisplayID == id else { return false }
        if flags.contains(.removeFlag) || flags.contains(.disabledFlag) {
            release()
            return true
        }
        guard isReconfiguring else { return false }
        isReconfiguring = false
        return true
    }

    func refresh(selection: String?, exclusive: Bool) -> CGError? {
        guard let selection, let screen = NSScreen.screens.first(where: { $0.persistentID == selection && $0.canCapture }),
              let id = screen.displayID else { release(); return nil }
        if activeDisplayID != id || ownsCapture != exclusive {
            release()
            if exclusive {
                let status = CGDisplayCapture(id)
                guard status == .success else { return status }
                ownsCapture = true
            }
            activeDisplayID = id
        }
        guard !isReconfiguring else { return nil }
        let panel = window ?? makePanel()
        window = panel
        panel.setFrame(screen.frame, display: true)
        guard window === panel else { return nil }
        if panel.screen?.displayID == id && screen.canCapture {
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else {
            panel.orderOut(nil)
        }
        return nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        // The selected display's frame controls the panel's placement.
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.level = ownsCapture ? .init(rawValue: Int(CGShieldingWindowLevel()) + 1) : .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = board
        return panel
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let window, notification.object as? NSWindow === window, window.isVisible,
              let activeDisplayID else { return }
        if window.screen?.displayID != activeDisplayID || window.screen?.canCapture != true {
            window.orderOut(nil)
        }
    }

    func release() {
        guard let id = activeDisplayID else { return }
        activeDisplayID = nil
        isReconfiguring = false
        closePanel()
        if ownsCapture {
            ownsCapture = false
            CGDisplayRelease(id)
        }
    }

    private func closePanel() {
        guard let panel = window else { return }
        window = nil
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
    }
}

import AppKit
import SwiftUI
import XCTest
@testable import KbdDisplay

final class SettingsPreviewTests: XCTestCase {
    @MainActor func testTabChangesKeepCurrentSettingsAndOnlyPauseTheRemovedBoard() throws {
        _ = NSApplication.shared
        let suite = "kbd-display.preview-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EffectSettingsStore(defaults: defaults)
        var mounted: [BoardView] = []

        func page(_ name: String) -> some View {
            Group {
                if name != "Music" {
                    BoardSettingsPreview(store: store, labelKeys: name == "Dictation") { mounted.append($0) }
                }
            }
            .id(name)
        }

        let host = NSHostingView(rootView: page("Appearance"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        func waitForRender(_ condition: () -> Bool) -> Bool {
            let deadline = Date(timeIntervalSinceNow: 2)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return true }
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            } while Date() < deadline
            return condition()
        }

        XCTAssertTrue(waitForRender { mounted.count == 1 })
        let original = try XCTUnwrap(mounted.last)
        store.value.showKeyLegends.toggle()
        XCTAssertTrue(waitForRender { original.effects.showKeyLegends == store.value.showKeyLegends })

        host.rootView = page("Dictation")
        XCTAssertTrue(waitForRender { mounted.count == 2 && original.effectsPaused })
        let dictation = try XCTUnwrap(mounted.last)
        XCTAssertFalse(original === dictation)
        XCTAssertEqual(dictation.keycapPreview, .labeled)
        XCTAssertFalse(dictation.effectsPaused)
        XCTAssertNotNil(dictation.pulse(0))

        host.rootView = page("Music")
        XCTAssertTrue(waitForRender { dictation.effectsPaused })
        store.isPaused = true
        store.value.reactiveKeys.toggle()
        host.rootView = page("Key effects")
        XCTAssertTrue(waitForRender { mounted.count == 3 })
        let current = try XCTUnwrap(mounted.last)
        XCTAssertEqual(current.keycapPreview, .tiles)
        XCTAssertEqual(current.effects.reactiveKeys, store.value.reactiveKeys)
        XCTAssertTrue(current.effectsPaused)
        store.isPaused = false
        XCTAssertTrue(waitForRender { !current.effectsPaused })
        XCTAssertNotNil(current.pulse(0))
    }
}

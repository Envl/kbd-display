import AppKit
import XCTest
@testable import KbdDisplay

final class MenuTests: XCTestCase {
    @MainActor func testMenuActionsForBuildConfiguration() {
        _ = NSApplication.shared
        let menu = NSMenu()
        let delegate = AppDelegate()
        delegate.menuNeedsUpdate(menu)
        let actions = Set(menu.items.compactMap { $0.action.map(NSStringFromSelector) })
        let releaseActions: Set<String> = ["selectOutput:", "showEffects", "toggleEffectsPause", "toggleOpenAtLogin"]
        #if DEBUG
        XCTAssertEqual(actions, releaseActions.union(["showDebug", "toggleExclusiveCapture", "calibrate", "toggleMusicAmbient", "quit"]))
        #else
        XCTAssertFalse(delegate.responds(to: NSSelectorFromString("calibrate")))
        XCTAssertEqual(actions, releaseActions)
        #endif
    }
    @MainActor func testRestartActionIsOnlyAvailableForAStagedInstaller() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let menu = NSMenu()
        let title = "Restart to Update"
        var installs = 0

        delegate.menuNeedsUpdate(menu)
        XCTAssertNil(menu.item(withTitle: title))
        delegate.updates.stage(version: "1.2.3") { installs += 1 }
        XCTAssertEqual(delegate.updates.readyVersion, "1.2.3")
        delegate.menuNeedsUpdate(menu)
        let item = try XCTUnwrap(menu.item(withTitle: title))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(installs, 1)

        delegate.updates.clear()
        delegate.menuNeedsUpdate(menu)
        XCTAssertNil(menu.item(withTitle: title))
        delegate.updates.restartToUpdate()
        XCTAssertEqual(installs, 1)
    }

}

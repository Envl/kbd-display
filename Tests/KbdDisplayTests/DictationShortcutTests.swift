import XCTest
@testable import KbdDisplay

final class DictationShortcutTests: XCTestCase {
    func testRecordingPersistsOnFirstReleaseAndCancelPreservesShortcut() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EffectSettingsStore(defaults: defaults)
        let recorder = ShortcutRecorder()
        XCTAssertEqual(store.value.dictationShortcut, .standard)
        recorder.begin { store.value.dictationShortcut = $0 }
        recorder.receive(55, down: true)
        recorder.receive(55, down: true)
        recorder.receive(49, down: true)
        recorder.receive(55, down: false)
        XCTAssertNil(recorder.keys)
        let shortcut = store.value.dictationShortcut
        XCTAssertEqual(shortcut.keys, [55, 49])
        XCTAssertEqual(shortcut.anchor, 49)
        XCTAssertEqual(EffectSettingsStore(defaults: defaults).value.dictationShortcut, shortcut)
        recorder.begin { store.value.dictationShortcut = $0 }
        recorder.receive(58, down: true)
        recorder.cancel()
        recorder.receive(58, down: false)
        XCTAssertEqual(store.value.dictationShortcut, shortcut)
        store.value = EffectConfiguration()
        XCTAssertEqual(EffectSettingsStore(defaults: defaults).value.dictationShortcut, .standard)
    }

    func testMalformedPreferenceFallsBackToRightOption() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for invalid in [[], [-1, 49], [129], [58, 58]] {
            defaults.set(["dictationShortcut": invalid], forKey: "effectConfiguration")
            XCTAssertEqual(EffectSettingsStore(defaults: defaults).value.dictationShortcut, .standard)
        }
    }

    func testOnlyCompleteChordActivatesAndRebindingClearsHeldKeys() throws {
        let controller = DictationBlobController.shared
        controller.setEnabled(true)
        defer { controller.stop(); controller.setShortcut(.standard) }
        let shortcut = try XCTUnwrap(DictationShortcut(keys: [61, 56]))
        controller.setShortcut(shortcut)
        XCTAssertEqual(controller.effect.anchor, 56)
        controller.setKey(58, held: true)
        controller.setKey(56, held: true)
        XCTAssertFalse(controller.effect.isKeyHeld)
        controller.setKey(61, held: true)
        XCTAssertTrue(controller.effect.isKeyHeld)
        controller.setKey(61, held: false)
        XCTAssertFalse(controller.effect.isKeyHeld)
        controller.setKey(61, held: true)
        controller.setShortcut(try XCTUnwrap(DictationShortcut(keys: [1])))
        XCTAssertFalse(controller.effect.isKeyHeld)
        controller.setKey(1, held: true)
        XCTAssertTrue(controller.effect.isKeyHeld)
        controller.setEnabled(false)
        controller.setEnabled(true)
        XCTAssertFalse(controller.effect.isKeyHeld)
    }
}

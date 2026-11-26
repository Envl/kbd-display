import AppKit
import XCTest
@testable import KbdDisplay

private struct TestHintBus: Sendable {
    let namespace = "kbd-display.test.\(UUID().uuidString)"
    var center: DistributedNotificationCenter { .default() }

    func provider(_ id: String) -> [String: Any] {
        ["id": id, "pid": ProcessInfo.processInfo.processIdentifier]
    }

    func snapshot(_ id: String, title: String? = nil, press: Int? = nil) -> [String: Any] {
        var value: [String: Any] = ["provider": provider(id), "hints": []]
        value["title"] = title
        value["press"] = press
        return value
    }

    func post(_ topic: String, _ value: [String: Any]) {
        let json = try! JSONSerialization.data(withJSONObject: value)
        center.postNotificationName(.init("\(namespace).\(topic)"), object: String(decoding: json, as: UTF8.self),
                                    userInfo: nil, deliverImmediately: true)
    }
}

@MainActor
final class HintPluginTests: XCTestCase {
    func testRegistrationDiscoveryArbitrationAndUnregister() {
        let bus = TestHintBus()
        let ready = expectation(description: "Already-running provider answered discovery")
        let done = expectation(description: "Both providers cleared")
        let observer = bus.center.addObserver(forName: .init("\(bus.namespace).discover"), object: nil, queue: .main) { _ in
            bus.post("register", bus.snapshot("editor", title: "Editor", press: 1))
        }
        defer { bus.center.removeObserver(observer) }

        var titles: [String] = []
        var presses: [UInt16] = []
        let receiver = HintReceiver(namespace: bus.namespace) { frame in
            titles.append(frame?.title ?? "idle")
            if let press = frame?.press { presses.append(press) }
            if titles.count == 1 { ready.fulfill() }
            if frame == nil { done.fulfill() }
        }
        defer { withExtendedLifetime(receiver) {} }
        wait(for: [ready], timeout: 4)
        bus.post("state", bus.snapshot("other", title: "Unregistered"))
        bus.post("register", bus.snapshot("music"))
        bus.post("state", bus.snapshot("editor", title: "Editor", press: 1))
        bus.post("state", bus.snapshot("music", title: "Music"))
        bus.post("register", bus.snapshot("editor", title: "Editor"))
        bus.post("state", bus.snapshot("music"))
        bus.post("state", bus.snapshot("music", title: "Mixer"))
        bus.post("unregister", bus.provider("music"))
        bus.post("state", bus.snapshot("music", title: "Removed"))
        bus.post("unregister", bus.provider("editor"))
        wait(for: [done], timeout: 4)
        XCTAssertEqual(titles, ["Editor", "Editor", "Music", "Editor", "Mixer", "Editor", "idle"])
        XCTAssertEqual(presses, [1])
    }

    func testIndependentProviderRegistersAndExits() throws {
        let bus = TestHintBus()
        let active = expectation(description: "Separate process registered")
        let exited = expectation(description: "Process exit cleared its snapshot")
        let receiver = HintReceiver(namespace: bus.namespace) { frame in
            if let frame {
                XCTAssertEqual(frame.provider.id, "org.example.tool")
                XCTAssertNotEqual(frame.provider.pid, ProcessInfo.processInfo.processIdentifier)
                XCTAssertEqual(frame.hints.first?.label, "Save")
                active.fulfill()
            } else {
                exited.fulfill()
            }
        }
        defer { withExtendedLifetime(receiver) {} }

        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.standardInput = input
        #if arch(arm64)
        let target = "arm64-apple-macos13.0"
        #else
        let target = "x86_64-apple-macos13.0"
        #endif
        // This standalone app imports only Foundation and shares no types with the receiver.
        process.arguments = ["swift", "-target", target, "-e", """
            import Foundation
            let provider: [String: Any] = ["id": "org.example.tool", "pid": ProcessInfo.processInfo.processIdentifier]
            let hints: [[String: Any]] = [["keyCode": 1, "label": "Save", "symbol": "square.and.arrow.down"]]
            let data = try JSONSerialization.data(withJSONObject: ["provider": provider, "hints": hints])
            DistributedNotificationCenter.default().postNotificationName(.init("\(bus.namespace).register"),
                object: String(decoding: data, as: UTF8.self), userInfo: nil, deliverImmediately: true)
            _ = readLine()
            """]
        try process.run()
        wait(for: [active], timeout: 30)
        try input.fileHandleForWriting.close()
        wait(for: [exited], timeout: 5)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testIconReplyMustMatchDisplayedProviderEvenWhenIDsOverlap() throws {
        let bus = TestHintBus()
        let done = expectation(description: "Correct artwork delivered")
        var requests: [String] = []
        func png(_ color: NSColor) throws -> String {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap)).cgContext
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).base64EncodedString()
        }
        let stale = try png(.red)
        let current = try png(.blue)
        let observer = bus.center.addObserver(forName: .init("\(bus.namespace).requestIcon"), object: nil, queue: .main) { note in
            guard let text = note.object as? String,
                  let body = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let provider = body["provider"] as? [String: Any], let id = provider["id"] as? String,
                  body["iconID"] as? String == "shared" else { return }
            requests.append(id)
            if id == "second" {
                bus.post("icon", ["provider": bus.provider("first"), "iconID": "shared", "png": stale])
                // A late reply for the first provider must leave the second request pending.
                bus.post("icon", ["provider": provider, "iconID": "shared", "png": current])
            }
        }
        defer { bus.center.removeObserver(observer) }
        var received = 0
        let receiver = HintReceiver(namespace: bus.namespace, onIcon: { _, artwork in
            XCTAssertGreaterThan(artwork.colors.background.blueComponent, artwork.colors.background.redComponent)
            received += 1
            done.fulfill()
        }, onUpdate: { _ in })
        defer { withExtendedLifetime(receiver) {} }
        for id in ["first", "second"] {
            bus.post("register", ["provider": bus.provider(id), "hints": [
                ["keyCode": 1, "label": id, "symbol": "app", "iconID": "shared"]
            ]])
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(requests, ["first", "second"])
        XCTAssertEqual(received, 1)
    }
}

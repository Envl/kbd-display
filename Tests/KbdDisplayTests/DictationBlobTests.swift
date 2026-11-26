import AppKit
import Metal
import XCTest
@testable import KbdDisplay

final class DictationBlobTests: XCTestCase {
    func testVoiceMetricsRejectDCAndScaleWithSpeechAmplitudeAndFrequency() {
        var dcState: (prevIn: Float, prevOut: Float) = (0, 0)

        let silence = [Float](repeating: 0, count: 1024)
        let silentMetrics = PassiveMicMonitor.computeVoiceMetrics(samples: silence, dcState: &dcState)
        XCTAssertEqual(silentMetrics.amplitude, 0)
        XCTAssertEqual(silentMetrics.peak, 0)

        // Pure DC offset should settle to near-zero after DC blocker
        let dcSignal = [Float](repeating: 0.45, count: 1024)
        let dcMetrics = PassiveMicMonitor.computeVoiceMetrics(samples: dcSignal, dcState: &dcState)
        XCTAssertLessThan(dcMetrics.amplitude, 0.08)

        dcState = (0, 0)
        let quietSpeech = (0..<1024).map { Float(0.02 * sin(2.0 * .pi * 220.0 * Double($0) / 48_000.0)) }
        let quietMetrics = PassiveMicMonitor.computeVoiceMetrics(samples: quietSpeech, dcState: &dcState)

        dcState = (0, 0)
        let loudSpeech = (0..<1024).map { Float(0.28 * sin(2.0 * .pi * 220.0 * Double($0) / 48_000.0)) }
        let loudMetrics = PassiveMicMonitor.computeVoiceMetrics(samples: loudSpeech, dcState: &dcState)

        dcState = (0, 0)
        let brightConsonant = (0..<1024).map { Float(0.18 * sin(2.0 * .pi * 3400.0 * Double($0) / 48_000.0)) }
        let brightMetrics = PassiveMicMonitor.computeVoiceMetrics(samples: brightConsonant, dcState: &dcState)

        XCTAssertGreaterThan(quietMetrics.amplitude, 0.05)
        XCTAssertGreaterThan(loudMetrics.amplitude, quietMetrics.amplitude)
        XCTAssertGreaterThan(loudMetrics.peak, quietMetrics.peak)
        XCTAssertGreaterThan(brightMetrics.brightness, loudMetrics.brightness)
    }

    func testDictationBlobDebounceMicTriggerAndSmoothRelease() {
        let effect = DictationBlobEffect()
        XCTAssertFalse(effect.isActive)

        // Press Right Option: stays invisible during brief <60ms tap if external mic isn't open yet
        effect.setKeyHeld(true, at: 10.0)
        XCTAssertTrue(effect.isActive)
        effect.step(dt: 1.0 / 60.0, now: 10.02, micSnapshot: .idle)
        XCTAssertEqual(effect.visibility, 0)

        // When external mic opens, blob activates immediately without waiting for debounce
        let activeMic = PassiveMicSnapshot(
            externalMicOpen: true,
            amplitude: 0.78,
            peak: 0.85,
            brightness: 0.42,
            permissionDenied: false
        )
        effect.step(dt: 1.0 / 60.0, now: 10.06, micSnapshot: activeMic)
        XCTAssertGreaterThan(effect.visibility, 0.05)
        XCTAssertGreaterThan(effect.smoothedAmplitude, 0.25)

        // Hold for a short stretch so visibility reaches 1.0
        for i in 1...20 {
            effect.step(dt: 1.0 / 60.0, now: 10.06 + Double(i) / 60.0, micSnapshot: activeMic)
        }
        XCTAssertEqual(effect.visibility, 1.0, accuracy: 0.01)

        // Release key: fades out smoothly back to inactive
        effect.setKeyHeld(false, at: 10.5)
        for i in 1...40 {
            effect.step(dt: 1.0 / 60.0, now: 10.5 + Double(i) / 60.0, micSnapshot: .idle)
        }
        XCTAssertFalse(effect.isActive)
        XCTAssertEqual(effect.visibility, 0)
    }

    @MainActor
    func testDictationBlobRendersAroundRightOptionAndGrowsWithVoiceAmplitude() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        let rightOptRect = try XCTUnwrap(Action75.rects[DictationShortcut.rightOption])
        let escRect = try XCTUnwrap(Action75.rects[53])

        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1920, pixelsHigh: 720,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        // Match BoardView's flipped coordinate space (origin at top-left).
        context.cgContext.translateBy(x: 0, y: Action75.canvas.height)
        context.cgContext.scaleBy(x: 1, y: -1)

        let colors = EffectColorParams()

        func renderEnergy(amplitude: Float, peak: Float) throws -> (totalLuma: Double, rightOptLuma: Double, escLuma: Double) {
            let effect = DictationBlobEffect()
            effect.setKeyHeld(true, at: 1.0)
            let snap = PassiveMicSnapshot(
                externalMicOpen: true,
                amplitude: amplitude,
                peak: peak,
                brightness: amplitude * 0.6,
                permissionDenied: false
            )
            for i in 0..<25 {
                effect.step(dt: 1.0 / 60.0, now: 1.0 + Double(i) / 60.0, micSnapshot: snap)
            }
            context.cgContext.clear(CGRect(origin: .zero, size: Action75.canvas))
            effect.draw(in: context.cgContext, colors: colors)

            let bytes = try XCTUnwrap(rep.bitmapData)
            var totalLuma = 0.0
            for i in stride(from: 0, to: rep.bytesPerPlane, by: 4) {
                totalLuma += 0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1]) + 0.0722 * Double(bytes[i + 2])
            }
            let optCol = try XCTUnwrap(rep.colorAt(x: Int(rightOptRect.midX), y: Int(rightOptRect.midY))?.usingColorSpace(.deviceRGB))
            let escCol = try XCTUnwrap(rep.colorAt(x: Int(escRect.midX), y: Int(escRect.midY))?.usingColorSpace(.deviceRGB))
            let optLuma = 0.2126 * Double(optCol.redComponent) + 0.7152 * Double(optCol.greenComponent) + 0.0722 * Double(optCol.blueComponent)
            let escLuma = 0.2126 * Double(escCol.redComponent) + 0.7152 * Double(escCol.greenComponent) + 0.0722 * Double(escCol.blueComponent)
            return (totalLuma, optLuma, escLuma)
        }

        let quiet = try renderEnergy(amplitude: 0.05, peak: 0.05)
        let loud = try renderEnergy(amplitude: 0.90, peak: 0.95)

        XCTAssertGreaterThan(quiet.rightOptLuma, 0.05)
        XCTAssertLessThan(quiet.escLuma, 0.01)
        XCTAssertLessThan(loud.escLuma, 0.01)
        XCTAssertGreaterThan(loud.totalLuma, quiet.totalLuma * 1.45)
    }

    @MainActor
    func testPressMonitorReportsRightOptionAndBoardViewStaysDarkAtIdle() throws {
        XCTAssertTrue(PressMonitor.isModifierPressed(code: 61, rawFlags: 0x00080040))
        XCTAssertFalse(PressMonitor.isModifierPressed(code: 61, rawFlags: 0))
        XCTAssertFalse(PressMonitor.isModifierPressed(code: 61, rawFlags: 0x00080020))

        _ = NSApplication.shared
        let board = BoardView(frame: CGRect(origin: .zero, size: Action75.canvas))
        let window = NSWindow(contentRect: board.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = board
        for layer in EffectLayer.allCases { board.effects[layer] = false }

        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1920, pixelsHigh: 720,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = Action75.canvas
        board.cacheDisplay(in: board.bounds, to: bitmap)

        let rightOpt = try XCTUnwrap(Action75.rects[DictationShortcut.rightOption])
        let c = try XCTUnwrap(bitmap.colorAt(x: Int(rightOpt.midX), y: Int(rightOpt.midY))?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(max(c.redComponent, max(c.greenComponent, c.blueComponent)), 0.01)
    }

    @MainActor
    func testDictationBlobPreviewAndPhysicalHold() throws {
        let controller = DictationBlobController.shared
        controller.stop()
        controller.setEnabled(true)
        defer { controller.stop() }

        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1920, pixelsHigh: 720,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.translateBy(x: 0, y: Action75.canvas.height)
        context.cgContext.scaleBy(x: 1, y: -1)

        var settings = EffectConfiguration()
        settings.dictationVoiceBlob = true

        // Preview mode renders non-empty pixels around Right Option and auto-expires cleanly
        let start = ProcessInfo.processInfo.systemUptime
        controller.triggerPreview(duration: 0.6, at: start)
        XCTAssertTrue(controller.isActive)
        for i in 0..<10 {
            controller.draw(in: context.cgContext, now: start + Double(i) * 0.02, settings: settings)
        }
        XCTAssertGreaterThan(controller.effect.visibility, 0.4)
        let bytes = try XCTUnwrap(rep.bitmapData)
        XCTAssertTrue(UnsafeBufferPointer(start: bytes, count: rep.bytesPerPlane).contains { $0 != 0 })

        // Physical holds also drive the effect.
        controller.stop()
        controller.setKey(DictationShortcut.rightOption, held: true, at: start + 1.0)
        for i in 0..<10 {
            controller.draw(in: context.cgContext, now: start + 1.0 + Double(i) * 0.02, settings: settings)
        }
        XCTAssertTrue(controller.effect.isKeyHeld)
        XCTAssertGreaterThan(controller.effect.visibility, 0.4)
        controller.setKey(DictationShortcut.rightOption, held: false, at: start + 1.3)
        XCTAssertFalse(controller.effect.isKeyHeld)
    }
}

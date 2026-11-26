import AppKit
import Metal
import XCTest
@testable import KbdDisplay

final class MusicAmbientTests: XCTestCase {
    private func sineWave(frequency: Double, sampleRate: Double = 48_000, count: Int = 2048, amplitude: Float = 0.5) -> [Float] {
        (0..<count).map { i in
            amplitude * Float(sin(2.0 * .pi * frequency * Double(i) / sampleRate))
        }
    }

    func testFFTProcessorSeparatesLowMidAndHighFrequencies() {
        let lowFFT = MusicFFTProcessor()
        let lowFrame = lowFFT.process(monoSamples: sineWave(frequency: 65), sampleRate: 48_000)

        let midFFT = MusicFFTProcessor()
        let midFrame = midFFT.process(monoSamples: sineWave(frequency: 1_200), sampleRate: 48_000)

        let highFFT = MusicFFTProcessor()
        let highFrame = highFFT.process(monoSamples: sineWave(frequency: 7_500), sampleRate: 48_000)

        XCTAssertFalse(lowFrame.isSilent)
        XCTAssertGreaterThan(lowFrame.bass, lowFrame.mids)
        XCTAssertGreaterThan(lowFrame.bass, lowFrame.highs)

        XCTAssertGreaterThan(midFrame.mids, midFrame.bass)
        XCTAssertGreaterThan(midFrame.mids, midFrame.highs)

        XCTAssertGreaterThan(highFrame.highs, highFrame.bass)
        XCTAssertGreaterThan(highFrame.highs, highFrame.mids)

        XCTAssertLessThan(lowFrame.dominantPitch, midFrame.dominantPitch)
        XCTAssertLessThan(midFrame.dominantPitch, highFrame.dominantPitch)
    }

    func testFFTProcessorDetectsBeatOnsetAfterSilence() {
        let fft = MusicFFTProcessor()
        let silence = [Float](repeating: 0, count: MusicFFTProcessor.fftSize)
        for _ in 0..<6 {
            let f = fft.process(monoSamples: silence, dt: 1.0 / 60.0)
            XCTAssertFalse(f.beatTriggered)
            XCTAssertTrue(f.isSilent)
        }

        let kick = sineWave(frequency: 72, amplitude: 0.85)
        let burst = fft.process(monoSamples: kick, dt: 1.0 / 60.0)
        XCTAssertTrue(burst.beatTriggered)
        XCTAssertGreaterThan(burst.beatPulse, 0.5)
        XCTAssertEqual(burst.beatCount, 1)

        var lastPulse = burst.beatPulse
        for _ in 0..<18 {
            let decayFrame = fft.process(monoSamples: silence, dt: 1.0 / 60.0)
            lastPulse = decayFrame.beatPulse
        }
        XCTAssertLessThan(lastPulse, burst.beatPulse * 0.5)
    }

    func testDemoMusicSynthesizerGeneratesValidAudioAndBeats() {
        let synth = DemoMusicSynthesizer(sampleRate: 48_000)
        let fft = MusicFFTProcessor()
        var ring = [Float](repeating: 0, count: MusicFFTProcessor.fftSize)
        var totalBeats = 0
        var peakEnergy: Float = 0

        // Simulate ~2 seconds at 60fps (120 frames)
        for _ in 0..<120 {
            let chunk = synth.render(frameCount: 800)
            XCTAssertTrue(chunk.mono.allSatisfy { $0.isFinite && abs($0) <= 1.0 })
            XCTAssertTrue(chunk.stereoBalance.isFinite && abs(chunk.stereoBalance) <= 1.0)
            ring.removeFirst(800)
            ring.append(contentsOf: chunk.mono)
            let frame = fft.process(monoSamples: ring, stereoBalance: chunk.stereoBalance, sampleRate: 48_000, dt: 1.0 / 60.0)
            if frame.beatTriggered { totalBeats += 1 }
            peakEnergy = max(peakEnergy, frame.energy)
        }
        XCTAssertGreaterThanOrEqual(totalBeats, 2)
        XCTAssertGreaterThan(peakEnergy, 0.25)
    }

    @MainActor
    func testWaterPoolSimulatesBeatImpulsesAndRendersPixels() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        let renderer = MusicAmbientRenderer()
        var settings = EffectConfiguration()
        settings.musicAmbient = true
        settings.musicVisual = .waterPool

        var beatFrame = MusicSpectrumFrame.silent
        beatFrame.bands = (0..<32).map { Float(0.8 - Double($0) * 0.015) }
        beatFrame.peaks = beatFrame.bands
        beatFrame.subBass = 0.85
        beatFrame.bass = 0.82
        beatFrame.mids = 0.55
        beatFrame.highs = 0.42
        beatFrame.energy = 0.68
        beatFrame.level = 0.72
        beatFrame.beatPulse = 1.0
        beatFrame.beatTriggered = true
        beatFrame.snareTriggered = true
        beatFrame.hatTriggered = true
        beatFrame.isSilent = false

        renderer.injectKeyImpulse(at: CGPoint(x: 960, y: 360), strength: 1.2)
        renderer.step(frame: beatFrame, dt: 1.0 / 60.0, now: 1.0, settings: settings)
        XCTAssertGreaterThan(renderer.shader.waterEnergy, 0.1)

        for i in 1...6 {
            var follow = beatFrame
            follow.beatTriggered = false
            follow.snareTriggered = false
            follow.hatTriggered = false
            renderer.step(frame: follow, dt: 1.0 / 60.0, now: 1.0 + Double(i) / 60.0, settings: settings)
        }

        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1920, pixelsHigh: 720,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(origin: .zero, size: Action75.canvas))
        renderer.draw(in: context.cgContext, now: 1.1, settings: settings, frame: beatFrame)

        let bytes = try XCTUnwrap(rep.bitmapData)
        XCTAssertTrue(UnsafeBufferPointer(start: bytes, count: rep.bytesPerPlane).contains { $0 != 0 })

        renderer.reset()
        XCTAssertEqual(renderer.shader.waterEnergy, 0)
    }

    @MainActor
    func testAllTwelveMusicVisualStylesRenderNonEmptyPixels() throws {
        let renderer = MusicAmbientRenderer()
        var frame = MusicSpectrumFrame.silent
        frame.bands = (0..<32).map { i in Float(0.35 + 0.55 * abs(sin(Double(i) * 0.25))) }
        frame.peaks = frame.bands.map { min(1, $0 + 0.1) }
        frame.waveform = (0..<64).map { i in Float(sin(Double(i) * 0.35) * 0.75) }
        frame.subBass = 0.78
        frame.bass = 0.74
        frame.mids = 0.62
        frame.highs = 0.54
        frame.energy = 0.66
        frame.level = 0.70
        frame.beatPulse = 0.88
        frame.snarePulse = 0.65
        frame.hatPulse = 0.52
        frame.beatTriggered = true
        frame.isSilent = false

        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1920, pixelsHigh: 720,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context

        let hasMetal = MTLCreateSystemDefaultDevice() != nil
        for style in MusicVisualStyle.allCases {
            if !hasMetal && [.waterPool, .auroraRibbons, .ferrofluid, .plasmaNebula, .cymatics, .radialPulse, .audioFire, .lavaLamp].contains(style) {
                continue
            }
            var settings = EffectConfiguration()
            settings.musicAmbient = true
            settings.musicVisual = style

            renderer.step(frame: frame, dt: 1.0 / 60.0, now: 2.0 + Double(style.rawValue) * 0.05, settings: settings)
            context.cgContext.clear(CGRect(origin: .zero, size: Action75.canvas))
            renderer.draw(in: context.cgContext, now: 2.0 + Double(style.rawValue) * 0.05, settings: settings, frame: frame)

            let bytes = try XCTUnwrap(rep.bitmapData)
            let hasPixels = UnsafeBufferPointer(start: bytes, count: rep.bytesPerPlane).contains { $0 != 0 }
            XCTAssertTrue(hasPixels, "Music visual style \(style.title) should render visible pixels")
        }
    }

    @MainActor
    func testBoardViewDrawsMusicAmbientWhenEnabledAndStaysDarkWhenDisabled() throws {
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

        func hasNonBlackPixelInKeyCenter(_ code: UInt16) throws -> Bool {
            let rect = try XCTUnwrap(Action75.rects[code])
            for y in Int(rect.minY + 25)..<Int(rect.maxY - 25) {
                for x in Int(rect.minX + 25)..<Int(rect.maxX - 25) {
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if c.redComponent > 0.03 || c.greenComponent > 0.03 || c.blueComponent > 0.03 {
                        return true
                    }
                }
            }
            return false
        }

        // Disabled by default: key interiors stay black (only fixed orientation markers render)
        board.cacheDisplay(in: board.bounds, to: bitmap)
        XCTAssertFalse(try hasNonBlackPixelInKeyCenter(0))
        XCTAssertFalse(try hasNonBlackPixelInKeyCenter(34))

        // Enabled with Demo Beat + Spectrum Bars: board draws audio-reactive visuals across bass keys
        board.effects.musicAudioSource = .demoBeat
        board.effects.musicVisual = .spectrumBars
        board.effects.musicAmbient = true
        defer { MusicAmbientController.shared.stop() }
        board.cacheDisplay(in: board.bounds, to: bitmap)
        XCTAssertTrue(try hasNonBlackPixelInKeyCenter(0))
    }
}

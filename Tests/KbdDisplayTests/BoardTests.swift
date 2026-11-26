import XCTest
import AppKit
import Metal
@testable import KbdDisplay

final class BoardTests: XCTestCase {
    func testMappedKeysUseNativeCanvasAndStaggeredRows() throws {
        let canvas = CGRect(origin: .zero, size: CGSize(width: 1920, height: 720))
        XCTAssertEqual(Action75.canvas, canvas.size)
        XCTAssertTrue(Action75.rects.values.allSatisfy(canvas.contains))
        let codes = Action75.rows.flatMap { $0.map(\.code) }
        XCTAssertEqual(Set(codes).count, codes.count)
        for (index, code) in [UInt16(105), 107, 117].enumerated() {
            XCTAssertEqual(Action75.rects[code], CGRect(x: (13 + index) * 120, y: 0, width: 120, height: 120))
            XCTAssertEqual(Action75.legends[code], ["PrtSc", "ScrLk", "Del"][index])
        }
        let i = try XCTUnwrap(Action75.rects[34])
        let k = try XCTUnwrap(Action75.rects[40])
        XCTAssertEqual(i.minY + i.height, k.minY)
        XCTAssertEqual(k.midX - i.midX, 30)
        for code: UInt16 in [34,38,40,37,32,31,35] { XCTAssertNotNil(Action75.rects[code]) }
    }

    @MainActor
    func testPausingClearsEffectsAndIgnoresEveryPressSourceUntilResumed() throws {
        let board = BoardView()
        board.effects.fireworks = true
        XCTAssertNotNil(board.pulse(0, source: .monitor))
        board.effectsPaused = true
        XCTAssertTrue(board.hits.isEmpty)
        for source: BoardView.Input in [.mouse, .local, .monitor, .plugin] {
            XCTAssertNil(board.pulse(3, source: source))
        }
        board.effectsPaused = false
        let resumed = try XCTUnwrap(board.pulse(3, source: .local))
        XCTAssertTrue(board.effects.fireworks)
        XCTAssertEqual(board.hits.count, 1)
        XCTAssertEqual(resumed.flameHeat, 0)
        XCTAssertEqual(resumed.start.y, resumed.end.y)
        XCTAssertEqual(resumed.end.x - resumed.start.x, 96)
    }

    @MainActor
    func testFunctionalHintDrawsLargeWhiteContentWithoutAKeycap() throws {
        _ = NSApplication.shared
        let board = BoardView(frame: CGRect(origin: .zero, size: Action75.canvas))
        let window = NSWindow(contentRect: board.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = board
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1920, pixelsHigh: 720,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        image.size = Action75.canvas
        let key = try XCTUnwrap(Action75.rects[34])
        func brightness(_ x: CGFloat, _ y: CGFloat) throws -> CGFloat {
            let color = try XCTUnwrap(image.colorAt(x: Int(x), y: Int(y))?.usingColorSpace(.deviceRGB))
            return max(color.redComponent, color.greenComponent, color.blueComponent)
        }
        func whiteBounds(in region: CGRect) -> CGRect {
            var bounds = CGRect.null
            for y in Int(region.minY)..<Int(region.maxY) {
                for x in Int(region.minX)..<Int(region.maxX) {
                    guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          min(color.redComponent, color.greenComponent, color.blueComponent) > 0.8 else { continue }
                    bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
            return bounds
        }
        board.hints = [KeyHint(keyCode: 34, label: "Brighter", symbol: "sun.max.fill")]
        board.cacheDisplay(in: board.bounds, to: image)
        let symbolArea = CGRect(x: key.minX, y: key.minY, width: key.width, height: 76)
        let labelArea = CGRect(x: key.minX, y: symbolArea.maxY, width: key.width, height: key.height - 76)
        XCTAssertGreaterThan(whiteBounds(in: symbolArea).height, 50)
        XCTAssertGreaterThan(whiteBounds(in: labelArea).width, 80)
        XCTAssertLessThan(try brightness(key.minX + 10, key.minY + 10), 0.02)
        XCTAssertLessThan(try brightness(key.minX - 1, key.midY), 0.02)
        board.hints = []
        board.cacheDisplay(in: board.bounds, to: image)
        XCTAssertTrue(whiteBounds(in: key).isNull)

        board.hints = [KeyHint(keyCode: 34, label: "Brighter", symbol: "sun.max.fill")]
        board.effects.reactiveKeys = true
        for layer in EffectLayer.allCases { board.effects[layer] = false }
        board.pulse(34, source: .mouse)
        board.cacheDisplay(in: board.bounds, to: image)
        XCTAssertFalse(whiteBounds(in: key).isNull)
        XCTAssertLessThan(try brightness(key.minX + 10, key.minY + 10), 0.02)
    }

    @MainActor
    func testCapturedBoardFillsTheNegotiatedDisplayMode() throws {
        let board = DisplayOutput().board
        board.frame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        // Esc, Home, left Control and right arrow sample the outer grid rows and columns.
        for (point, code): (CGPoint, UInt16) in [
            (CGPoint(x: 1, y: 1), 53), (CGPoint(x: 1599, y: 151), 115),
            (CGPoint(x: 1, y: 899), 59), (CGPoint(x: 1599, y: 899), 124)
        ] {
            XCTAssertEqual(board.key(at: point), code)
        }
    }

    @MainActor
    func testClippedEdgesMapToOutputAndLetterboxedPreview() throws {
        let clip = try XCTUnwrap(BoardClip(left: 150, right: 280, top: 130, bottom: 145))
        let output = DisplayOutput().board
        output.frame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let preview = BoardView(frame: CGRect(x: 0, y: 0, width: 960, height: 480))
        let previewFrame = CGRect(x: 0, y: 60, width: 960, height: 360)
        for (board, frame) in [(output, output.bounds), (preview, previewFrame)] {
            board.boardClip = clip
            // The four screen corners now land on 1, Delete, left Shift and right Shift.
            for (x, y, key): (CGFloat, CGFloat, UInt16) in [
                (frame.minX + 1, frame.minY + 1, 18), (frame.maxX - 1, frame.minY + 1, 51),
                (frame.minX + 1, frame.maxY - 1, 56), (frame.maxX - 1, frame.maxY - 1, 60)
            ] {
                XCTAssertEqual(board.key(at: CGPoint(x: x, y: y)), key)
            }
        }
        XCTAssertNil(preview.key(at: CGPoint(x: 50, y: 59)))
        XCTAssertNil(preview.key(at: CGPoint(x: 50, y: 421)))
    }

    func testClipValidationPersistenceAndLegacyOverscan() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(BoardClip.load(from: defaults), BoardClip(left: 32, right: 30, top: 14, bottom: 10))
        XCTAssertNil(BoardClip(left: -1, right: 0, top: 0, bottom: 0))
        XCTAssertNil(BoardClip(left: 100, right: 1820, top: 0, bottom: 0))
        XCTAssertNil(BoardClip(left: 0, right: 0, top: 200, bottom: Int.max))
        defaults.set([-240, -90, 2400, 900], forKey: "boardRect")
        XCTAssertEqual(BoardClip.load(from: defaults), BoardClip(left: 192, right: 192, top: 72, bottom: 72))
        let custom = try XCTUnwrap(BoardClip(left: 20, right: 35, top: 0, bottom: 1))
        custom.save(to: defaults)
        XCTAssertEqual(BoardClip.load(from: defaults), custom)
        BoardClip.none.save(to: defaults)
        XCTAssertEqual(BoardClip.load(from: defaults), .none)
    }

    func testMetalFoilSoftensAtEveryEdgeAndClears() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        let frames = BlastEffect.makeFrames()
        XCTAssertEqual(frames.count, 49)
        guard frames.count == 49 else { return }
        func centerColor(_ index: Int) throws -> NSColor {
            let bitmap = NSBitmapImageRep(cgImage: frames[index])
            return try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide/2, y: bitmap.pixelsHigh/2))
        }
        let early = try centerColor(2), late = try centerColor(9)
        XCTAssertGreaterThan(early.blueComponent, early.redComponent)
        XCTAssertGreaterThan(late.redComponent, late.blueComponent)
        let peakFrame = NSBitmapImageRep(cgImage: frames[5])
        // Equal radii along the axes and a 3:4:5 diagonal must have equal opacity.
        let axis = try XCTUnwrap(peakFrame.colorAt(x: 130, y: 80)).alphaComponent
        XCTAssertGreaterThan(axis, 0.3)
        for (x, y) in [(80, 130), (110, 120), (119, 49), (29, 80)] {
            XCTAssertEqual(try XCTUnwrap(peakFrame.colorAt(x: x, y: y)).alphaComponent, axis, accuracy: 0.025)
        }
        for (x, y) in [(0, 80), (159, 80), (80, 0), (80, 159)] {
            XCTAssertLessThan(try XCTUnwrap(peakFrame.colorAt(x: x, y: y)).alphaComponent, 0.01)
        }
        let last = try XCTUnwrap(frames.last?.dataProvider?.data) as Data
        XCTAssertTrue(last.allSatisfy { $0 == 0 })
    }

    func testPlasmaKernelsAndOverheatFlameBakeAndClear() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        for effect: BlastEffect.Effect in [.plasmaOrb, .plasmaWake, .plasmaFlameCold, .plasmaFlameHot] {
            let frames = BlastEffect.makeFrames(effect: effect)
            XCTAssertEqual(frames.count, 49, "Expected 49 frames for \(effect)")
            let last = try XCTUnwrap(frames.last?.dataProvider?.data) as Data
            XCTAssertTrue(last.allSatisfy { $0 == 0 }, "Final frame should fade to clear for \(effect)")
        }
        let hotFrames = BlastEffect.makeFrames(effect: .plasmaFlameHot)
        let hotPeak = NSBitmapImageRep(cgImage: try XCTUnwrap(hotFrames.dropFirst(16).first))
        var blueHotPixels = 0
        for y in stride(from: 0, to: hotPeak.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: hotPeak.pixelsWide, by: 2) {
                let color = try XCTUnwrap(hotPeak.colorAt(x: x, y: y))
                if color.alphaComponent > 0.3 && color.blueComponent > 0.7 && color.blueComponent > color.redComponent {
                    blueHotPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(blueHotPixels, 40)
    }

    func testFlameBakesAFullHeightPlumeWithAHotCoreAndFades() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        let frames = BlastEffect.makeFrames(effect: .flame)
        let peak = try XCTUnwrap(frames.dropFirst(frames.count / 3).first)
        let image = NSBitmapImageRep(cgImage: peak)
        var hot = 0, red = 0
        var bounds = CGRect.null
        for y in stride(from: 0, to: image.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: image.pixelsWide, by: 2) {
                let color = try XCTUnwrap(image.colorAt(x: x, y: y))
                if color.alphaComponent > 0.2 {
                    bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                    if color.greenComponent > 0.75 { hot += 1 }
                    if color.greenComponent < 0.5 && color.redComponent > 0.7 { red += 1 }
                }
            }
        }
        XCTAssertGreaterThan(bounds.height, CGFloat(image.pixelsHigh) * 0.6)
        XCTAssertGreaterThan(bounds.width, CGFloat(image.pixelsWide) * 0.42)
        XCTAssertGreaterThan(hot, 100)
        XCTAssertGreaterThan(red, 100)
        let last = try XCTUnwrap(frames.last?.dataProvider?.data) as Data
        XCTAssertTrue(last.allSatisfy { $0 == 0 })
    }

    @MainActor
    func testLiveBoardShaderRendersMultiHitMetaballsAndRepeatFlames() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1920, pixelsHigh: 720,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(origin: .zero, size: Action75.canvas))

        var history = KeyPressHistory()
        let sparks = BeamSpark.burst()
        let k1 = try XCTUnwrap(Action75.rects[0])
        let k2 = try XCTUnwrap(Action75.rects[1])
        let hit1 = history.record(key: k1, sparks: sparks, at: 0)
        let hit2 = history.record(key: k2, sparks: sparks, at: 0.05)
        let repeatHit = history.record(key: k2, sparks: sparks, at: 0.12)

        var settings = EffectConfiguration()
        settings.style = .liquidSDF
        BlastEffect.shared.draw([(hit1, 0.22), (hit2, 0.17), (repeatHit, 0.14)], settings: settings)
        let bytes = try XCTUnwrap(rep.bitmapData)
        XCTAssertTrue(UnsafeBufferPointer(start: bytes, count: rep.bytesPerPlane).contains { $0 != 0 })
    }

    @MainActor
    func testSingleKeyLightningIceAndFireEffectsDrawPixels() throws {
        let key = try XCTUnwrap(Action75.rects[34])
        var history = KeyPressHistory()
        let sparks = BeamSpark.burst()
        let hit = history.record(key: key, sparks: sparks, at: 0)

        func hasPixels(settings: EffectConfiguration, beam: KeyBeam? = nil) throws -> Bool {
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1920, pixelsHigh: 720,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            context.cgContext.clear(CGRect(origin: .zero, size: Action75.canvas))
            BlastEffect.shared.draw(beam ?? hit, age: 0.14, settings: settings)
            let bytes = try XCTUnwrap(rep.bitmapData)
            return UnsafeBufferPointer(start: bytes, count: rep.bytesPerPlane).contains { $0 != 0 }
        }

        var baseOff = EffectConfiguration()
        for layer in EffectLayer.allCases { baseOff[layer] = false }

        var lightningOnly = baseOff
        lightningOnly.lightning = true
        XCTAssertTrue(try hasPixels(settings: lightningOnly))

        var iceOnly = baseOff
        iceOnly.ice = true
        XCTAssertTrue(try hasPixels(settings: iceOnly))

        var waterOnly = baseOff
        waterOnly.waterWave = true
        XCTAssertTrue(try hasPixels(settings: waterOnly))

        var confettiOnly = baseOff
        confettiOnly.confetti = true
        XCTAssertTrue(try hasPixels(settings: confettiOnly))

        var blackHoleOnly = baseOff
        blackHoleOnly.blackHole = true
        XCTAssertTrue(try hasPixels(settings: blackHoleOnly))

        var fireSingleKey = baseOff
        fireSingleKey[.flame] = true
        fireSingleKey.fireRepeatOnly = false
        XCTAssertTrue(try hasPixels(settings: fireSingleKey))

        var fireRepeatOnly = baseOff
        fireRepeatOnly[.flame] = true
        fireRepeatOnly.fireRepeatOnly = true
        XCTAssertFalse(try hasPixels(settings: fireRepeatOnly))

        var random = baseOff
        random.randomSingleKeyEffects = true
        for style in EffectStyle.allCases {
            random.style = style
            XCTAssertFalse(try hasPixels(settings: random))
            for effect in SingleKeyEffect.allCases {
                var beam = hit
                beam.randomSingleKeyEffect = effect
                XCTAssertEqual(SingleKeyEffect.allCases.filter { random.shows($0, for: beam) }, [effect])
                XCTAssertTrue(try hasPixels(settings: random, beam: beam), "\(style), \(effect)")
            }
        }
    }

    @MainActor
    func testReactiveKeysStayDarkAtIdleAndIlluminateByDistanceOnTap() throws {
        _ = NSApplication.shared
        let board = BoardView(frame: CGRect(origin: .zero, size: Action75.canvas))
        let window = NSWindow(contentRect: board.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = board
        board.keycapPreview = .labeled

        var config = EffectConfiguration()
        for layer in EffectLayer.allCases { config[layer] = false }
        config.reactiveKeys = true
        board.effects = config

        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1920, pixelsHigh: 720,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        image.size = Action75.canvas

        func luma(of code: UInt16) throws -> CGFloat {
            let rect = try XCTUnwrap(Action75.rects[code])
            let color = try XCTUnwrap(image.colorAt(x: Int(rect.minX + 18), y: Int(rect.minY + 18))?.usingColorSpace(.deviceRGB))
            return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
        }

        // At idle, all keys must be completely dark (lights off)
        board.cacheDisplay(in: board.bounds, to: image)
        XCTAssertLessThan(try luma(of: 34), 0.01) // I
        XCTAssertLessThan(try luma(of: 32), 0.01) // U (adjacent to I)
        XCTAssertLessThan(try luma(of: 53), 0.01) // Esc (far away)

        // Tap I (code 34): I lights up brightest, adjacent U (32) glows dimly by distance, far Esc (53) stays dark
        board.pulse(34, source: .mouse)
        board.cacheDisplay(in: board.bounds, to: image)
        let tapped = try luma(of: 34)
        let adjacent = try luma(of: 32)
        let far = try luma(of: 53)
        XCTAssertGreaterThan(tapped, 0.08)
        XCTAssertGreaterThan(adjacent, 0.01)
        XCTAssertGreaterThan(tapped, adjacent)
        XCTAssertLessThan(far, 0.01)
    }

    @MainActor
    func testTransparentKeyLegendsUseTheirOwnColorAndLightOnDirectHits() throws {
        _ = NSApplication.shared
        let board = BoardView(frame: CGRect(origin: .zero, size: Action75.canvas))
        let window = NSWindow(contentRect: board.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = board
        for layer in EffectLayer.allCases { board.effects[layer] = false }

        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1920, pixelsHigh: 720,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        func render() { board.cacheDisplay(in: board.bounds, to: bitmap) }
        func brightestPixel(of code: UInt16) throws -> NSColor {
            let key = try XCTUnwrap(Action75.rects[code])
            var brightest = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1)
            for y in Int(key.midY - 23)..<Int(key.midY + 23) {
                for x in Int(key.midX - 40)..<Int(key.midX + 40) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          color.redComponent > brightest.redComponent else { continue }
                    brightest = color
                }
            }
            return brightest
        }

        render()
        XCTAssertLessThan(try brightestPixel(of: 34).redComponent, 0.01)
        board.effects.showKeyLegends = true
        render()
        let white = try brightestPixel(of: 34)
        XCTAssertGreaterThan(white.redComponent, 0.4)
        XCTAssertEqual(white.redComponent, white.greenComponent, accuracy: 0.02)
        XCTAssertGreaterThan(try brightestPixel(of: 49).redComponent, 0.4)

        board.effects[.keyLegendHue] = 0
        render()
        let red = try brightestPixel(of: 34)
        XCTAssertGreaterThan(red.redComponent, red.greenComponent + 0.25)
        board.effects[.keyLegendBrightness] = 0.3
        render()
        let dimmed = try brightestPixel(of: 34)
        XCTAssertLessThan(dimmed.redComponent, red.redComponent - 0.15)

        board.effects.reactiveKeys = true
        render()
        XCTAssertLessThan(try brightestPixel(of: 34).redComponent, 0.01)
        board.pulse(34, source: .mouse)
        render()
        XCTAssertGreaterThan(try brightestPixel(of: 34).redComponent, 0.2)
        XCTAssertLessThan(try brightestPixel(of: 32).redComponent, 0.01)
        board.resetBeamHistory(matching: nil)
        board.pulse(34, source: .mouse, at: ProcessInfo.processInfo.systemUptime - BlastEffect.duration)
        render()
        XCTAssertLessThan(try brightestPixel(of: 34).redComponent, 0.01)
    }

    @MainActor
    func testWaveTankAndConstellationEffectsSimulateRenderAndSettle() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1920, pixelsHigh: 720,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        let colors = EffectColorParams()

        // Wave Tank: drops ripple, renders non-empty caustics, and eventually settles to inactive
        let tank = WaveTankEffect()
        XCTAssertFalse(tank.isActive)
        tank.impulse(at: CGPoint(x: 960, y: 360), strength: 1.2)
        XCTAssertTrue(tank.isActive)
        for _ in 0..<8 { tank.step() }
        context.cgContext.clear(CGRect(origin: .zero, size: Action75.canvas))
        tank.draw(in: context.cgContext, colors: colors)
        let tankBytes = try XCTUnwrap(rep.bitmapData)
        XCTAssertTrue(UnsafeBufferPointer(start: tankBytes, count: rep.bytesPerPlane).contains { $0 != 0 })
        for _ in 0..<300 { tank.step() }
        XCTAssertFalse(tank.isActive)

        // Constellation: connects nearby keys into star graph & aurora triads, then expires
        let constellation = ConstellationEffect()
        XCTAssertFalse(constellation.isActive)
        constellation.addNode(at: CGPoint(x: 500, y: 300), keyCode: 0, at: 10.0)
        constellation.addNode(at: CGPoint(x: 680, y: 320), keyCode: 1, at: 10.1)
        constellation.addNode(at: CGPoint(x: 590, y: 450), keyCode: 2, at: 10.2)
        XCTAssertTrue(constellation.isActive)
        context.cgContext.clear(CGRect(origin: .zero, size: Action75.canvas))
        constellation.draw(in: context.cgContext, now: 10.5, colors: colors)
        let constBytes = try XCTUnwrap(rep.bitmapData)
        XCTAssertTrue(UnsafeBufferPointer(start: constBytes, count: rep.bytesPerPlane).contains { $0 != 0 })
        constellation.prune(now: 15.0)
        XCTAssertFalse(constellation.isActive)

        // Matrix Rain: spawns neon glyph cascades and expires cleanly
        let matrix = MatrixRainEffect()
        XCTAssertFalse(matrix.isActive)
        matrix.spawn(at: CGPoint(x: 960, y: 360), keyCode: 34, at: 20.0, strength: 1.0)
        XCTAssertTrue(matrix.isActive)
        context.cgContext.clear(CGRect(origin: .zero, size: Action75.canvas))
        matrix.draw(in: context.cgContext, now: 20.2, colors: colors, strength: 1.0)
        let matrixBytes = try XCTUnwrap(rep.bitmapData)
        XCTAssertTrue(UnsafeBufferPointer(start: matrixBytes, count: rep.bytesPerPlane).contains { $0 != 0 })
        matrix.prune(now: 23.0)
        XCTAssertFalse(matrix.isActive)

        // Fireworks: launches rocket and detonates into starburst, then expires cleanly
        let fireworks = FireworksEffect()
        XCTAssertFalse(fireworks.isActive)
        fireworks.launch(from: CGPoint(x: 960, y: 500), keyCode: 36, at: 30.0, strength: 1.0)
        XCTAssertTrue(fireworks.isActive)
        context.cgContext.clear(CGRect(origin: .zero, size: Action75.canvas))
        fireworks.draw(in: context.cgContext, now: 30.55, colors: colors, strength: 1.0)
        let fwBytes = try XCTUnwrap(rep.bitmapData)
        XCTAssertTrue(UnsafeBufferPointer(start: fwBytes, count: rep.bytesPerPlane).contains { $0 != 0 })
        fireworks.prune(now: 33.0)
        XCTAssertFalse(fireworks.isActive)
    }

    func testKeyboardSoundProfilesSynthesizeValidNonSilentWaveforms() {
        for profile in KeyboardSoundProfile.allCases {
            let samples = KeyboardSoundEngine.synthesizeSamples(profile: profile, tone: 0.5, variant: 1)
            XCTAssertGreaterThan(samples.count, 1000, "Profile \(profile) should synthesize audio samples")
            XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) <= 1.0 }, "Profile \(profile) samples must stay within [-1, 1]")
            let peak = samples.map { abs($0) }.max() ?? 0
            XCTAssertGreaterThan(peak, 0.1, "Profile \(profile) should have audible peak amplitude")
        }
    }

    @MainActor
    func testHitOutlineGlowsAndLeavesTheKeyFaceClear() throws {
        let key = CGRect(x: 16, y: 10, width: 300, height: 100)
        func alpha(_ age: Double, x: Int) throws -> CGFloat {
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 336, pixelsHigh: 120,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            context.cgContext.clear(CGRect(x: 0, y: 0, width: 336, height: 120))
            BlastEffect.drawKeyFlash(in: context.cgContext, key: key, age: age)
            return try XCTUnwrap(rep.colorAt(x: x, y: 60)).alphaComponent
        }
        XCTAssertEqual(try alpha(0, x: 165), 0)
        XCTAssertGreaterThan(try alpha(0, x: 24), 0.6)
        XCTAssertGreaterThan(try alpha(0, x: 20), 0)
        XCTAssertGreaterThan(try alpha(0, x: 307), 0.5)
        XCTAssertEqual(try alpha(0.64, x: 24), 0)
    }

    @MainActor
    func testHeldKeyOutlineFlashesSettlesAndClearsOnRelease() throws {
        _ = NSApplication.shared
        let board = BoardView(frame: CGRect(origin: .zero, size: Action75.canvas))
        let window = NSWindow(contentRect: board.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = board
        for layer in EffectLayer.allCases { board.effects[layer] = false }
        board.effects[.border] = true
        board.effects.showOrientationMarkers = false
        let bitmap = try XCTUnwrap(board.bitmapImageRepForCachingDisplay(in: board.bounds))

        func brightness(_ code: UInt16, inset: CGFloat = 7) throws -> CGFloat {
            board.cacheDisplay(in: board.bounds, to: bitmap)
            let key = try XCTUnwrap(Action75.rects[code])
            let scale = CGFloat(bitmap.pixelsWide) / Action75.canvas.width
            let color = try XCTUnwrap(bitmap.colorAt(x: Int((key.minX + inset) * scale), y: Int(key.midY * scale))?
                .usingColorSpace(.deviceRGB))
            return max(color.redComponent, color.greenComponent, color.blueComponent)
        }

        // The steady outline survives the entire traveling effect and duplicate key-down reports.
        let now = ProcessInfo.processInfo.systemUptime
        board.pulse(34, source: .monitor, tracksRelease: true, at: now - 2)
        let steady = try brightness(34)
        let steadyEdge = try brightness(34, inset: 10)
        XCTAssertGreaterThan(steady, 0.85)
        XCTAssertNil(board.pulse(34, source: .local, tracksRelease: true))
        XCTAssertEqual(try brightness(34), steady, accuracy: 0.02)
        board.releaseKey(34)
        XCTAssertLessThan(try brightness(34), 0.02)

        for style in EffectStyle.allCases {
            board.effects.style = style
            board.resetBeamHistory(matching: nil)
            board.pulse(34, source: .monitor, tracksRelease: true)
            XCTAssertGreaterThan(try brightness(34, inset: 10), steadyEdge + 0.2, "\(style)")
            board.releaseKey(34)
            XCTAssertLessThan(try brightness(34), 0.02, "\(style)")
        }
    }

    @MainActor
    func testKeyOutlineReleaseDelayExpiresAndRestartsOnTheNextRelease() throws {
        let board = BoardView(frame: CGRect(origin: .zero, size: Action75.canvas))
        board.effects[.border] = true
        board.effects.borderReleaseDelay = true
        board.effects[.borderReleaseDuration] = 0.5
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1920, pixelsHigh: 720,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap)).cgContext
        context.translateBy(x: 0, y: Action75.canvas.height)
        context.scaleBy(x: 1, y: -1)
        let key = try XCTUnwrap(Action75.rects[34])

        func brightness(at time: TimeInterval, inset: CGFloat = 7) throws -> CGFloat {
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            context.fill(board.bounds)
            board.drawKeyOutlines(in: context, now: time, colors: board.effects.colorParams)
            let color = try XCTUnwrap(bitmap.colorAt(x: Int(key.minX + inset), y: Int(key.midY))?.usingColorSpace(.deviceRGB))
            return max(color.redComponent, color.greenComponent, color.blueComponent)
        }

        board.pulse(34, source: .monitor, tracksRelease: true, at: 8)
        let held = try brightness(at: 10)
        let heldEdge = try brightness(at: 10, inset: 10)
        XCTAssertGreaterThan(held, 0.85)
        board.releaseKey(34, at: 10)
        board.releaseKey(34, at: 10.25)
        XCTAssertEqual(try brightness(at: 10.49), held, accuracy: 0.02)
        XCTAssertLessThan(try brightness(at: 10.5), 0.02)

        board.pulse(34, source: .monitor, tracksRelease: true, at: 11)
        board.releaseKey(34, at: 11.3)
        board.pulse(34, source: .monitor, tracksRelease: true, at: 11.4)
        XCTAssertGreaterThan(try brightness(at: 11.4, inset: 10), heldEdge + 0.2)
        XCTAssertEqual(try brightness(at: 12), held, accuracy: 0.02)
        board.releaseKey(34, at: 12)
        XCTAssertEqual(try brightness(at: 12.4), held, accuracy: 0.02)
        board.effects.borderReleaseDelay = false
        XCTAssertLessThan(try brightness(at: 12.4), 0.02)
    }

    @MainActor
    func testKeyOutlineMorphResizesAndRetargetsWithoutLeavingAnOutlineBehind() throws {
        let board = BoardView(frame: CGRect(origin: .zero, size: Action75.canvas))
        board.effects[.border] = true
        board.effects.borderMorphsBetweenKeys = true
        board.effects.borderReleaseDelay = true
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1920, pixelsHigh: 720,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap)).cgContext
        context.translateBy(x: 0, y: Action75.canvas.height)
        context.scaleBy(x: 1, y: -1)

        func render(at now: TimeInterval) {
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            context.fill(board.bounds)
            board.drawKeyOutlines(in: context, now: now, colors: board.effects.colorParams)
        }

        func brightness(at point: CGPoint) throws -> CGFloat {
            let color = try XCTUnwrap(bitmap.colorAt(x: Int(point.x), y: Int(point.y))?.usingColorSpace(.deviceRGB))
            return max(color.redComponent, color.greenComponent, color.blueComponent)
        }

        let a = try XCTUnwrap(Action75.rects[0])
        let space = try XCTUnwrap(Action75.rects[49])
        let i = try XCTUnwrap(Action75.rects[34])
        let aEdge = CGPoint(x: a.minX + 7, y: a.midY)
        let spaceEdge = CGPoint(x: space.maxX - 7, y: space.midY)
        let intermediateEdge = CGPoint(x: (a.maxX + space.maxX) * 0.5 - 7, y: (a.midY + space.midY) * 0.5)

        board.pulse(0, source: .monitor, tracksRelease: true, at: 1)
        board.releaseKey(0, at: 1.15)
        board.pulse(49, source: .monitor, tracksRelease: true, at: 1.2)
        render(at: 1.27)
        XCTAssertGreaterThan(try brightness(at: intermediateEdge), 0.8)
        XCTAssertLessThan(try brightness(at: aEdge), 0.02)
        XCTAssertLessThan(try brightness(at: spaceEdge), 0.02)

        board.releaseKey(49, at: 1.27)
        board.pulse(34, source: .mouse, at: 1.27)
        render(at: 1.27)
        XCTAssertGreaterThan(try brightness(at: intermediateEdge), 0.8)
        render(at: 1.42)
        XCTAssertLessThan(try brightness(at: intermediateEdge), 0.02)
        XCTAssertGreaterThan(try brightness(at: CGPoint(x: i.minX + 7, y: i.midY)), 0.8)

        // Two genuinely held keys each keep their outline after the morph.
        board.pulse(0, source: .monitor, tracksRelease: true, at: 2)
        board.pulse(49, source: .monitor, tracksRelease: true, at: 2.2)
        render(at: 2.4)
        XCTAssertGreaterThan(try brightness(at: aEdge), 0.8)
        XCTAssertGreaterThan(try brightness(at: spaceEdge), 0.8)

        board.clearHeldKeys()
        board.resetBeamHistory(matching: nil)
        board.pulse(0, source: .mouse, at: 3)
        board.pulse(49, source: .plugin, at: 3.2)
        board.pulse(49, source: .monitor, tracksRelease: true, at: 3.24)
        XCTAssertEqual(board.hits.map(\.code), [0, 49])
        render(at: 3.27)
        XCTAssertGreaterThan(try brightness(at: intermediateEdge), 0.8)
        render(at: 3.6)
        XCTAssertGreaterThan(try brightness(at: spaceEdge), 0.8)
    }

    @MainActor
    func testBeamsTravelBetweenKeysAndStayAtTheSourceOnRestrike() throws {
        let board = BoardView()
        for code: UInt16 in [0, 1, 35, 34, 40, 40, 0] { board.pulse(code, source: .mouse) }
        XCTAssertEqual(board.hits.count, 7)
        for index in 1...4 {
            let previous = board.hits[index-1]
            let hit = board.hits[index]
            let key = try XCTUnwrap(Action75.rects[hit.code])
            XCTAssertEqual(hit.beam.start, previous.beam.end)
            XCTAssertEqual(hit.beam.end, CGPoint(x: key.midX, y: key.midY))
            let projected = CGPoint(x: hit.beam.start.x + hit.beam.length * cos(hit.beam.heading),
                                    y: hit.beam.start.y + hit.beam.length * sin(hit.beam.heading))
            XCTAssertEqual(projected.x, key.midX, accuracy: 0.001)
            XCTAssertEqual(projected.y, key.midY, accuracy: 0.001)
        }
        XCTAssertGreaterThan(board.hits[2].beam.length, board.hits[1].beam.length * 4)
        XCTAssertEqual(board.hits[5].beam.length, 0)
        XCTAssertEqual(board.hits[5].beam.start, board.hits[4].beam.end)
        XCTAssertEqual(board.hits[6].beam.start, board.hits[5].beam.end)
        XCTAssertGreaterThan(board.hits[6].beam.length, 0)
    }

    func testRepeatedKeyHeatFollowsCadenceAndCoolsAfterRestOrKeyChange() {
        let key = CGRect(x: 0, y: 0, width: 120, height: 120)
        let next = key.offsetBy(dx: 120, dy: 0)
        var history = KeyPressHistory()
        func hit(_ t: Double, _ rect: CGRect) -> Double {
            history.record(key: rect, sparks: [], at: t).flameHeat
        }
        XCTAssertEqual(hit(0, key), 0)
        XCTAssertEqual(hit(0.1, key), 0)
        for repeatIndex in 1...6 {
            XCTAssertEqual(hit(0.1 + Double(repeatIndex) * 0.16, key),
                           min(1, Double(repeatIndex) * 0.2), accuracy: 0.001)
        }
        let slower = hit(1.60, key)
        XCTAssertGreaterThan(slower, 0)
        XCTAssertLessThan(slower, 1)
        XCTAssertEqual(hit(2.60, key), 0)
        XCTAssertGreaterThan(hit(2.75, key), 0)
        XCTAssertEqual(hit(2.9, next), 0)
        XCTAssertEqual(hit(3.0, next), 0)
    }

    @MainActor
    func testOverlappingInputSourcesProduceOneHopPerPress() {
        let board = BoardView()
        board.pulse(0, source: .local)
        board.pulse(1, source: .monitor)
        board.pulse(0, source: .plugin)
        board.pulse(1, source: .local)
        board.pulse(35, source: .plugin)
        XCTAssertEqual(board.hits.map(\.code), [0, 1, 35])
        XCTAssertEqual(board.hits.last?.beam.start, board.hits[1].beam.end)
    }

    @MainActor
    func testRandomEffectStaysWithEachKeyUntilItsLatestHitExpires() throws {
        let board = BoardView()
        board.effects.randomSingleKeyEffects = true
        let start = ProcessInfo.processInfo.systemUptime
        let first = try XCTUnwrap(board.pulse(34, source: .mouse, at: start))
        let firstEffect = try XCTUnwrap(first.randomSingleKeyEffect)
        var other = first
        other.randomSingleKeyEffect = firstEffect == .fire ? .ice : .fire

        let second = board.pulse(35, source: .mouse, matching: other, at: start + 0.1)
        XCTAssertEqual(second?.randomSingleKeyEffect, other.randomSingleKeyEffect)

        let repeatBeforeFade = board.pulse(34, source: .mouse, matching: other, at: start + 0.5)
        XCTAssertEqual(repeatBeforeFade?.randomSingleKeyEffect, firstEffect)
        let repeatAfterFirstHitExpires = board.pulse(34, source: .mouse, matching: other, at: start + 1)
        XCTAssertEqual(repeatAfterFirstHitExpires?.randomSingleKeyEffect, firstEffect)

        let hitAfterFade = board.pulse(34, source: .mouse, matching: other, at: start + 2)
        XCTAssertEqual(hitAfterFade?.randomSingleKeyEffect, other.randomSingleKeyEffect)
    }

    @MainActor
    func testRandomEffectsRespectRepeatOnly() {
        let board = BoardView()
        board.effects.randomSingleKeyEffects = true
        board.effects.fireRepeatOnly = true
        XCTAssertNil(board.pulse(34, source: .mouse)?.randomSingleKeyEffect)
        XCTAssertNotNil(board.pulse(34, source: .mouse)?.randomSingleKeyEffect)
        XCTAssertNil(board.pulse(35, source: .mouse)?.randomSingleKeyEffect)
    }

    func testSnapshotAndEmptyState() throws {
        let data = Data(#"{"provider":{"id":"org.example.keys","pid":42},"hints":[{"keyCode":34,"label":"Brighter","symbol":"sun.max.fill"}],"press":34}"#.utf8)
        let frame = try JSONDecoder().decode(HintFrame.self, from: data)
        XCTAssertEqual(frame.hints.first?.keyCode, frame.press)
        XCTAssertEqual(frame.hints.first?.label, "Brighter")
        let empty = try JSONDecoder().decode(HintFrame.self, from: Data(#"{"provider":{"id":"org.example.keys","pid":42},"hints":[]}"#.utf8))
        XCTAssertTrue(empty.hints.isEmpty)
        XCTAssertNil(empty.press)
    }

    func testModifierDetectionRecognizesLeftAndRightShiftOptionCommandControl() {
        let cases: [(code: UInt16, downFlag: UInt64, otherSideFlag: UInt64)] = [
            (56, 0x00020002, 0x00020004), // Left Shift vs Right Shift
            (60, 0x00020004, 0x00020002), // Right Shift vs Left Shift
            (58, 0x00080020, 0x00080040), // Left Option vs Right Option
            (61, 0x00080040, 0x00080020), // Right Option vs Left Option
            (55, 0x00100008, 0x00100010), // Left Command vs Right Command
            (54, 0x00100010, 0x00100008), // Right Command vs Left Command
            (59, 0x00040001, 0x00042000), // Left Control vs Right Control
            (62, 0x00042000, 0x00040001), // Right Control vs Left Control
        ]
        for entry in cases {
            XCTAssertTrue(PressMonitor.isModifierPressed(code: entry.code, rawFlags: entry.downFlag), "Expected press for \(entry.code)")
            XCTAssertFalse(PressMonitor.isModifierPressed(code: entry.code, rawFlags: 0), "Expected release for \(entry.code)")
            XCTAssertFalse(PressMonitor.isModifierPressed(code: entry.code, rawFlags: entry.otherSideFlag), "Opposite side should not trigger \(entry.code)")
        }
    }

    @MainActor
    func testOrientationMarkersGlowBrimFlowAround369AndBreathFlowAroundFJ() throws {
        _ = NSApplication.shared
        let board = BoardView(frame: CGRect(origin: .zero, size: Action75.canvas))
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1920, pixelsHigh: 720,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: image)).cgContext
        context.translateBy(x: 0, y: Action75.canvas.height)
        context.scaleBy(x: 1, y: -1)

        func render(at time: TimeInterval, reduceMotion: Bool = false) {
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            context.fill(board.bounds)
            board.drawOrientationMarkers(in: context, now: time, reduceMotion: reduceMotion)
        }

        func brightnessAt(_ x: Int, _ y: Int, file: StaticString = #filePath, line: UInt = #line) throws -> CGFloat {
            let color = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), file: file, line: line)
            return max(color.redComponent, max(color.greenComponent, color.blueComponent))
        }

        func borderPoints(for rect: CGRect, inset: CGFloat) -> [CGPoint] {
            let tile = rect.insetBy(dx: inset, dy: inset)
            return [
                CGPoint(x: tile.midX, y: tile.minY), // top
                CGPoint(x: tile.maxX, y: tile.midY), // right
                CGPoint(x: tile.midX, y: tile.maxY), // bottom
                CGPoint(x: tile.minX, y: tile.midY)  // left
            ]
        }

        // 1. Digits 3 (20), 6 (22), 9 (25): bold glow brim around outline with flowing highlight
        render(at: 0.4)
        for code: UInt16 in [20, 22, 25] {
            let rect = try XCTUnwrap(Action75.rects[code])
            for pt in borderPoints(for: rect, inset: 11) {
                XCTAssertGreaterThan(try brightnessAt(Int(pt.x), Int(pt.y)), 0.55)
            }
            XCTAssertLessThan(try brightnessAt(Int(rect.midX), Int(rect.midY)), 0.02)
        }
        for adjacentNonTarget: UInt16 in [21, 26, 29] {
            let rect = try XCTUnwrap(Action75.rects[adjacentNonTarget])
            XCTAssertLessThan(try brightnessAt(Int(rect.midX), Int(rect.midY)), 0.02)
        }

        var digitBrightestSides: Set<Int> = []
        for t in [0.0, 0.6, 1.2, 1.8] {
            render(at: t)
            let rect = try XCTUnwrap(Action75.rects[20])
            let sides = try borderPoints(for: rect, inset: 11).map { try brightnessAt(Int($0.x), Int($0.y)) }
            if let maxIdx = sides.enumerated().max(by: { $0.element < $1.element })?.offset {
                digitBrightestSides.insert(maxIdx)
            }
        }
        XCTAssertGreaterThan(digitBrightestSides.count, 1)

        // 2. Homing keys F (3) and J (38): breathing aura + flowing perimeter highlight
        for code: UInt16 in [3, 38] {
            let rect = try XCTUnwrap(Action75.rects[code])
            let pts = borderPoints(for: rect, inset: 5)

            render(at: 0.0)
            let troughSum = try pts.reduce(CGFloat(0)) { $0 + (try brightnessAt(Int($1.x), Int($1.y))) }
            XCTAssertLessThan(try brightnessAt(Int(rect.midX), Int(rect.midY)), 0.02)

            render(at: 1.6)
            let peakSum = try pts.reduce(CGFloat(0)) { $0 + (try brightnessAt(Int($1.x), Int($1.y))) }
            XCTAssertLessThan(try brightnessAt(Int(rect.midX), Int(rect.midY)), 0.02)
            XCTAssertGreaterThan(peakSum, troughSum + 0.35)

            var brightestSides: Set<Int> = []
            for t in [0.0, 0.65, 1.3, 1.95] {
                render(at: t)
                let sides = try pts.map { try brightnessAt(Int($0.x), Int($0.y)) }
                if let maxIdx = sides.enumerated().max(by: { $0.element < $1.element })?.offset {
                    brightestSides.insert(maxIdx)
                }
            }
            XCTAssertGreaterThan(brightestSides.count, 1)
        }

        let homingKey = try XCTUnwrap(Action75.rects[3])
        let sample = borderPoints(for: homingKey, inset: 5)[0]
        render(at: 0, reduceMotion: true)
        let steady = try brightnessAt(Int(sample.x), Int(sample.y))
        XCTAssertGreaterThan(steady, 0.1)
        render(at: 1.6, reduceMotion: true)
        XCTAssertEqual(try brightnessAt(Int(sample.x), Int(sample.y)), steady, accuracy: 0.01)

        board.effects.showOrientationMarkers = false
        render(at: 1.6)
        for code: UInt16 in [20, 22, 25, 3, 38] {
            let rect = try XCTUnwrap(Action75.rects[code])
            let inset: CGFloat = code == 3 || code == 38 ? 5 : 11
            for point in borderPoints(for: rect, inset: inset) {
                XCTAssertLessThan(try brightnessAt(Int(point.x), Int(point.y)), 0.02)
            }
        }
    }
}

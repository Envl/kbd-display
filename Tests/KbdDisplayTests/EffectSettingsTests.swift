import AppKit
import XCTest
@testable import KbdDisplay

final class EffectSettingsTests: XCTestCase {
    func testPauseSurvivesRelaunchAndKeepsEffectPreferences() throws {
        let suite = "effect-pause-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EffectSettingsStore(defaults: defaults)
        XCTAssertFalse(store.isPaused)
        store.value.musicAmbient = true
        let selected = store.value
        store.isPaused = true
        let reopened = EffectSettingsStore(defaults: defaults)
        XCTAssertTrue(reopened.isPaused)
        XCTAssertEqual(reopened.value, selected)
        reopened.isPaused = false
        XCTAssertEqual(reopened.value, selected)
        XCTAssertFalse(EffectSettingsStore(defaults: defaults).isPaused)
    }

    func testSettingsPersistNotifyAndReset() throws {
        let suite = "kbd-display-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EffectSettingsStore(defaults: defaults)
        var observed: EffectConfiguration?
        store.onChange = { observed = $0 }
        XCTAssertFalse(store.value.borderMorphsBetweenKeys)
        store.value.borderMorphsBetweenKeys = true
        XCTAssertFalse(store.value.borderReleaseDelay)
        XCTAssertEqual(store.value[.borderReleaseDuration], 0.25, accuracy: 0.0001)
        store.value.borderReleaseDelay = true
        store.value[.borderReleaseDuration] = 0.6
        XCTAssertTrue(store.value.showOrientationMarkers)
        store.value.showOrientationMarkers = false
        XCTAssertEqual(observed?.showOrientationMarkers, false)
        XCTAssertNil(store.value.travelBlade)
        store.value.travelBlade = .plasmaKatana
        store.value.style = .classic
        store.value[.glow] = false
        store.value[.startingFraction] = 0.42
        store.value[.heatTaps] = 7
        store.value[.particleSize] = 100
        store.value[.hue] = 0.25
        store.value[.chroma] = 1.5
        store.value[.intensity] = 1.35
        store.value.fireRepeatOnly = true
        store.value.randomSingleKeyEffects = true
        store.value.lightning = true
        store.value.ice = true
        store.value.waterWave = true
        store.value.confetti = true
        store.value.blackHole = true
        store.value.reactiveKeys = true
        store.value.showKeyLegends = true
        store.value[.keyLegendBrightness] = 0.35
        store.value[.keyLegendHue] = 0.7
        store.value.waveTank = true
        store.value.constellation = true
        store.value.matrixRain = true
        store.value.fireworks = true
        store.value[.boardEffectStrength] = 1.4
        store.value.soundEnabled = true
        store.value.soundProfile = .typewriter
        store.value[.soundVolume] = 1.15
        store.value[.soundPitch] = 0.85
        store.value[.soundTone] = 0.75
        store.value.musicAmbient = true
        store.value.musicVisual = .ferrofluid
        store.value.musicAudioSource = .demoBeat
        store.value.musicAutoCycle = true
        store.value[.musicSensitivity] = 1.45
        store.value[.musicIntensity] = 1.15
        store.value[.musicReactivity] = 1.55
        XCTAssertTrue(store.value.dictationVoiceBlob)
        store.value.dictationVoiceBlob = false
        store.value.rollPalette()
        let rolledSeed = store.value.paletteSeed
        XCTAssertGreaterThan(rolledSeed, 0)
        XCTAssertFalse(store.value.hasDefaultColors)
        XCTAssertEqual(store.value.style, .classic)
        XCTAssertEqual(store.value[.particleSize], 2)
        XCTAssertEqual(store.value[.hue], 0.25, accuracy: 0.0001)
        XCTAssertEqual(store.value[.chroma], 1.5, accuracy: 0.0001)
        XCTAssertEqual(store.value[.intensity], 1.35, accuracy: 0.0001)
        XCTAssertTrue(store.value.lightning)
        XCTAssertTrue(store.value.ice)
        XCTAssertTrue(store.value.waterWave)
        XCTAssertTrue(store.value.confetti)
        XCTAssertTrue(store.value.blackHole)
        XCTAssertTrue(store.value.reactiveKeys)
        XCTAssertTrue(store.value.waveTank)
        XCTAssertTrue(store.value.constellation)
        XCTAssertTrue(store.value.matrixRain)
        XCTAssertTrue(store.value.fireworks)
        XCTAssertTrue(store.value.soundEnabled)
        XCTAssertEqual(store.value.soundProfile, .typewriter)
        XCTAssertEqual(observed, store.value)
        let restored = EffectSettingsStore(defaults: defaults)
        XCTAssertEqual(restored.value, store.value)
        XCTAssertEqual(restored.value.travelBlade, .plasmaKatana)
        XCTAssertEqual(restored.value.style, .classic)
        XCTAssertTrue(restored.value.borderMorphsBetweenKeys)
        XCTAssertTrue(restored.value.borderReleaseDelay)
        XCTAssertEqual(restored.value[.borderReleaseDuration], 0.6, accuracy: 0.0001)
        XCTAssertEqual(restored.value.paletteSeed, rolledSeed)
        XCTAssertTrue(restored.value.fireRepeatOnly)
        XCTAssertTrue(restored.value.randomSingleKeyEffects)
        XCTAssertTrue(restored.value.lightning)
        XCTAssertTrue(restored.value.ice)
        XCTAssertTrue(restored.value.waterWave)
        XCTAssertTrue(restored.value.confetti)
        XCTAssertTrue(restored.value.blackHole)
        XCTAssertTrue(restored.value.reactiveKeys)
        XCTAssertTrue(restored.value.showKeyLegends)
        XCTAssertFalse(restored.value.showOrientationMarkers)
        XCTAssertEqual(restored.value[.keyLegendBrightness], 0.35, accuracy: 0.0001)
        XCTAssertEqual(restored.value[.keyLegendHue], 0.7, accuracy: 0.0001)
        XCTAssertTrue(restored.value.waveTank)
        XCTAssertTrue(restored.value.constellation)
        XCTAssertTrue(restored.value.matrixRain)
        XCTAssertTrue(restored.value.fireworks)
        XCTAssertEqual(restored.value[.boardEffectStrength], 1.4, accuracy: 0.0001)
        XCTAssertTrue(restored.value.soundEnabled)
        XCTAssertEqual(restored.value.soundProfile, .typewriter)
        XCTAssertEqual(restored.value[.soundVolume], 1.15, accuracy: 0.0001)
        XCTAssertEqual(restored.value[.soundPitch], 0.85, accuracy: 0.0001)
        XCTAssertEqual(restored.value[.soundTone], 0.75, accuracy: 0.0001)
        XCTAssertTrue(restored.value.musicAmbient)
        XCTAssertEqual(restored.value.musicVisual, .ferrofluid)
        XCTAssertEqual(restored.value.musicAudioSource, .demoBeat)
        XCTAssertTrue(restored.value.musicAutoCycle)
        XCTAssertEqual(restored.value[.musicSensitivity], 1.45, accuracy: 0.0001)
        XCTAssertEqual(restored.value[.musicIntensity], 1.15, accuracy: 0.0001)
        XCTAssertEqual(restored.value[.musicReactivity], 1.55, accuracy: 0.0001)
        XCTAssertFalse(restored.value.dictationVoiceBlob)
        XCTAssertFalse(restored.value[.glow])
        XCTAssertTrue(restored.value[.border])
        restored.value.resetColors()
        XCTAssertTrue(restored.value.hasDefaultColors)
        XCTAssertEqual(restored.value.paletteSeed, 0)
        XCTAssertEqual(restored.value[.hue], 0)
        XCTAssertEqual(restored.value[.chroma], 1)
        XCTAssertEqual(restored.value[.intensity], 1)
        restored.value = EffectConfiguration()
        XCTAssertEqual(EffectSettingsStore(defaults: defaults).value, EffectConfiguration())
        XCTAssertEqual(EffectSettingsStore(defaults: defaults).value.style, .default)
        XCTAssertTrue(EffectSettingsStore(defaults: defaults).value.showOrientationMarkers)
    }

    func testColorControlsAndDiceRollTransformPaletteAndShaders() throws {
        var config = EffectConfiguration()
        let baseParams = config.colorParams
        let baseSample = try XCTUnwrap(baseParams.samplePalette(at: 0.3).usingColorSpace(.sRGB))

        // Chroma = 0 produces achromatic/monochrome output
        config[.chroma] = 0
        let monoSample = try XCTUnwrap(config.colorParams.samplePalette(at: 0.3).usingColorSpace(.sRGB))
        XCTAssertEqual(monoSample.redComponent, monoSample.greenComponent, accuracy: 0.001)
        XCTAssertEqual(monoSample.greenComponent, monoSample.blueComponent, accuracy: 0.001)

        // Rolling the dice changes the palette seed and sampled colors
        config.resetColors()
        config.rollPalette()
        let firstRoll = config.paletteSeed
        let rolledSample = try XCTUnwrap(config.colorParams.samplePalette(at: 0.3).usingColorSpace(.sRGB))
        XCTAssertNotEqual(firstRoll, 0)
        let diff = abs(baseSample.redComponent - rolledSample.redComponent)
            + abs(baseSample.greenComponent - rolledSample.greenComponent)
            + abs(baseSample.blueComponent - rolledSample.blueComponent)
        XCTAssertGreaterThan(diff, 0.02)

        config.rollPalette()
        XCTAssertNotEqual(config.paletteSeed, firstRoll)
        config.resetColors()
        XCTAssertTrue(config.hasDefaultColors)
        XCTAssertEqual(config.colorParams, baseParams)
    }

    func testAllEffectStylesRespectLayerToggles() throws {
        let first = CGRect(x: 80, y: 290, width: 120, height: 120)
        let second = first.offsetBy(dx: 160, dy: 0)
        var history = KeyPressHistory()
        let sparks = BeamSpark.burst()
        _ = history.record(key: first, sparks: sparks, at: 0)
        let travel = history.record(key: second, sparks: sparks, at: 0.1)
        let flame = history.record(key: second, sparks: sparks, at: 0.2)

        @MainActor
        func hasPixels(_ beam: KeyBeam, settings: EffectConfiguration) throws -> Bool {
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            context.cgContext.clear(CGRect(x: 0, y: 0, width: 512, height: 512))
            BlastEffect.shared.draw(beam, age: 0.17, settings: settings)
            let bytes = try XCTUnwrap(rep.bitmapData)
            return UnsafeBufferPointer(start: bytes, count: rep.bytesPerPlane).contains { $0 != 0 }
        }

        for style in EffectStyle.allCases {
            var off = EffectConfiguration()
            off.style = style
            for layer in EffectLayer.allCases { off[layer] = false }
            for beam in [travel, flame] {
                XCTAssertFalse(try MainActor.assumeIsolated { try hasPixels(beam, settings: off) }, "Style \(style) should be empty when all layers are off")
            }
            for blade in BladeStyle.allCases {
                var selected = off
                selected.travelBlade = blade
                XCTAssertFalse(try MainActor.assumeIsolated { try hasPixels(travel, settings: selected) })
                selected[.glow] = true
                XCTAssertTrue(try MainActor.assumeIsolated { try hasPixels(travel, settings: selected) })
                XCTAssertFalse(try MainActor.assumeIsolated { try hasPixels(flame, settings: selected) })
            }
            for layer in EffectLayer.allCases {
                var only = off
                only[layer] = true
                XCTAssertTrue(try MainActor.assumeIsolated { try hasPixels(layer == .flame ? flame : travel, settings: only) }, "Style \(style) layer \(layer) should draw pixels")
            }
        }
    }

    func testTapSettingChangesFlameBuildup() {
        var history = KeyPressHistory()
        let key = CGRect(x: 0, y: 0, width: 120, height: 120)
        let hits = (0..<5).map { i in
            history.record(key: key, sparks: [], at: Double(i) * 0.1, tapsToFullHeat: 2).flameHeat
        }
        XCTAssertEqual(hits, [0, 0, 0.5, 1, 1])
    }

    @MainActor
    func testDisablingLayersRemovesGlowAndRepeatFlame() throws {
        let first = CGRect(x: 80, y: 290, width: 120, height: 120)
        let second = first.offsetBy(dx: 160, dy: 0)
        var history = KeyPressHistory()
        let sparks = BeamSpark.burst()
        _ = history.record(key: first, sparks: sparks, at: 0)
        let travel = history.record(key: second, sparks: sparks, at: 0.1)
        let flame = history.record(key: second, sparks: sparks, at: 0.2)
        var off = EffectConfiguration()
        for layer in EffectLayer.allCases { off[layer] = false }

        func hasPixels(_ beam: KeyBeam, settings: EffectConfiguration) throws -> Bool {
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            context.cgContext.clear(CGRect(x: 0, y: 0, width: 512, height: 512))
            BlastEffect.shared.draw(beam, age: 0.17, settings: settings)
            let bytes = try XCTUnwrap(rep.bitmapData)
            return UnsafeBufferPointer(start: bytes, count: rep.bytesPerPlane).contains { $0 != 0 }
        }
        for beam in [travel, flame] { XCTAssertFalse(try hasPixels(beam, settings: off)) }
        for layer in EffectLayer.allCases {
            var only = off
            only[layer] = true
            XCTAssertTrue(try hasPixels(layer == .flame ? flame : travel, settings: only))
        }
    }
}

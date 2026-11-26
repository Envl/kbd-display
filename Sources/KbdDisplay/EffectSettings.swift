import AppKit
import Combine
import Foundation
import simd

enum EffectStyle: Int, CaseIterable {
    case classic = 0
    case plasma = 1
    case liquidSDF = 2

    static let `default`: EffectStyle = .liquidSDF

    var title: String {
        switch self {
        case .classic: return "Classic"
        case .plasma: return "Plasma"
        case .liquidSDF: return "Liquid"
        }
    }
}

enum KeyboardSoundProfile: Int, CaseIterable {
    case thock = 0
    case clicky = 1
    case tactile = 2
    case typewriter = 3
    case synth = 4

    static let `default`: KeyboardSoundProfile = .thock

    var title: String {
        switch self {
        case .thock: return "Thock"
        case .clicky: return "Clicky"
        case .tactile: return "Tactile"
        case .typewriter: return "Typewriter"
        case .synth: return "Synth"
        }
    }
}

enum MusicVisualStyle: Int, CaseIterable {
    case waterPool = 0
    case spectrumBars = 1
    case auroraRibbons = 2
    case ferrofluid = 3
    case plasmaNebula = 4
    case cymatics = 5
    case keyMatrixEQ = 6
    case oscilloscope = 7
    case radialPulse = 8
    case audioFire = 9
    case starfieldWarp = 10
    case lavaLamp = 11

    static let `default`: MusicVisualStyle = .waterPool

    var title: String {
        switch self {
        case .waterPool: return "Water Pool"
        case .spectrumBars: return "Spectrum Bars"
        case .auroraRibbons: return "Aurora"
        case .ferrofluid: return "Ferrofluid"
        case .plasmaNebula: return "Plasma Nebula"
        case .cymatics: return "Cymatics"
        case .keyMatrixEQ: return "Key Matrix EQ"
        case .oscilloscope: return "Oscilloscope"
        case .radialPulse: return "Radial Pulse"
        case .audioFire: return "Audio Fire"
        case .starfieldWarp: return "Starfield Warp"
        case .lavaLamp: return "Lava Lamp"
        }
    }

    var symbol: String {
        switch self {
        case .waterPool: return "drop.fill"
        case .spectrumBars: return "chart.bar.fill"
        case .auroraRibbons: return "wind"
        case .ferrofluid: return "circle.hexagongrid.fill"
        case .plasmaNebula: return "sparkles"
        case .cymatics: return "waveform.path.ecg"
        case .keyMatrixEQ: return "keyboard.fill"
        case .oscilloscope: return "waveform"
        case .radialPulse: return "scope"
        case .audioFire: return "flame.fill"
        case .starfieldWarp: return "rays"
        case .lavaLamp: return "bubbles.and.sparkles.fill"
        }
    }
}

enum MusicAudioSource: Int, CaseIterable {
    case systemAudio = 0
    case microphone = 1
    case demoBeat = 2

    static let `default`: MusicAudioSource = .systemAudio

    var title: String {
        switch self {
        case .systemAudio: return "System Audio"
        case .microphone: return "Mic"
        case .demoBeat: return "Demo"
        }
    }
}

enum EffectLayer: String, CaseIterable {
    case glow, border, particles, flame

    var title: String {
        switch self {
        case .glow: return "Traveling glow"
        case .border: return "Key outline"
        case .particles: return "Sparks and embers"
        case .flame: return "Repeat-key flame"
        }
    }

    var controls: [EffectControl] {
        switch self {
        case .glow: return [.glowSize]
        case .border: return [.borderBrightness]
        case .particles: return [.particleDensity, .particleSize]
        case .flame: return [.startingFraction, .peakScale, .heatTaps]
        }
    }
}

enum EffectControl: String {
    case glowSize, borderBrightness, particleDensity, particleSize, startingFraction, peakScale, heatTaps
    case borderReleaseDuration
    case hue, chroma, intensity
    case keyLegendBrightness, keyLegendHue
    case boardEffectStrength
    case soundVolume, soundPitch, soundTone
    case musicSensitivity, musicIntensity, musicReactivity

    static let colorControls: [EffectControl] = [.hue, .chroma, .intensity]
    static let keyLegendControls: [EffectControl] = [.keyLegendBrightness, .keyLegendHue]
    static let soundControls: [EffectControl] = [.soundVolume, .soundPitch, .soundTone]
    static let musicControls: [EffectControl] = [.musicSensitivity, .musicIntensity, .musicReactivity]
    static let extraControls: [EffectControl] = [.boardEffectStrength, .borderReleaseDuration]
        + keyLegendControls + soundControls + musicControls

    var title: String {
        switch self {
        case .glowSize, .particleSize: return "Size"
        case .borderBrightness, .keyLegendBrightness: return "Brightness"
        case .borderReleaseDuration: return "Fade delay"
        case .particleDensity: return "Amount"
        case .startingFraction: return "Starting size"
        case .peakScale: return "Maximum size"
        case .heatTaps: return "Taps to maximum"
        case .hue, .keyLegendHue: return "Color tone"
        case .chroma: return "Color richness"
        case .intensity: return "Intensity"
        case .boardEffectStrength: return "Strength"
        case .soundVolume: return "Volume"
        case .soundPitch: return "Pitch"
        case .soundTone: return "Crispness"
        case .musicSensitivity: return "Sensitivity"
        case .musicIntensity: return "Brightness"
        case .musicReactivity: return "Reactivity"
        }
    }

    var defaultValue: Double {
        switch self {
        case .borderReleaseDuration: return 0.25
        case .startingFraction: return 0.22
        case .heatTaps: return 5
        case .hue: return 0
        case .keyLegendBrightness: return 0.6
        case .keyLegendHue: return -0.01
        case .soundVolume: return 0.75
        case .soundTone: return 0.50
        case .musicIntensity: return 0.85
        default: return 1
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .borderBrightness: return 0.05...1
        case .borderReleaseDuration: return 0.05...2
        case .startingFraction: return 0.05...1
        case .heatTaps: return 1...15
        case .hue: return -0.5...0.5
        case .keyLegendBrightness: return 0...1
        case .keyLegendHue: return defaultValue...1
        case .chroma: return 0...2
        case .intensity: return 0.25...2
        case .boardEffectStrength: return 0.25...2
        case .soundVolume: return 0.05...1.5
        case .soundPitch: return 0.5...1.5
        case .soundTone: return 0...1
        case .musicSensitivity: return 0.25...2.5
        case .musicIntensity: return 0.15...1.5
        case .musicReactivity: return 0.25...2.0
        default: return 0.25...2
        }
    }

    var step: Double {
        switch self {
        case .heatTaps: return 1
        case .startingFraction, .hue, .keyLegendHue: return 0.01
        default: return 0.05
        }
    }

    func bounded(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        let clamped = min(range.upperBound, max(range.lowerBound, value))
        return self == .heatTaps ? clamped.rounded() : clamped
    }

    func formattedValue(_ value: Double) -> String {
        switch self {
        case .heatTaps:
            return "\(Int(value))"
        case .borderReleaseDuration:
            return "\(value.formatted(.number.precision(.fractionLength(2)))) s"
        case .hue:
            let degrees = Int((value * 360).rounded())
            return degrees > 0 ? "+\(degrees)°" : "\(degrees)°"
        case .keyLegendHue:
            return value < 0 ? "White" : "\(Int((value * 360).rounded()))°"
        default:
            return "\(Int((value * 100).rounded()))%"
        }
    }
}

/// GPU-ready 48-byte color parameters shared by Metal kernels and CoreGraphics vector layers.
struct EffectColorParams: Equatable {
    /// xyz = cosine palette offset A, w = hue shift in turns (-0.5...0.5)
    var palA: SIMD4<Float>
    /// xyz = cosine palette amplitude B, w = chroma multiplier (0...2)
    var palB: SIMD4<Float>
    /// xyz = cosine palette phase D, w = intensity multiplier (0.25...2)
    var palD: SIMD4<Float>

    init(settings: EffectConfiguration = EffectConfiguration()) {
        let hue = Float(settings[.hue])
        let chroma = Float(settings[.chroma])
        let intensity = Float(settings[.intensity])
        let seed = settings.paletteSeed

        if seed == 0 {
            palA = SIMD4<Float>(0.38103930, 0.17971327, 0.38240391, hue)
            palB = SIMD4<Float>(0.70256774, 0.95307879, 0.70069124, chroma)
            palD = SIMD4<Float>(0.61018468, 0.75327672, 0.89134032, intensity)
        } else {
            var state = UInt64(bitPattern: Int64(seed)) &* 0x9E3779B97F4A7C15
            func nextUnit() -> Float {
                state &+= 0x9E3779B97F4A7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
                z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
                z = z ^ (z >> 31)
                return Float(z >> 40) / Float(1 << 24)
            }
            func next(in range: ClosedRange<Float>) -> Float {
                range.lowerBound + (range.upperBound - range.lowerBound) * nextUnit()
            }
            let d0 = nextUnit()
            let d1 = fmod(d0 + next(in: 0.14...0.36), 1.0)
            let d2 = fmod(d0 + next(in: 0.34...0.66), 1.0)
            palA = SIMD4<Float>(next(in: 0.34...0.52), next(in: 0.26...0.48), next(in: 0.34...0.52), hue)
            palB = SIMD4<Float>(next(in: 0.66...0.94), next(in: 0.68...0.96), next(in: 0.66...0.94), chroma)
            palD = SIMD4<Float>(d0, d1, d2, intensity)
        }
    }

    var hueShift: Float { palA.w }
    var chroma: Float { palB.w }
    var intensity: Float { palD.w }
    /// Secondary hue offset for fixed-palette elements (flames, borders, sparks) when a custom palette is rolled.
    var AuxHueShift: Float {
        let baseD0: Float = 0.61018468
        let rolledOffset = palD.x - baseD0
        return hueShift + rolledOffset
    }

    func grade(_ rgb: SIMD3<Float>, extraHue: Float = 0) -> SIMD3<Float> {
        let totalHue = hueShift + extraHue
        var c = rgb
        if abs(totalHue) > 1e-5 {
            let angle = totalHue * 2.0 * .pi
            let cosA = cos(angle), sinA = sin(angle)
            let k = SIMD3<Float>(repeating: 0.57735027)
            c = c * cosA + cross(k, c) * sinA + k * dot(k, c) * (1.0 - cosA)
        }
        if abs(chroma - 1.0) > 1e-5 {
            let luma = dot(c, SIMD3<Float>(0.2126, 0.7152, 0.0722))
            c = SIMD3<Float>(repeating: luma) + (c - SIMD3<Float>(repeating: luma)) * chroma
        }
        return simd_clamp(c * intensity, .zero, SIMD3<Float>(repeating: 1.0))
    }

    func samplePalette(at t: Float) -> NSColor {
        let a = SIMD3<Float>(palA.x, palA.y, palA.z)
        let b = SIMD3<Float>(palB.x, palB.y, palB.z)
        let d = SIMD3<Float>(palD.x, palD.y, palD.z)
        let angle = 2.0 * Float.pi * (0.5 * t + d)
        let raw = a + b * SIMD3<Float>(cos(angle.x), cos(angle.y), cos(angle.z))
        let graded = grade(simd_clamp(raw, .zero, SIMD3<Float>(repeating: 1.0)))
        return NSColor(srgbRed: CGFloat(graded.x), green: CGFloat(graded.y), blue: CGFloat(graded.z), alpha: 1)
    }

    func apply(to color: NSColor, useRolledOffset: Bool = true) -> NSColor {
        guard let srgb = color.usingColorSpace(.sRGB) else { return color }
        let raw = SIMD3<Float>(Float(srgb.redComponent), Float(srgb.greenComponent), Float(srgb.blueComponent))
        let extra = useRolledOffset ? (palD.x - 0.61018468) : 0
        let graded = grade(raw, extraHue: extra)
        let alphaScale = CGFloat(min(1.35, 0.35 + 0.65 * intensity))
        let alpha = min(1.0, max(0.0, srgb.alphaComponent * alphaScale))
        return NSColor(srgbRed: CGFloat(graded.x), green: CGFloat(graded.y), blue: CGFloat(graded.z), alpha: alpha)
    }
}

// Store only overrides. Missing values take their defaults, including controls added in a later version.
struct EffectConfiguration: Equatable {
    static let travelBladeKey = "travelBlade"
    static let styleKey = "style"
    static let paletteSeedKey = "paletteSeed"
    static let fireRepeatOnlyKey = "fireRepeatOnly"
    static let randomSingleKeyEffectsKey = "randomSingleKeyEffects"
    static let lightningKey = "lightning"
    static let iceKey = "ice"
    static let waterWaveKey = "waterWave"
    static let confettiKey = "confetti"
    static let blackHoleKey = "blackHole"
    static let reactiveKeysKey = "reactiveKeys"
    static let showKeyLegendsKey = "showKeyLegends"
    static let showOrientationMarkersKey = "showOrientationMarkers"
    static let borderMorphsBetweenKeysKey = "borderMorphsBetweenKeys"
    static let borderReleaseDelayKey = "borderReleaseDelay"
    static let waveTankKey = "waveTank"
    static let constellationKey = "constellation"
    static let matrixRainKey = "matrixRain"
    static let fireworksKey = "fireworks"
    static let soundEnabledKey = "soundEnabled"
    static let soundProfileKey = "soundProfile"
    static let musicAmbientKey = "musicAmbient"
    static let musicVisualKey = "musicVisual"
    static let musicAudioSourceKey = "musicAudioSource"
    static let musicAutoCycleKey = "musicAutoCycle"
    static let dictationVoiceBlobKey = "dictationVoiceBlob"
    var dictationShortcut = DictationShortcut.standard
    private(set) var overrides: [String: Double] = [:]

    var travelBlade: BladeStyle? {
        get { overrides[Self.travelBladeKey].flatMap(Int.init(exactly:)).flatMap(BladeStyle.init(rawValue:)) }
        set { overrides[Self.travelBladeKey] = newValue.map { Double($0.rawValue) } }
    }

    var style: EffectStyle {
        get {
            guard let raw = overrides[Self.styleKey], raw.isFinite else { return .default }
            return EffectStyle(rawValue: Int(raw.rounded())) ?? .default
        }
        set {
            overrides[Self.styleKey] = newValue == .default ? nil : Double(newValue.rawValue)
        }
    }

    /// When false (default), single-key effects trigger on every press and scale up on rapid repeats.
    var fireRepeatOnly: Bool {
        get { overrides[Self.fireRepeatOnlyKey] == 1 }
        set { overrides[Self.fireRepeatOnlyKey] = newValue ? 1 : nil }
    }

    var randomSingleKeyEffects: Bool {
        get { overrides[Self.randomSingleKeyEffectsKey] == 1 }
        set { overrides[Self.randomSingleKeyEffectsKey] = newValue ? 1 : nil }
    }

    /// Single-key branching Tesla lightning effect.
    var lightning: Bool {
        get { overrides[Self.lightningKey] == 1 }
        set { overrides[Self.lightningKey] = newValue ? 1 : nil }
    }

    /// Single-key crystalline frost and ice shard effect.
    var ice: Bool {
        get { overrides[Self.iceKey] == 1 }
        set { overrides[Self.iceKey] = newValue ? 1 : nil }
    }

    /// Single-key concentric water wave splash & droplet ripple effect.
    var waterWave: Bool {
        get { overrides[Self.waterWaveKey] == 1 }
        set { overrides[Self.waterWaveKey] = newValue ? 1 : nil }
    }

    /// Single-key tumbling 3D confetti & streamer pop effect.
    var confetti: Bool {
        get { overrides[Self.confettiKey] == 1 }
        set { overrides[Self.confettiKey] = newValue ? 1 : nil }
    }

    /// Single-key gravitational singularity with swirling accretion disk & inward matter trails.
    var blackHole: Bool {
        get { overrides[Self.blackHoleKey] == 1 }
        set { overrides[Self.blackHoleKey] = newValue ? 1 : nil }
    }

    /// Turns all keyboard keys off at idle and illuminates tapped + adjacent keys by distance from active glows.
    var reactiveKeys: Bool {
        get { overrides[Self.reactiveKeysKey] == 1 }
        set { overrides[Self.reactiveKeysKey] = newValue ? 1 : nil }
    }

    var showKeyLegends: Bool {
        get { overrides[Self.showKeyLegendsKey] == 1 }
        set { overrides[Self.showKeyLegendsKey] = newValue ? 1 : nil }
    }

    var showOrientationMarkers: Bool {
        get { overrides[Self.showOrientationMarkersKey] != 0 }
        set { overrides[Self.showOrientationMarkersKey] = newValue ? nil : 0 }
    }

    var borderMorphsBetweenKeys: Bool {
        get { overrides[Self.borderMorphsBetweenKeysKey] == 1 }
        set { overrides[Self.borderMorphsBetweenKeysKey] = newValue ? 1 : nil }
    }

    var borderReleaseDelay: Bool {
        get { overrides[Self.borderReleaseDelayKey] == 1 }
        set { overrides[Self.borderReleaseDelayKey] = newValue ? 1 : nil }
    }

    var keyLegendColor: NSColor {
        let hue = self[.keyLegendHue]
        let alpha = self[.keyLegendBrightness]
        if hue < 0 { return NSColor(white: 1, alpha: alpha) }
        return NSColor(calibratedHue: hue, saturation: 0.8, brightness: 1, alpha: alpha)
    }

    /// Persistent 2D shallow-water ripple physics simulation across the entire keyboard.
    var waveTank: Bool {
        get { overrides[Self.waveTankKey] == 1 }
        set { overrides[Self.waveTankKey] = newValue ? 1 : nil }
    }

    /// Persistent multi-key star constellation graph with aurora triads and synaptic pulses.
    var constellation: Bool {
        get { overrides[Self.constellationKey] == 1 }
        set { overrides[Self.constellationKey] = newValue ? 1 : nil }
    }

    /// Cybernetic digital phosphor glyph rain cascading from struck keys.
    var matrixRain: Bool {
        get { overrides[Self.matrixRainKey] == 1 }
        set { overrides[Self.matrixRainKey] = newValue ? 1 : nil }
    }

    /// Parabolic firework rockets launching from struck keys and bursting into starbursts.
    var fireworks: Bool {
        get { overrides[Self.fireworksKey] == 1 }
        set { overrides[Self.fireworksKey] = newValue ? 1 : nil }
    }

    /// Synthesized mechanical keyboard click sound.
    var soundEnabled: Bool {
        get { overrides[Self.soundEnabledKey] == 1 }
        set { overrides[Self.soundEnabledKey] = newValue ? 1 : nil }
    }

    var soundProfile: KeyboardSoundProfile {
        get {
            guard let raw = overrides[Self.soundProfileKey], raw.isFinite else { return .default }
            return KeyboardSoundProfile(rawValue: Int(raw.rounded())) ?? .default
        }
        set {
            overrides[Self.soundProfileKey] = newValue == .default ? nil : Double(newValue.rawValue)
        }
    }

    /// Music Ambient Mode: analyzes playing audio via FFT to drive full-board ambient visuals.
    var musicAmbient: Bool {
        get { overrides[Self.musicAmbientKey] == 1 }
        set { overrides[Self.musicAmbientKey] = newValue ? 1 : nil }
    }

    var musicVisual: MusicVisualStyle {
        get {
            guard let raw = overrides[Self.musicVisualKey], raw.isFinite else { return .default }
            return MusicVisualStyle(rawValue: Int(raw.rounded())) ?? .default
        }
        set {
            overrides[Self.musicVisualKey] = newValue == .default ? nil : Double(newValue.rawValue)
        }
    }

    var musicAudioSource: MusicAudioSource {
        get {
            guard let raw = overrides[Self.musicAudioSourceKey], raw.isFinite else { return .default }
            return MusicAudioSource(rawValue: Int(raw.rounded())) ?? .default
        }
        set {
            overrides[Self.musicAudioSourceKey] = newValue == .default ? nil : Double(newValue.rawValue)
        }
    }

    var musicAutoCycle: Bool {
        get { overrides[Self.musicAutoCycleKey] == 1 }
        set { overrides[Self.musicAutoCycleKey] = newValue ? 1 : nil }
    }

    /// Passive mic voice-reactive blob around the selected key while held during dictation.
    var dictationVoiceBlob: Bool {
        get { overrides[Self.dictationVoiceBlobKey] != 0 }
        set { overrides[Self.dictationVoiceBlobKey] = newValue ? nil : 0 }
    }

    var hasAnySingleKeyEffect: Bool {
        randomSingleKeyEffects || self[.flame] || lightning || ice || waterWave || confetti || blackHole
    }

    func allowsSingleKeyEffects(for beam: KeyBeam) -> Bool {
        !fireRepeatOnly || beam.length == 0
    }

    func shows(_ effect: SingleKeyEffect, for beam: KeyBeam) -> Bool {
        guard allowsSingleKeyEffects(for: beam) else { return false }
        if randomSingleKeyEffects { return beam.randomSingleKeyEffect == effect }
        switch effect {
        case .fire: return self[.flame]
        case .lightning: return lightning
        case .ice: return ice
        case .waterWave: return waterWave
        case .confetti: return confetti
        case .blackHole: return blackHole
        }
    }

    var hasAnyBoardEffect: Bool {
        waveTank || constellation || matrixRain || fireworks
    }

    var paletteSeed: Int {
        get {
            guard let raw = overrides[Self.paletteSeedKey], raw.isFinite else { return 0 }
            return max(0, Int(raw.rounded()))
        }
        set {
            let clamped = max(0, newValue)
            overrides[Self.paletteSeedKey] = clamped == 0 ? nil : Double(clamped)
        }
    }

    var hasDefaultColors: Bool {
        paletteSeed == 0
            && overrides[EffectControl.hue.rawValue] == nil
            && overrides[EffectControl.chroma.rawValue] == nil
            && overrides[EffectControl.intensity.rawValue] == nil
    }

    mutating func rollPalette() {
        var next = Int.random(in: 1...999_999)
        if next == paletteSeed { next = (next % 999_999) + 1 }
        paletteSeed = next
    }

    mutating func resetColors() {
        paletteSeed = 0
        for control in EffectControl.colorControls {
            self[control] = control.defaultValue
        }
    }

    var colorParams: EffectColorParams { EffectColorParams(settings: self) }

    subscript(layer: EffectLayer) -> Bool {
        get { overrides[layer.rawValue] != 0 }
        set { overrides[layer.rawValue] = newValue ? nil : 0 }
    }

    subscript(control: EffectControl) -> Double {
        get { control.bounded(overrides[control.rawValue] ?? control.defaultValue) }
        set {
            let value = control.bounded(newValue)
            overrides[control.rawValue] = abs(value - control.defaultValue) < 0.000001 ? nil : value
        }
    }
}

final class EffectSettingsStore: ObservableObject {
    private let defaults: UserDefaults
    private static let key = "effectConfiguration"
    var onChange: ((EffectConfiguration) -> Void)?

    @Published var keyboardMonitoringActive = false
    @Published var connection = KeyboardConnection()

    @Published var isPaused: Bool {
        didSet {
            guard oldValue != isPaused else { return }
            defaults.set(isPaused, forKey: "keyboardEffectsPaused")
            onChange?(value)
        }
    }

    @Published var value: EffectConfiguration {
        didSet {
            guard oldValue != value else { return }
            var stored: [String: Any] = value.overrides
            if value.dictationShortcut != .standard {
                stored["dictationShortcut"] = value.dictationShortcut.keys.map(Int.init)
            }
            defaults.set(stored, forKey: Self.key)
            onChange?(value)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isPaused = defaults.bool(forKey: "keyboardEffectsPaused")
        let stored = defaults.dictionary(forKey: Self.key) ?? [:]
        var loaded = EffectConfiguration()
        if let codes = stored["dictationShortcut"] as? [Int] {
            let keys = codes.compactMap(UInt16.init(exactly:))
            if keys.count == codes.count, let shortcut = DictationShortcut(keys: keys) {
                loaded.dictationShortcut = shortcut
            }
        }
        if let blade = stored[EffectConfiguration.travelBladeKey] as? NSNumber,
           let id = Int(exactly: blade.doubleValue) {
            loaded.travelBlade = BladeStyle(rawValue: id)
        }
        if let rawStyle = stored[EffectConfiguration.styleKey] as? NSNumber,
           let style = EffectStyle(rawValue: rawStyle.intValue) {
            loaded.style = style
        }
        if let rawSeed = stored[EffectConfiguration.paletteSeedKey] as? NSNumber {
            loaded.paletteSeed = rawSeed.intValue
        }
        if let v = stored[EffectConfiguration.fireRepeatOnlyKey] as? NSNumber { loaded.fireRepeatOnly = v.boolValue }
        if let v = stored[EffectConfiguration.randomSingleKeyEffectsKey] as? NSNumber {
            loaded.randomSingleKeyEffects = v.boolValue
        }
        if let v = stored[EffectConfiguration.lightningKey] as? NSNumber { loaded.lightning = v.boolValue }
        if let v = stored[EffectConfiguration.iceKey] as? NSNumber { loaded.ice = v.boolValue }
        if let v = stored[EffectConfiguration.waterWaveKey] as? NSNumber { loaded.waterWave = v.boolValue }
        if let v = stored[EffectConfiguration.confettiKey] as? NSNumber { loaded.confetti = v.boolValue }
        if let v = stored[EffectConfiguration.blackHoleKey] as? NSNumber { loaded.blackHole = v.boolValue }
        if let v = stored[EffectConfiguration.reactiveKeysKey] as? NSNumber { loaded.reactiveKeys = v.boolValue }
        if let v = stored[EffectConfiguration.showKeyLegendsKey] as? NSNumber { loaded.showKeyLegends = v.boolValue }
        if let v = stored[EffectConfiguration.showOrientationMarkersKey] as? NSNumber {
            loaded.showOrientationMarkers = v.boolValue
        }
        if let v = stored[EffectConfiguration.borderMorphsBetweenKeysKey] as? NSNumber {
            loaded.borderMorphsBetweenKeys = v.boolValue
        }
        if let v = stored[EffectConfiguration.borderReleaseDelayKey] as? NSNumber { loaded.borderReleaseDelay = v.boolValue }
        if let v = stored[EffectConfiguration.waveTankKey] as? NSNumber { loaded.waveTank = v.boolValue }
        if let v = stored[EffectConfiguration.constellationKey] as? NSNumber { loaded.constellation = v.boolValue }
        if let v = stored[EffectConfiguration.matrixRainKey] as? NSNumber { loaded.matrixRain = v.boolValue }
        if let v = stored[EffectConfiguration.fireworksKey] as? NSNumber { loaded.fireworks = v.boolValue }
        if let v = stored[EffectConfiguration.soundEnabledKey] as? NSNumber { loaded.soundEnabled = v.boolValue }
        if let rawProfile = stored[EffectConfiguration.soundProfileKey] as? NSNumber,
           let profile = KeyboardSoundProfile(rawValue: rawProfile.intValue) {
            loaded.soundProfile = profile
        }
        if let v = stored[EffectConfiguration.musicAmbientKey] as? NSNumber { loaded.musicAmbient = v.boolValue }
        if let rawVisual = stored[EffectConfiguration.musicVisualKey] as? NSNumber,
           let visual = MusicVisualStyle(rawValue: rawVisual.intValue) {
            loaded.musicVisual = visual
        }
        if let rawSource = stored[EffectConfiguration.musicAudioSourceKey] as? NSNumber,
           let source = MusicAudioSource(rawValue: rawSource.intValue) {
            loaded.musicAudioSource = source
        }
        if let v = stored[EffectConfiguration.musicAutoCycleKey] as? NSNumber { loaded.musicAutoCycle = v.boolValue }
        if let v = stored[EffectConfiguration.dictationVoiceBlobKey] as? NSNumber { loaded.dictationVoiceBlob = v.boolValue }
        for control in EffectControl.colorControls + EffectControl.extraControls {
            if let number = stored[control.rawValue] as? NSNumber { loaded[control] = number.doubleValue }
        }
        for layer in EffectLayer.allCases {
            if let flag = stored[layer.rawValue] as? NSNumber { loaded[layer] = flag.boolValue }
            for control in layer.controls {
                if let number = stored[control.rawValue] as? NSNumber { loaded[control] = number.doubleValue }
            }
        }
        value = loaded
    }
}

import AVFoundation
import Foundation

/// Low-latency procedural mechanical keyboard sound synthesizer.
/// Generates realistic per-switch acoustic buffers with key-type resonance (spacebar, enter, modifiers)
/// and subtle per-key organic variation, requiring zero external audio files.
final class KeyboardSoundEngine {
    static let shared = KeyboardSoundEngine()

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var varispeeds: [AVAudioUnitVarispeed] = []
    private var nextVoice = 0
    private var started = false
    private let lock = NSLock()
    private var lastPlayedByKey: [UInt16: TimeInterval] = [:]
    private let sampleRate: Double = 44_100
    private let format: AVAudioFormat
    private var cachedKey: CacheKey?
    private var standardBuffers: [AVAudioPCMBuffer] = []
    private var spaceBuffer: AVAudioPCMBuffer?
    private var enterBuffer: AVAudioPCMBuffer?
    private var bellBuffer: AVAudioPCMBuffer?

    private struct CacheKey: Equatable {
        let profile: KeyboardSoundProfile
        let toneBucket: Int
    }

    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    }

    private func ensureEngineStarted() -> Bool {
        guard !Self.isRunningTests else { return false }
        if started && engine.isRunning { return true }
        if players.isEmpty {
            let voiceCount = 8
            for _ in 0..<voiceCount {
                let player = AVAudioPlayerNode()
                let speed = AVAudioUnitVarispeed()
                engine.attach(player)
                engine.attach(speed)
                engine.connect(player, to: speed, format: format)
                engine.connect(speed, to: engine.mainMixerNode, format: format)
                players.append(player)
                varispeeds.append(speed)
            }
        }
        do {
            try engine.start()
            started = true
            return true
        } catch {
            return false
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard started else { return }
        players.forEach { $0.stop() }
        engine.stop()
        started = false
        lastPlayedByKey.removeAll()
    }

    /// Plays a mechanical key sound for the given virtual key code according to current settings.
    func play(keyCode: UInt16, settings: EffectConfiguration, bypassDebounce: Bool = false) {
        guard settings.soundEnabled else { return }
        lock.lock()
        defer { lock.unlock() }

        let now = ProcessInfo.processInfo.systemUptime
        if !bypassDebounce, let last = lastPlayedByKey[keyCode], now - last < 0.025 {
            return
        }
        lastPlayedByKey[keyCode] = now

        guard ensureEngineStarted() else { return }

        let profile = settings.soundProfile
        let tone = settings[.soundTone]
        let key = CacheKey(profile: profile, toneBucket: Int((tone * 20).rounded()))
        if cachedKey != key {
            rebuildBuffers(profile: profile, tone: tone)
            cachedKey = key
        }

        let volume = Float(settings[.soundVolume])
        let basePitch = Float(settings[.soundPitch])

        let buffer: AVAudioPCMBuffer?
        var pitchMul: Float = basePitch
        var gainMul: Float = volume

        switch keyCode {
        case 49: // Spacebar: deeper, fuller stabilizer thock
            buffer = spaceBuffer ?? standardBuffers.first
            pitchMul *= 0.84
            gainMul *= 1.08
        case 36: // Return: meatier click + typewriter bell
            buffer = enterBuffer ?? standardBuffers.first
            pitchMul *= 0.90
            gainMul *= 1.05
        case 51, 48, 57: // Delete / Tab / Caps
            buffer = enterBuffer ?? standardBuffers.first
            pitchMul *= 0.94
        case 54...62: // Modifiers
            buffer = standardBuffers.first
            pitchMul *= 0.92
            gainMul *= 0.82
        default:
            if profile == .synth {
                buffer = standardBuffers.first
                pitchMul *= pentatonicRatio(for: keyCode)
            } else {
                let variant = Int(keyCode) % max(1, standardBuffers.count)
                buffer = standardBuffers.isEmpty ? nil : standardBuffers[variant]
                // Subtle deterministic per-key pitch spread + tiny organic jitter
                let keySpread = Float((Int(keyCode) * 37) % 11 - 5) * 0.008
                let jitter = Float.random(in: -0.018...0.018)
                pitchMul *= (1.0 + keySpread + jitter)
            }
        }

        if let buffer {
            schedule(buffer: buffer, rate: max(0.35, min(2.6, pitchMul)), volume: min(1.5, gainMul))
        }
        if profile == .typewriter && keyCode == 36, let bell = bellBuffer {
            schedule(buffer: bell, rate: max(0.5, min(2.0, basePitch)), volume: min(1.0, volume * 0.65))
        }
    }

    private func schedule(buffer: AVAudioPCMBuffer, rate: Float, volume: Float) {
        guard !players.isEmpty else { return }
        let idx = nextVoice % players.count
        nextVoice += 1
        let player = players[idx]
        let speed = varispeeds[idx]
        speed.rate = rate
        player.volume = volume
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        player.play()
    }

    private func pentatonicRatio(for keyCode: UInt16) -> Float {
        let scale: [Float] = [1.0, 9.0/8.0, 5.0/4.0, 3.0/2.0, 5.0/3.0, 2.0, 9.0/4.0, 5.0/2.0]
        if let rect = Action75.rects[keyCode] {
            let normX = min(0.999, max(0.0, rect.midX / Action75.canvas.width))
            let idx = Int(normX * Double(scale.count))
            return scale[idx] * 0.85
        }
        return scale[Int(keyCode) % scale.count] * 0.85
    }

    // MARK: - Procedural Acoustic Synthesis

    /// Pure sample synthesis exposed for deterministic testing without starting AVAudioEngine.
    static func synthesizeSamples(profile: KeyboardSoundProfile, tone: Double,
                                  variant: Int = 0, sampleRate: Double = 44_100) -> [Float] {
        let duration: Double
        switch profile {
        case .synth: duration = 0.22
        case .typewriter: duration = 0.095
        default: duration = 0.068
        }
        let count = Int(sampleRate * duration)
        var samples = [Float](repeating: 0, count: count)
        var rngState: UInt64 = UInt64(variant + 1) &* 0x9E3779B97F4A7C15 ^ 0xBF58476D1CE4E5B9
        func whiteNoise() -> Float {
            rngState &+= 0x9E3779B97F4A7C15
            var z = rngState
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z = z ^ (z >> 31)
            return Float(Double(z >> 11) / Double(1 << 53)) * 2.0 - 1.0
        }

        let brightness = Float(min(1, max(0, tone)))
        let vShift = 1.0 + Float(variant - 2) * 0.025
        var lpState: Float = 0
        var hpPrevIn: Float = 0
        var hpPrevOut: Float = 0

        for i in 0..<count {
            let t = Float(i) / Float(sampleRate)
            let rawNoise = whiteNoise()
            // Simple 1-pole lowpass + highpass for shaping transient noise
            let lpAlpha: Float = 0.14 + 0.34 * brightness
            lpState += lpAlpha * (rawNoise - lpState)
            let hp = 0.72 * (hpPrevOut + rawNoise - hpPrevIn)
            hpPrevIn = rawNoise
            hpPrevOut = hp

            var sample: Float = 0
            switch profile {
            case .thock:
                // Creamy deep PBT case thud + damped stem bottom-out
                let thudFreq = (148.0 + 55.0 * brightness) * vShift
                let bodyFreq = (340.0 + 180.0 * brightness) * vShift
                let thud = sin(2.0 * .pi * thudFreq * t * (1.0 - 1.8 * t)) * exp(-t * 58.0) * 0.78
                let body = sin(2.0 * .pi * bodyFreq * t) * exp(-t * 115.0) * 0.36
                let tap = lpState * exp(-t * 210.0) * (0.48 + 0.32 * brightness)
                let tick = hp * exp(-t * 620.0) * (0.14 + 0.25 * brightness)
                sample = thud + body + tap + tick

            case .clicky:
                // Sharp MX-Blue / Box-Jade metallic click jacket + snappy bottom-out
                let clickFreq = (3100.0 + 1300.0 * brightness) * vShift
                let click1 = (sin(2.0 * .pi * clickFreq * t) + 0.45 * sin(2.0 * .pi * clickFreq * 1.47 * t))
                    * exp(-t * 480.0) * (0.55 + 0.35 * brightness)
                let snapNoise = hp * exp(-t * 520.0) * (0.52 + 0.30 * brightness)
                // Secondary bottom-out 4.5ms after the tactile click jacket
                let t2 = max(0, t - 0.0045)
                let bottom = t > 0.0045
                    ? (sin(2.0 * .pi * 240.0 * vShift * t2) * exp(-t2 * 95.0) * 0.46
                       + lpState * exp(-t2 * 240.0) * 0.32)
                    : 0
                sample = click1 + snapNoise + bottom

            case .tactile:
                // Pronounced mid-frequency tactile bump + warm solid bottom-out
                let bumpFreq = (820.0 + 420.0 * brightness) * vShift
                let baseFreq = (195.0 + 75.0 * brightness) * vShift
                let bump = sin(2.0 * .pi * bumpFreq * t) * exp(-t * 240.0) * (0.48 + 0.25 * brightness)
                let base = sin(2.0 * .pi * baseFreq * t) * exp(-t * 72.0) * 0.62
                let clack = (lpState * 0.45 + hp * (0.25 + 0.30 * brightness)) * exp(-t * 320.0)
                sample = bump + base + clack

            case .typewriter:
                // Heavy mechanical striker hammer + crisp platen clack + metal linkage ring
                let strike = hp * exp(-t * 380.0) * (0.72 + 0.25 * brightness)
                let metal = (sin(2.0 * .pi * 1680.0 * vShift * t) * 0.34
                           + sin(2.0 * .pi * 2940.0 * vShift * t) * 0.22) * exp(-t * 145.0)
                let platen = sin(2.0 * .pi * 210.0 * vShift * t) * exp(-t * 54.0) * 0.58
                let t2 = max(0, t - 0.011)
                let rebound = t > 0.011 ? lpState * exp(-t2 * 280.0) * 0.28 : 0
                sample = strike + metal + platen + rebound

            case .synth:
                // Soft crystalline kalimba/marimba pluck + delicate mechanical touch
                let f0 = (440.0 + 140.0 * brightness) * vShift
                let env = min(1.0, t / 0.0025) * exp(-t * 18.0)
                let h1 = sin(2.0 * .pi * f0 * t) * 0.62
                let h2 = sin(2.0 * .pi * f0 * 2.0 * t) * exp(-t * 28.0) * (0.24 + 0.18 * brightness)
                let h3 = sin(2.0 * .pi * f0 * 3.0 * t) * exp(-t * 48.0) * (0.10 + 0.14 * brightness)
                let touch = lpState * exp(-t * 420.0) * 0.16
                sample = (h1 + h2 + h3) * env + touch
            }

            // Soft limiter + micro fade-out at tail to prevent clicks
            let tailFade = i > count - 128 ? Float(count - i) / 128.0 : 1.0
            samples[i] = tanh(sample * 1.15) * 0.85 * tailFade
        }
        return samples
    }

    private func makeBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                channel.update(from: base, count: samples.count)
            }
        }
        return buffer
    }

    private func rebuildBuffers(profile: KeyboardSoundProfile, tone: Double) {
        standardBuffers = (0..<5).compactMap { variant in
            makeBuffer(from: Self.synthesizeSamples(profile: profile, tone: tone, variant: variant, sampleRate: sampleRate))
        }
        spaceBuffer = makeBuffer(from: Self.synthesizeSamples(profile: profile, tone: max(0, tone - 0.2), variant: 7, sampleRate: sampleRate))
        enterBuffer = makeBuffer(from: Self.synthesizeSamples(profile: profile, tone: max(0, tone - 0.1), variant: 9, sampleRate: sampleRate))
        if profile == .typewriter {
            // Classic brass typewriter carriage return bell ping
            let count = Int(sampleRate * 0.45)
            var bell = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let t = Float(i) / Float(sampleRate)
                let env = min(1.0, t / 0.002) * exp(-t * 8.5)
                let s = sin(2.0 * .pi * 2140.0 * t) * 0.52
                    + sin(2.0 * .pi * 4295.0 * t) * exp(-t * 14.0) * 0.28
                    + sin(2.0 * .pi * 6410.0 * t) * exp(-t * 26.0) * 0.14
                bell[i] = s * env * 0.65
            }
            bellBuffer = makeBuffer(from: bell)
        } else {
            bellBuffer = nil
        }
    }
}

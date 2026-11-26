import Accelerate
import AVFoundation
import CoreAudio
import Foundation

/// Analyzed real-time audio spectrum and beat-onset snapshot for music-reactive visuals.
struct MusicSpectrumFrame {
    static let bandCount = 32
    static let waveformCount = 64

    var bands: [Float]
    var peaks: [Float]
    var waveform: [Float]
    var subBass: Float
    var bass: Float
    var mids: Float
    var highs: Float
    var energy: Float
    var level: Float
    var beatPulse: Float
    var snarePulse: Float
    var hatPulse: Float
    var beatTriggered: Bool
    var snareTriggered: Bool
    var hatTriggered: Bool
    var beatCount: UInt64
    var dominantPitch: Float
    var stereoBalance: Float
    var isSilent: Bool

    static let silent = MusicSpectrumFrame(
        bands: Array(repeating: 0, count: bandCount),
        peaks: Array(repeating: 0, count: bandCount),
        waveform: Array(repeating: 0, count: waveformCount),
        subBass: 0,
        bass: 0,
        mids: 0,
        highs: 0,
        energy: 0,
        level: 0,
        beatPulse: 0,
        snarePulse: 0,
        hatPulse: 0,
        beatTriggered: false,
        snareTriggered: false,
        hatTriggered: false,
        beatCount: 0,
        dominantPitch: 0.3,
        stereoBalance: 0,
        isSilent: true
    )
}

/// Real-time Accelerate/vDSP FFT analyzer with perceptual log-band binning, adaptive AGC, and onset detection.
final class MusicFFTProcessor {
    static let fftSize = 2048
    private static let log2n = vDSP_Length(11)

    private let fftSetup: FFTSetup?
    private var window: [Float]
    private var windowed: [Float]
    private var realPart: [Float]
    private var imagPart: [Float]
    private var magnitudes: [Float]

    private var smoothedBands: [Float]
    private var prevRawBands: [Float]
    private var peaks: [Float]

    private var agcPeak: Float = 0.08
    private var bassFluxAvg: Float = 0.015
    private var snareFluxAvg: Float = 0.015
    private var hatFluxAvg: Float = 0.015
    private var beatPulse: Float = 0
    private var snarePulse: Float = 0
    private var hatPulse: Float = 0
    private var beatCooldown: Double = 0
    private var snareCooldown: Double = 0
    private var hatCooldown: Double = 0
    private var beatCount: UInt64 = 0
    private var smoothedPitch: Float = 0.3
    private var smoothedBalance: Float = 0

    init() {
        fftSetup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))
        window = Array(repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        windowed = Array(repeating: 0, count: Self.fftSize)
        realPart = Array(repeating: 0, count: Self.fftSize / 2)
        imagPart = Array(repeating: 0, count: Self.fftSize / 2)
        magnitudes = Array(repeating: 0, count: Self.fftSize / 2)
        smoothedBands = Array(repeating: 0, count: MusicSpectrumFrame.bandCount)
        prevRawBands = Array(repeating: 0, count: MusicSpectrumFrame.bandCount)
        peaks = Array(repeating: 0, count: MusicSpectrumFrame.bandCount)
    }

    deinit {
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    func reset() {
        for i in 0..<smoothedBands.count {
            smoothedBands[i] = 0
            prevRawBands[i] = 0
            peaks[i] = 0
        }
        agcPeak = 0.08
        bassFluxAvg = 0.015
        snareFluxAvg = 0.015
        hatFluxAvg = 0.015
        beatPulse = 0
        snarePulse = 0
        hatPulse = 0
        beatCooldown = 0
        snareCooldown = 0
        hatCooldown = 0
        beatCount = 0
        smoothedPitch = 0.3
        smoothedBalance = 0
    }

    func process(
        monoSamples: [Float],
        stereoBalance: Float = 0,
        sampleRate: Double = 48_000,
        dt: Double = 1.0 / 60.0,
        sensitivity: Double = 1.0,
        reactivity: Double = 1.0
    ) -> MusicSpectrumFrame {
        let clampedDt = max(1.0 / 180.0, min(0.1, dt))
        let sens = Float(max(0.15, min(3.0, sensitivity)))
        let react = Float(max(0.25, min(2.0, reactivity)))
        let safeRate = max(8_000, min(192_000, sampleRate))

        let sampleCount = monoSamples.count
        var padded = [Float](repeating: 0, count: Self.fftSize)
        if sampleCount >= Self.fftSize {
            let start = sampleCount - Self.fftSize
            for i in 0..<Self.fftSize {
                padded[i] = monoSamples[start + i]
            }
        } else if sampleCount > 0 {
            let offset = Self.fftSize - sampleCount
            for i in 0..<sampleCount {
                padded[offset + i] = monoSamples[i]
            }
        }

        // Compute RMS level and downsampled waveform trace
        var rms: Float = 0
        vDSP_rmsqv(padded, 1, &rms, vDSP_Length(Self.fftSize))
        let waveformCount = MusicSpectrumFrame.waveformCount
        var waveform = [Float](repeating: 0, count: waveformCount)
        let strideStep = max(1, Self.fftSize / waveformCount)
        let waveGain = min(4.0, 1.45 * sens)
        for i in 0..<waveformCount {
            let idx = min(Self.fftSize - 1, i * strideStep)
            waveform[i] = max(-1, min(1, padded[idx] * waveGain))
        }

        // Noise gate for silence
        let noiseGate: Float = 0.00035
        let isSilent = rms < noiseGate

        beatCooldown = max(0, beatCooldown - clampedDt)
        snareCooldown = max(0, snareCooldown - clampedDt)
        hatCooldown = max(0, hatCooldown - clampedDt)

        let decayRate = Float(exp(-clampedDt * (5.5 + 3.5 * Double(react))))
        beatPulse *= Float(exp(-clampedDt * 8.5))
        snarePulse *= Float(exp(-clampedDt * 11.0))
        hatPulse *= Float(exp(-clampedDt * 14.0))

        var rawBands = [Float](repeating: 0, count: MusicSpectrumFrame.bandCount)

        if !isSilent, let fftSetup {
            vDSP_vmul(padded, 1, window, 1, &windowed, 1, vDSP_Length(Self.fftSize))
            realPart.withUnsafeMutableBufferPointer { rBuf in
                imagPart.withUnsafeMutableBufferPointer { iBuf in
                    windowed.withUnsafeBufferPointer { wBuf in
                        wBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.fftSize / 2) { complexPtr in
                            var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                            vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(Self.fftSize / 2))
                            vDSP_fft_zrip(fftSetup, &split, 1, Self.log2n, FFTDirection(kFFTDirection_Forward))
                            // Scale and compute magnitudes
                            var scale = Float(1.0 / Double(Self.fftSize))
                            vDSP_vsmul(split.realp, 1, &scale, split.realp, 1, vDSP_Length(Self.fftSize / 2))
                            vDSP_vsmul(split.imagp, 1, &scale, split.imagp, 1, vDSP_Length(Self.fftSize / 2))
                            vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(Self.fftSize / 2))
                        }
                    }
                }
            }
            magnitudes[0] = 0 // discard DC bin

            let binHz = safeRate / Double(Self.fftSize)
            let halfBins = Self.fftSize / 2
            let minFreq = 28.0
            let maxFreq = min(16_000.0, safeRate * 0.45)
            let ratio = maxFreq / minFreq

            for b in 0..<MusicSpectrumFrame.bandCount {
                let f0 = minFreq * pow(ratio, Double(b) / Double(MusicSpectrumFrame.bandCount))
                let f1 = minFreq * pow(ratio, Double(b + 1) / Double(MusicSpectrumFrame.bandCount))
                let bin0 = max(1, min(halfBins - 1, Int(floor(f0 / binHz))))
                let bin1 = max(bin0, min(halfBins - 1, Int(ceil(f1 / binHz))))

                var peakBin: Float = 0
                var sumBin: Float = 0
                for k in bin0...bin1 {
                    let m = magnitudes[k]
                    sumBin += m
                    if m > peakBin { peakBin = m }
                }
                let avgBin = sumBin / Float(bin1 - bin0 + 1)
                let combined = peakBin * 0.65 + avgBin * 0.35
                // Gentle perceptual treble compensation (+3dB/oct feel)
                let bandFrac = Float(b + 1) / Float(MusicSpectrumFrame.bandCount)
                let tilt = 0.72 + 1.15 * pow(bandFrac, 0.42)
                rawBands[b] = combined * tilt
            }
        }

        // Adaptive AGC across the spectrum
        let frameMax = rawBands.max() ?? 0
        if frameMax > agcPeak {
            agcPeak = agcPeak * 0.72 + frameMax * 0.28
        } else {
            agcPeak = max(0.012, agcPeak * Float(pow(0.992, clampedDt * 60.0)))
        }
        let normDiv = max(0.012, agcPeak / sens)

        var normalizedBands = [Float](repeating: 0, count: MusicSpectrumFrame.bandCount)
        let attackAlpha = min(0.92, 0.48 + 0.36 * react)
        let releaseAlpha = max(0.08, 1.0 - decayRate)

        for b in 0..<MusicSpectrumFrame.bandCount {
            let scaled = rawBands[b] / normDiv
            // Dynamic range compression: crisp response at low & high levels
            let compressed = isSilent ? 0 : min(1.0, pow(max(0, scaled), 0.68))
            normalizedBands[b] = compressed

            let prev = smoothedBands[b]
            if compressed > prev {
                smoothedBands[b] = prev + (compressed - prev) * attackAlpha
            } else {
                smoothedBands[b] = prev * (1.0 - releaseAlpha) + compressed * releaseAlpha
            }
            if smoothedBands[b] < 0.002 { smoothedBands[b] = 0 }

            // Peak hold with gravity
            let peakFall = Float(clampedDt * 0.42)
            peaks[b] = max(smoothedBands[b], max(0, peaks[b] - peakFall))
        }

        // Spectral flux onset detection across Bass, Snare/Mid, and Hat/High bands
        var bassFlux: Float = 0
        var snareFlux: Float = 0
        var hatFlux: Float = 0
        for b in 0..<MusicSpectrumFrame.bandCount {
            let diff = max(0, normalizedBands[b] - prevRawBands[b])
            prevRawBands[b] = normalizedBands[b]
            if b < 7 {
                bassFlux += diff
            } else if b < 20 {
                snareFlux += diff
            } else {
                hatFlux += diff
            }
        }
        bassFlux /= 7.0
        snareFlux /= 13.0
        hatFlux /= 12.0

        bassFluxAvg = bassFluxAvg * 0.90 + bassFlux * 0.10
        snareFluxAvg = snareFluxAvg * 0.90 + snareFlux * 0.10
        hatFluxAvg = hatFluxAvg * 0.90 + hatFlux * 0.10

        let fluxThresholdScale = max(1.18, 1.62 - 0.24 * react)
        var beatTriggered = false
        var snareTriggered = false
        var hatTriggered = false

        if !isSilent {
            if beatCooldown <= 0 && bassFlux > max(0.032 / sens, bassFluxAvg * fluxThresholdScale) {
                beatTriggered = true
                beatPulse = min(1.0, max(beatPulse, 0.72 + bassFlux * 2.2))
                beatCooldown = 0.13
                beatCount &+= 1
            }
            if snareCooldown <= 0 && snareFlux > max(0.028 / sens, snareFluxAvg * (fluxThresholdScale + 0.08)) {
                snareTriggered = true
                snarePulse = min(1.0, max(snarePulse, 0.65 + snareFlux * 2.4))
                snareCooldown = 0.10
            }
            if hatCooldown <= 0 && hatFlux > max(0.022 / sens, hatFluxAvg * (fluxThresholdScale + 0.05)) {
                hatTriggered = true
                hatPulse = min(1.0, max(hatPulse, 0.60 + hatFlux * 2.6))
                hatCooldown = 0.065
            }
        }

        func bandMean(_ range: ClosedRange<Int>) -> Float {
            var sum: Float = 0
            for i in range { sum += smoothedBands[i] }
            return sum / Float(range.count)
        }

        let subBass = bandMean(0...3)
        let bass = bandMean(2...7)
        let mids = bandMean(8...19)
        let highs = bandMean(20...31)
        let energy = min(1.0, bass * 0.42 + mids * 0.36 + highs * 0.22)
        let level = min(1.0, rms * 3.8 * sens)

        var centroidNum: Float = 0
        var centroidDen: Float = 0
        for b in 0..<MusicSpectrumFrame.bandCount {
            let w = smoothedBands[b]
            centroidNum += Float(b) / Float(MusicSpectrumFrame.bandCount - 1) * w
            centroidDen += w
        }
        if centroidDen > 0.02 {
            let instantPitch = centroidNum / centroidDen
            smoothedPitch = smoothedPitch * 0.82 + instantPitch * 0.18
        }
        smoothedBalance = smoothedBalance * 0.8 + max(-1, min(1, stereoBalance)) * 0.2

        return MusicSpectrumFrame(
            bands: smoothedBands,
            peaks: peaks,
            waveform: waveform,
            subBass: subBass,
            bass: bass,
            mids: mids,
            highs: highs,
            energy: energy,
            level: level,
            beatPulse: beatPulse,
            snarePulse: snarePulse,
            hatPulse: hatPulse,
            beatTriggered: beatTriggered,
            snareTriggered: snareTriggered,
            hatTriggered: hatTriggered,
            beatCount: beatCount,
            dominantPitch: smoothedPitch,
            stereoBalance: smoothedBalance,
            isSilent: isSilent && smoothedBands.allSatisfy { $0 < 0.01 }
        )
    }
}

/// Self-contained procedural 124 BPM electronic groove synthesizer for testing and instant demo playback.
final class DemoMusicSynthesizer {
    let sampleRate: Double
    private var sampleCursor: UInt64 = 0
    private var rngState: UInt64 = 0x5A17_C0DE_BEEF_1234

    init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
    }

    func reset() {
        sampleCursor = 0
    }

    private func nextNoise() -> Float {
        rngState &+= 0x9E3779B97F4A7C15
        var z = rngState
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return Float(Double(z >> 11) / Double(1 << 53)) * 2.0 - 1.0
    }

    func render(frameCount: Int) -> (mono: [Float], stereoBalance: Float) {
        var mono = [Float](repeating: 0, count: frameCount)
        let bpm = 124.0
        let beatSec = 60.0 / bpm
        let sixteenthSec = beatSec * 0.25
        let bassNotes: [Double] = [55.0, 55.0, 65.41, 73.42, 82.41, 73.42, 65.41, 61.74]
        let arpNotes: [Double] = [220.0, 261.63, 329.63, 392.0, 440.0, 523.25, 659.25, 523.25]

        var leftSum: Float = 0
        var rightSum: Float = 0

        for i in 0..<frameCount {
            let t = Double(sampleCursor) / sampleRate
            sampleCursor &+= 1

            let beatPos = t / beatSec
            let beatPhase = beatPos - floor(beatPos)
            let beatTime = beatPhase * beatSec
            let beatIndex = Int(floor(beatPos))

            let stepPos = t / sixteenthSec
            let stepPhase = stepPos - floor(stepPos)
            let stepTime = stepPhase * sixteenthSec
            let stepIndex = Int(floor(stepPos))

            // 1. Punchy 4-on-the-floor kick drum
            let kickEnv = exp(-beatTime * 11.5)
            let kickFreq = 46.0 + 128.0 * exp(-beatTime * 34.0)
            let kick = Float(sin(2.0 * .pi * kickFreq * beatTime) * kickEnv) * 0.68

            // 2. Crisp snare on beats 2 & 4
            var snare: Float = 0
            if beatIndex % 2 == 1 {
                let snareEnv = Float(exp(-beatTime * 17.0))
                let body = Float(sin(2.0 * .pi * 192.0 * beatTime) * exp(-beatTime * 26.0)) * 0.28
                snare = (nextNoise() * 0.42 + body) * snareEnv
            }

            // 3. 16th-note metallic hi-hat
            let hatAccent: Float = (stepIndex % 4 == 2) ? 0.30 : 0.14
            let hatDecay = (stepIndex % 4 == 2) ? 24.0 : 48.0
            let hatEnv = Float(exp(-stepTime * hatDecay))
            let hatTone = Float(sin(2.0 * .pi * 6850.0 * t) * 0.35 + sin(2.0 * .pi * 9420.0 * t) * 0.25)
            let hat = (nextNoise() * 0.55 + hatTone) * hatEnv * hatAccent

            // 4. Rolling octave bassline
            let barStep = (stepIndex / 2) % bassNotes.count
            let bassF = bassNotes[barStep]
            let bassEnv = Float(exp(-stepTime * 7.0)) * (beatPhase < 0.14 ? 0.35 : 1.0)
            let bass = Float(sin(2.0 * .pi * bassF * t) * 0.65 + sin(2.0 * .pi * bassF * 2.0 * t) * 0.25) * bassEnv * 0.42

            // 5. Shimmering stereo pentatonic arpeggio
            let arpF = arpNotes[(stepIndex + beatIndex / 4) % arpNotes.count]
            let arpEnv = Float(min(1.0, stepTime / 0.004) * exp(-stepTime * 11.0))
            let arp = Float(sin(2.0 * .pi * arpF * t) * 0.7 + sin(2.0 * .pi * arpF * 2.0 * t) * 0.25) * arpEnv * 0.28

            let pan = Float(sin(Double(stepIndex) * 0.85))
            let lGain = 0.5 - 0.42 * pan
            let rGain = 0.5 + 0.42 * pan
            let center = kick + snare * 0.9 + bass
            let left = center * 0.5 + arp * lGain + hat * (0.5 + 0.2 * pan)
            let right = center * 0.5 + arp * rGain + hat * (0.5 - 0.2 * pan)

            leftSum += left * left
            rightSum += right * right
            mono[i] = max(-1, min(1, (left + right) * 0.85))
        }

        let denom = max(1e-6, leftSum + rightSum)
        let balance = (rightSum - leftSum) / denom
        return (mono, max(-1, min(1, balance * 1.8)))
    }
}

enum MusicAudioCaptureStatus: Equatable {
    case stopped
    case listening(MusicAudioSource)
    case permissionNeeded(String)
    case error(String)

    var label: String {
        switch self {
        case .stopped: return "Off"
        case .listening(let source): return "Listening (\(source.title))"
        case .permissionNeeded(let message): return message
        case .error(let message): return message
        }
    }
}

/// Captures live System Audio (macOS 14.2+ CoreAudio Process Tap), Microphone input, or Demo Synth
/// and supplies synchronized FFT spectrum frames for Music Ambient visuals.
final class MusicAudioEngine: ObservableObject {
    static let shared = MusicAudioEngine()

    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private static let ringCapacity = 4096

    @Published private(set) var status: MusicAudioCaptureStatus = .stopped
    @Published private(set) var meterBands: [Float] = Array(repeating: 0, count: 16)
    @Published private(set) var beatIndicator: Float = 0

    private let lock = NSLock()
    private var ringBuffer = [Float](repeating: 0, count: ringCapacity)
    private var ringWriteIndex = 0
    private var ringFilled = 0
    private var liveSampleRate: Double = 48_000
    private var liveBalance: Float = 0
    private var lastSampleTimestamp: TimeInterval = 0
    private var lastMeterPush: TimeInterval = 0

    private let fft = MusicFFTProcessor()
    private let demoSynth = DemoMusicSynthesizer(sampleRate: 48_000)

    private var activeSource: MusicAudioSource?
    private var avEngine: AVAudioEngine?
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    private init() {}

    func start(source: MusicAudioSource) {
        if activeSource == source, case .listening = status { return }
        stopCaptureOnly()
        activeSource = source
        fft.reset()
        demoSynth.reset()
        clearRingBuffer()

        if Self.isRunningTests {
            publishStatus(.listening(source))
            return
        }

        switch source {
        case .demoBeat:
            liveSampleRate = demoSynth.sampleRate
            publishStatus(.listening(.demoBeat))
        case .microphone:
            startMicrophone()
        case .systemAudio:
            startSystemAudio()
        }
    }

    func retry() {
        guard let source = activeSource else { return }
        stopCaptureOnly()
        activeSource = nil
        start(source: source)
    }

    func stop() {
        stopCaptureOnly()
        activeSource = nil
        fft.reset()
        clearRingBuffer()
        publishStatus(.stopped)
        DispatchQueue.main.async { [weak self] in
            self?.meterBands = Array(repeating: 0, count: 16)
            self?.beatIndicator = 0
        }
    }

    func sampleFrame(at now: TimeInterval, sensitivity: Double, reactivity: Double) -> MusicSpectrumFrame {
        guard let source = activeSource else { return .silent }
        let dt = lastSampleTimestamp > 0 ? max(1.0 / 120.0, min(0.05, now - lastSampleTimestamp)) : (1.0 / 60.0)
        lastSampleTimestamp = now

        let samples: [Float]
        let balance: Float
        let rate: Double

        if source == .demoBeat {
            let chunkCount = max(512, min(2048, Int((demoSynth.sampleRate * dt).rounded())))
            let generated = demoSynth.render(frameCount: chunkCount)
            pushMonoSamples(generated.mono, balance: generated.stereoBalance, sampleRate: demoSynth.sampleRate)
            (samples, balance, rate) = readLatestSamples(count: MusicFFTProcessor.fftSize)
        } else {
            (samples, balance, rate) = readLatestSamples(count: MusicFFTProcessor.fftSize)
        }

        let frame = fft.process(
            monoSamples: samples,
            stereoBalance: balance,
            sampleRate: rate,
            dt: dt,
            sensitivity: sensitivity,
            reactivity: reactivity
        )

        if now - lastMeterPush >= 0.05 {
            lastMeterPush = now
            let downsampled: [Float] = (0..<16).map { i in
                let index = i * 2
                let sum = frame.bands[index] + frame.bands[index + 1]
                return sum * 0.5
            }
            let beat = frame.beatPulse
            DispatchQueue.main.async { [weak self] in
                self?.meterBands = downsampled
                self?.beatIndicator = beat
            }
        }

        return frame
    }

    // MARK: - Ring Buffer

    private func clearRingBuffer() {
        lock.lock()
        for i in 0..<ringBuffer.count { ringBuffer[i] = 0 }
        ringWriteIndex = 0
        ringFilled = 0
        liveBalance = 0
        lock.unlock()
    }

    private func pushMonoSamples(_ samples: [Float], balance: Float, sampleRate: Double) {
        guard !samples.isEmpty else { return }
        lock.lock()
        liveSampleRate = sampleRate
        liveBalance = liveBalance * 0.7 + balance * 0.3
        for s in samples {
            ringBuffer[ringWriteIndex] = s
            ringWriteIndex = (ringWriteIndex + 1) % Self.ringCapacity
            if ringFilled < Self.ringCapacity { ringFilled += 1 }
        }
        lock.unlock()
    }

    private func readLatestSamples(count: Int) -> ([Float], Float, Double) {
        lock.lock()
        let available = min(count, ringFilled)
        var out = [Float](repeating: 0, count: count)
        if available > 0 {
            let start = (ringWriteIndex - available + Self.ringCapacity) % Self.ringCapacity
            let outStart = count - available
            for i in 0..<available {
                out[outStart + i] = ringBuffer[(start + i) % Self.ringCapacity]
            }
        }
        let balance = liveBalance
        let rate = liveSampleRate
        lock.unlock()
        return (out, balance, rate)
    }

    // MARK: - Capture Management

    private func stopCaptureOnly() {
        if let engine = avEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            avEngine = nil
        }
        if #available(macOS 14.2, *) {
            stopSystemTap()
        }
    }

    private func publishStatus(_ newStatus: MusicAudioCaptureStatus) {
        DispatchQueue.main.async { [weak self] in
            self?.status = newStatus
        }
    }

    private func startMicrophone() {
        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        switch auth {
        case .authorized:
            installMicrophoneTap()
        case .notDetermined:
            publishStatus(.permissionNeeded("Allow Microphone access in prompt…"))
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.activeSource == .microphone else { return }
                    if granted {
                        self.installMicrophoneTap()
                    } else {
                        self.publishStatus(.permissionNeeded("Microphone permission denied."))
                    }
                }
            }
        case .denied, .restricted:
            publishStatus(.permissionNeeded("Microphone permission required."))
        @unknown default:
            publishStatus(.error("Microphone unavailable."))
        }
    }

    private func installMicrophoneTap() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            publishStatus(.error("No audio input device available."))
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let channelData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            guard frameLength > 0, channels > 0 else { return }

            var mono = [Float](repeating: 0, count: frameLength)
            var lSum: Float = 0
            var rSum: Float = 0
            let invChannels = 1.0 / Float(channels)
            for i in 0..<frameLength {
                var sum: Float = 0
                for c in 0..<channels {
                    let v = channelData[c][i]
                    sum += v
                    if c == 0 { lSum += v * v }
                    if c == 1 { rSum += v * v }
                }
                mono[i] = sum * invChannels
            }
            let bal = channels > 1 ? (rSum - lSum) / max(1e-6, lSum + rSum) : 0
            self.pushMonoSamples(mono, balance: bal, sampleRate: format.sampleRate)
        }
        do {
            try engine.start()
            avEngine = engine
            publishStatus(.listening(.microphone))
        } catch {
            input.removeTap(onBus: 0)
            publishStatus(.error("Mic failed: \(error.localizedDescription)"))
        }
    }

    private func startSystemAudio() {
        guard #available(macOS 14.2, *) else {
            publishStatus(.error("System Audio requires macOS 14.2+; use Mic or Demo."))
            return
        }
        startSystemTapMacOS14()
    }

    @available(macOS 14.2, *)
    private func startSystemTapMacOS14() {
        var excluded: [AudioObjectID] = []
        var pid = ProcessInfo.processInfo.processIdentifier
        var pidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processObj: AudioObjectID = kAudioObjectUnknown
        var propSize = UInt32(MemoryLayout<AudioObjectID>.size)
        if AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &pidAddr,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &propSize,
            &processObj
        ) == noErr, processObj != kAudioObjectUnknown {
            excluded.append(processObj)
        }

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.name = "kbd-display Music Tap"
        desc.muteBehavior = .unmuted
        desc.isPrivate = true

        var createdTapID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(desc, &createdTapID)
        guard tapStatus == noErr, createdTapID != kAudioObjectUnknown else {
            if tapStatus == kAudioHardwareIllegalOperationError || tapStatus == kAudioHardwareUnsupportedOperationError {
                publishStatus(.permissionNeeded("Allow System Audio Recording in Privacy Settings."))
            } else {
                publishStatus(.error("System Audio tap failed (\(tapStatus)). Try Demo or Mic."))
            }
            return
        }
        tapID = createdTapID

        let tapUID = desc.uuid.uuidString
        let aggUID = "com.kbd-display.music-tap.\(UUID().uuidString)"
        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "kbd-display Music Tap Device",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var createdAggID: AudioObjectID = kAudioObjectUnknown
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &createdAggID)
        guard aggStatus == noErr, createdAggID != kAudioObjectUnknown else {
            stopSystemTap()
            publishStatus(.error("Audio tap device failed (\(aggStatus))."))
            return
        }
        aggregateDeviceID = createdAggID

        // Inspect tap stream format on the aggregate device input scope
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = 48_000.0
        var isFloat = true
        var bitsPerChannel: UInt32 = 32
        if AudioObjectGetPropertyData(createdAggID, &fmtAddr, 0, nil, &asbdSize, &asbd) == noErr {
            if asbd.mSampleRate > 0 { sampleRate = asbd.mSampleRate }
            isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            if asbd.mBitsPerChannel > 0 { bitsPerChannel = asbd.mBitsPerChannel }
        }

        var procID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, createdAggID, nil) { [weak self] _, inInputData, _, _, _ in
            guard let self else { return }
            let bufList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard !bufList.isEmpty else { return }

            if bufList.count >= 2 {
                // Non-interleaved stereo (or multi-buffer)
                let bufL = bufList[0]
                let bufR = bufList[1]
                guard let ptrL = bufL.mData, let ptrR = bufR.mData else { return }
                let count = Int(bufL.mDataByteSize) / MemoryLayout<Float>.size
                guard count > 0, isFloat, bitsPerChannel == 32 else { return }
                let fL = ptrL.assumingMemoryBound(to: Float.self)
                let fR = ptrR.assumingMemoryBound(to: Float.self)
                var mono = [Float](repeating: 0, count: count)
                var lSum: Float = 0
                var rSum: Float = 0
                for i in 0..<count {
                    let l = fL[i], r = fR[i]
                    lSum += l * l; rSum += r * r
                    mono[i] = (l + r) * 0.5
                }
                let bal = (rSum - lSum) / max(1e-6, lSum + rSum)
                self.pushMonoSamples(mono, balance: bal, sampleRate: sampleRate)
            } else {
                // Interleaved single buffer
                let buf = bufList[0]
                guard let ptr = buf.mData else { return }
                let channels = max(1, Int(buf.mNumberChannels))
                if isFloat && bitsPerChannel == 32 {
                    let totalFloats = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                    let frames = totalFloats / channels
                    guard frames > 0 else { return }
                    let floats = ptr.assumingMemoryBound(to: Float.self)
                    var mono = [Float](repeating: 0, count: frames)
                    var lSum: Float = 0
                    var rSum: Float = 0
                    let invC = 1.0 / Float(channels)
                    for i in 0..<frames {
                        var sum: Float = 0
                        for c in 0..<channels {
                            let v = floats[i * channels + c]
                            sum += v
                            if c == 0 { lSum += v * v }
                            if c == 1 { rSum += v * v }
                        }
                        mono[i] = sum * invC
                    }
                    let bal = channels > 1 ? (rSum - lSum) / max(1e-6, lSum + rSum) : 0
                    self.pushMonoSamples(mono, balance: bal, sampleRate: sampleRate)
                } else if !isFloat && bitsPerChannel == 16 {
                    let totalSamples = Int(buf.mDataByteSize) / MemoryLayout<Int16>.size
                    let frames = totalSamples / channels
                    guard frames > 0 else { return }
                    let ints = ptr.assumingMemoryBound(to: Int16.self)
                    var mono = [Float](repeating: 0, count: frames)
                    let scale: Float = 1.0 / 32768.0
                    let invC = 1.0 / Float(channels)
                    for i in 0..<frames {
                        var sum: Float = 0
                        for c in 0..<channels {
                            sum += Float(ints[i * channels + c]) * scale
                        }
                        mono[i] = sum * invC
                    }
                    self.pushMonoSamples(mono, balance: 0, sampleRate: sampleRate)
                }
            }
        }

        guard ioStatus == noErr, let procID else {
            stopSystemTap()
            publishStatus(.error("Audio tap IO failed (\(ioStatus))."))
            return
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(createdAggID, procID)
        guard startStatus == noErr else {
            stopSystemTap()
            if startStatus == kAudioHardwareIllegalOperationError {
                publishStatus(.permissionNeeded("Allow System Audio Recording in Privacy Settings."))
            } else {
                publishStatus(.error("System Audio start failed (\(startStatus))."))
            }
            return
        }
        publishStatus(.listening(.systemAudio))
    }

    @available(macOS 14.2, *)
    private func stopSystemTap() {
        if aggregateDeviceID != kAudioObjectUnknown {
            if let procID = ioProcID {
                AudioDeviceStop(aggregateDeviceID, procID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
                ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }
}

import AVFoundation
import CoreAudio
import Foundation

/// Thread-safe snapshot of externally opened microphone activity and live voice amplitude.
struct PassiveMicSnapshot: Equatable {
    var externalMicOpen: Bool
    var amplitude: Float
    var peak: Float
    var brightness: Float
    var permissionDenied: Bool

    static let idle = PassiveMicSnapshot(
        externalMicOpen: false,
        amplitude: 0,
        peak: 0,
        brightness: 0,
        permissionDenied: false
    )
}

/// Passively observes whether another process (e.g. a dictation app) has opened an input microphone.
/// Never starts or activates microphone hardware on its own: it only attaches a read-only CoreAudio
/// IOProc while the configured shortcut is held AND another process already has `kAudioProcessPropertyIsRunningInput == 1`.
final class PassiveMicMonitor {
    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private let lock = NSLock()
    private var isHeld = false
    private var pollTimer: Timer?
    private var requestedMicPermission = false

    private var attachedDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var dcState: (prevIn: Float, prevOut: Float) = (0, 0)

    private var externalMicOpen = false
    private var permissionDenied = false
    private var latestAmplitude: Float = 0
    private var latestPeak: Float = 0
    private var latestBrightness: Float = 0
    private var lastSampleTimestamp: TimeInterval = 0

    var onChange: (() -> Void)?

    deinit {
        setHoldActive(false)
    }

    func setHoldActive(_ held: Bool) {
        lock.lock()
        let changed = isHeld != held
        isHeld = held
        lock.unlock()

        if held {
            guard changed else { return }
            startPolling()
            pollExternalMicState()
        } else {
            stopPolling()
            detachReader()
            lock.lock()
            externalMicOpen = false
            latestAmplitude = 0
            latestPeak = 0
            latestBrightness = 0
            lastSampleTimestamp = 0
            dcState = (0, 0)
            lock.unlock()
        }
    }

    func currentSnapshot(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> PassiveMicSnapshot {
        lock.lock()
        let stale = lastSampleTimestamp == 0 || (now - lastSampleTimestamp > 0.18)
        let snapshot = PassiveMicSnapshot(
            externalMicOpen: externalMicOpen,
            amplitude: stale ? 0 : latestAmplitude,
            peak: stale ? 0 : latestPeak,
            brightness: stale ? 0 : latestBrightness,
            permissionDenied: permissionDenied
        )
        lock.unlock()
        return snapshot
    }

    /// Pure DSP helper: strips DC offset / desk rumble and extracts perceptual vocal amplitude, peak, and brightness.
    static func computeVoiceMetrics(
        samples: [Float],
        dcState: inout (prevIn: Float, prevOut: Float)
    ) -> (amplitude: Float, peak: Float, brightness: Float) {
        guard !samples.isEmpty else { return (0, 0, 0) }
        var sumSq: Float = 0
        var peakAbs: Float = 0
        var prevSign = false
        var crossings = 0
        var prevIn = dcState.prevIn
        var prevOut = dcState.prevOut
        if prevIn == 0 && prevOut == 0 {
            prevIn = samples[0]
        }

        for i in 0..<samples.count {
            let x = samples[i]
            let y = x - prevIn + 0.96 * prevOut
            prevIn = x
            prevOut = y

            let absY = abs(y)
            sumSq += y * y
            if absY > peakAbs { peakAbs = absY }

            let sign = y >= 0
            if i > 0 && sign != prevSign && absY > 0.002 {
                crossings += 1
            }
            prevSign = sign
        }

        dcState = (prevIn, prevOut)
        let rms = sqrt(sumSq / Float(samples.count))
        let noiseFloor: Float = 0.0025
        let amp = min(1.0, pow(max(0.0, (rms - noiseFloor) * 7.5), 0.62))
        let peak = min(1.0, pow(max(0.0, (peakAbs - noiseFloor) * 3.8), 0.72))
        let zcr = Float(crossings) / Float(max(1, samples.count - 1))
        let brightness = amp > 0.02 ? min(1.0, zcr * 3.2) : 0
        return (amp, peak, brightness)
    }

    private func startPolling() {
        guard !Self.isRunningTests else { return }
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.startPolling() }
            return
        }
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.pollExternalMicState()
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPolling() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.stopPolling() }
            return
        }
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollExternalMicState() {
        guard !Self.isRunningTests else { return }
        lock.lock()
        let held = isHeld
        lock.unlock()
        guard held else { return }

        let extDevice = detectExternalActiveInputDevice()
        if let extDevice {
            updateExternalMicState(open: true)
            if attachedDeviceID == extDevice && ioProcID != nil {
                return
            }
            if attachedDeviceID != kAudioObjectUnknown {
                detachReader()
            }

            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                updatePermissionDenied(false)
                attachReader(to: extDevice)
            case .notDetermined:
                if !requestedMicPermission {
                    requestedMicPermission = true
                    AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.updatePermissionDenied(!granted)
                            self.pollExternalMicState()
                        }
                    }
                }
            case .denied, .restricted:
                updatePermissionDenied(true)
            @unknown default:
                break
            }
        } else {
            updateExternalMicState(open: false)
            detachReader()
        }
    }

    private func updateExternalMicState(open: Bool) {
        lock.lock()
        let changed = externalMicOpen != open
        externalMicOpen = open
        if !open {
            latestAmplitude = 0
            latestPeak = 0
            latestBrightness = 0
        }
        lock.unlock()
        if changed {
            DispatchQueue.main.async { [weak self] in self?.onChange?() }
        }
    }

    private func updatePermissionDenied(_ denied: Bool) {
        lock.lock()
        let changed = permissionDenied != denied
        permissionDenied = denied
        lock.unlock()
        if changed {
            DispatchQueue.main.async { [weak self] in self?.onChange?() }
        }
    }

    // MARK: - Passive CoreAudio HAL Detection

    private func detectExternalActiveInputDevice() -> AudioDeviceID? {
        let myPID = ProcessInfo.processInfo.processIdentifier
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
           size >= MemoryLayout<AudioObjectID>.size {
            let count = Int(size) / MemoryLayout<AudioObjectID>.size
            var procIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
            if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &procIDs) == noErr {
                for proc in procIDs where proc != kAudioObjectUnknown {
                    var pid: pid_t = 0
                    var pidSize = UInt32(MemoryLayout<pid_t>.size)
                    var pidAddr = AudioObjectPropertyAddress(
                        mSelector: kAudioProcessPropertyPID,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    guard AudioObjectGetPropertyData(proc, &pidAddr, 0, nil, &pidSize, &pid) == noErr,
                          pid != myPID else { continue }

                    var runningInput: UInt32 = 0
                    var runSize = UInt32(MemoryLayout<UInt32>.size)
                    var runAddr = AudioObjectPropertyAddress(
                        mSelector: kAudioProcessPropertyIsRunningInput,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    guard AudioObjectGetPropertyData(proc, &runAddr, 0, nil, &runSize, &runningInput) == noErr,
                          runningInput != 0 else { continue }

                    if let dev = firstInputDevice(forProcess: proc) {
                        return dev
                    }
                    if let fallback = defaultInputDeviceID(), deviceHasInputStreams(fallback) {
                        return fallback
                    }
                }
                return nil
            }
        }

        // Fallback when process object list is unavailable: only check while our own reader is detached.
        if attachedDeviceID == kAudioObjectUnknown,
           let def = defaultInputDeviceID(),
           deviceHasInputStreams(def),
           isDeviceRunningSomewhere(def) {
            return def
        }
        return nil
    }

    private func firstInputDevice(forProcess processObject: AudioObjectID) -> AudioDeviceID? {
        var devAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(processObject, &devAddr, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioDeviceID>.size else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(processObject, &devAddr, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first { $0 != kAudioObjectUnknown && deviceHasInputStreams($0) }
    }

    private func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private func deviceHasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr else { return false }
        return size >= MemoryLayout<AudioStreamID>.size
    }

    private func isDeviceRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    // MARK: - Lightweight Input IOProc Attachment

    private func attachReader(to deviceID: AudioDeviceID) {
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var isFloat = true
        var bitsPerChannel: UInt32 = 32
        if AudioObjectGetPropertyData(deviceID, &fmtAddr, 0, nil, &asbdSize, &asbd) == noErr {
            isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            if asbd.mBitsPerChannel > 0 { bitsPerChannel = asbd.mBitsPerChannel }
        }

        var procID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { [weak self] _, inInputData, _, _, _ in
            guard let self else { return }
            self.processAudioBufferList(inInputData, isFloat: isFloat, bitsPerChannel: bitsPerChannel)
        }
        guard ioStatus == noErr, let procID else { return }

        let startStatus = AudioDeviceStart(deviceID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, procID)
            return
        }
        attachedDeviceID = deviceID
        ioProcID = procID
    }

    private func processAudioBufferList(
        _ inputData: UnsafePointer<AudioBufferList>,
        isFloat: Bool,
        bitsPerChannel: UInt32
    ) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let first = list.first, let ptr = first.mData else { return }

        var mono: [Float] = []
        if isFloat && bitsPerChannel == 32 {
            let channels = max(1, Int(first.mNumberChannels))
            let totalFloats = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let frames = totalFloats / channels
            guard frames > 0 else { return }
            let floats = ptr.assumingMemoryBound(to: Float.self)
            mono.reserveCapacity(frames)
            if channels == 1 {
                for i in 0..<frames { mono.append(floats[i]) }
            } else {
                let inv = 1.0 / Float(channels)
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += floats[i * channels + c] }
                    mono.append(sum * inv)
                }
            }
        } else if !isFloat && bitsPerChannel == 16 {
            let channels = max(1, Int(first.mNumberChannels))
            let totalSamples = Int(first.mDataByteSize) / MemoryLayout<Int16>.size
            let frames = totalSamples / channels
            guard frames > 0 else { return }
            let ints = ptr.assumingMemoryBound(to: Int16.self)
            mono.reserveCapacity(frames)
            let inv = 1.0 / (32768.0 * Float(channels))
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += Float(ints[i * channels + c]) }
                mono.append(sum * inv)
            }
        } else {
            return
        }

        lock.lock()
        var state = dcState
        let metrics = Self.computeVoiceMetrics(samples: mono, dcState: &state)
        dcState = state
        latestAmplitude = latestAmplitude * 0.45 + metrics.amplitude * 0.55
        latestPeak = max(latestPeak * 0.72, metrics.peak)
        latestBrightness = latestBrightness * 0.5 + metrics.brightness * 0.5
        lastSampleTimestamp = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    private func detachReader() {
        guard attachedDeviceID != kAudioObjectUnknown else { return }
        if let procID = ioProcID {
            AudioDeviceStop(attachedDeviceID, procID)
            AudioDeviceDestroyIOProcID(attachedDeviceID, procID)
            ioProcID = nil
        }
        attachedDeviceID = kAudioObjectUnknown
    }
}

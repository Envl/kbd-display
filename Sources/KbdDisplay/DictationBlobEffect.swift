import AppKit
import Foundation
import Metal
import simd

/// Shared Metal compute pipeline for the Dictation Voice Blob shader, reusing MusicMetalContext's device & keycap SDF.
final class DictationMetalPipeline {
    static let shared = DictationMetalPipeline()

    let pipeline: MTLComputePipelineState?

    private init() {
        guard let dev = MusicMetalContext.shared.device else {
            pipeline = nil
            return
        }
        do {
            let lib = try dev.makeLibrary(source: Self.shaderSource, options: nil)
            if let fn = lib.makeFunction(name: "dictationBlob") {
                pipeline = try dev.makeComputePipelineState(function: fn)
            } else {
                pipeline = nil
            }
        } catch {
            print("DictationMetalPipeline shader compile error: \(error)")
            pipeline = nil
        }
    }

    struct UniformsGPU {
        var time: Float
        var visibility: Float
        var amplitude: Float
        var peak: Float
        var brightness: Float
        var micOpen: Float
        var ripplePhase: Float
        var pad0: Float = 0
        var keyCenter: SIMD2<Float>
        var keyHalfSize: SIMD2<Float>
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct DictationUniforms {
        float time;
        float visibility;
        float amplitude;
        float peak;
        float brightness;
        float micOpen;
        float ripplePhase;
        float pad0;
        float2 keyCenter;
        float2 keyHalfSize;
    };

    float roundedBoxSDF(float2 p, float2 b, float r) {
        float2 q = abs(p) - b + r;
        return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
    }

    float hash21(float2 p) {
        float3 q = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
        q += dot(q, q.yzx + 33.33);
        return fract((q.x + q.y) * q.z);
    }

    float valueNoise(float2 p) {
        float2 i = floor(p), f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash21(i), hash21(i + float2(1, 0)), f.x),
                   mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), f.x), f.y);
    }

    float fbm(float2 p) {
        return 0.55 * valueNoise(p) + 0.30 * valueNoise(p * 2.13 + 7.1) + 0.15 * valueNoise(p * 4.31 + 19.7);
    }

    float3 foilPalette(float t, float3 a, float3 b, float3 d) {
        return a + b * cos(2.0 * M_PI_F * (0.5 * t + d));
    }

    float3 gradeColor(float3 rgb, float hueShift, float chroma) {
        float3 c = rgb;
        if (abs(hueShift) > 1e-5) {
            float angle = hueShift * 2.0 * M_PI_F;
            float cosA = cos(angle), sinA = sin(angle);
            float3 k = float3(0.57735027);
            c = c * cosA + cross(k, c) * sinA + k * dot(k, c) * (1.0 - cosA);
        }
        if (abs(chroma - 1.0) > 1e-5) {
            float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
            c = mix(float3(luma), c, chroma);
        }
        return max(float3(0.0), c);
    }

    float blobDistance(float2 rel, float angle, DictationUniforms u) {
        float baseR = (98.0 + 195.0 * u.amplitude + 48.0 * u.peak) * (0.50 + 0.50 * u.visibility);
        float wobbleStrength = 0.08 + 0.24 * u.amplitude + 0.14 * u.brightness;
        float harmonic = sin(angle * 3.0 + u.time * 2.4) * 0.45
                       + cos(angle * 5.0 - u.time * 3.3) * 0.32
                       + sin(angle * 7.0 + u.time * 4.7) * 0.23;
        float n = fbm(float2(cos(angle) * 1.4 + u.time * 0.55, sin(angle) * 1.4 - u.time * 0.45)) - 0.5;
        float radius = baseR * (1.0 + wobbleStrength * harmonic + (0.14 + 0.22 * u.amplitude) * n);
        return length(rel) - radius;
    }

    kernel void dictationBlob(device uchar4 *pixels [[buffer(0)]],
                              constant float4 *sdfGrid [[buffer(1)]],
                              constant uint2 &dims [[buffer(2)]],
                              constant DictationUniforms &u [[buffer(3)]],
                              constant float4 *colorParams [[buffer(4)]],
                              uint2 id [[thread_position_in_grid]]) {
        if (id.x >= dims.x || id.y >= dims.y) return;
        uint idx = id.y * dims.x + id.x;

        float2 pos = float2((float(id.x) + 0.5) * (1920.0 / float(dims.x)),
                            (float(dims.y - 1 - id.y) + 0.5) * (720.0 / float(dims.y)));
        float2 rel = pos - u.keyCenter;
        float dist = length(rel);
        if (dist > 520.0 || u.visibility <= 0.002) {
            pixels[idx] = uchar4(0);
            return;
        }

        float4 sdf = sdfGrid[idx];
        float keyDist = sdf.x;
        float2 keyNormal = sdf.yz;
        float dOptKey = roundedBoxSDF(rel, u.keyHalfSize, 12.0);

        float3 palA = colorParams[0].xyz;
        float3 palB = colorParams[1].xyz;
        float3 palD = colorParams[2].xyz;
        float hueShift = colorParams[0].w;
        float chroma = colorParams[1].w;
        float intensity = colorParams[2].w;

        float angle = atan2(rel.y, rel.x);
        float dBlob = blobDistance(rel, angle, u);

        // Compute organic normal via finite differences for liquid 3D shading
        float eps = 3.0;
        float2 relX = rel + float2(eps, 0.0);
        float2 relY = rel + float2(0.0, eps);
        float dX = blobDistance(relX, atan2(relX.y, relX.x), u);
        float dY = blobDistance(relY, atan2(relY.y, relY.x), u);
        float2 grad = float2(dX - dBlob, dY - dBlob) / eps;

        float body = smoothstep(26.0, -34.0, dBlob);
        float rimGlow = exp(-0.0014 * dBlob * dBlob) * (0.42 + 0.65 * u.amplitude);
        float outerAura = exp(-dist * (0.011 - 0.004 * u.amplitude)) * (0.28 + 0.45 * u.amplitude + 0.2 * u.micOpen);

        float sdfEdge = exp(-0.14 * keyDist * keyDist);
        float2 refractXY = grad * (0.75 + 0.55 * u.amplitude) + keyNormal * sdfEdge * 0.38;
        float nz = sqrt(max(0.04, 1.0 - saturate(dot(refractXY, refractXY) * 0.35)));
        float3 N = normalize(float3(refractXY, nz));
        float fresnel = pow(1.0 - saturate(N.z), 2.4);

        float3 L = normalize(float3(0.35, 0.55, 0.85));
        float3 H = normalize(L + float3(0.0, 0.0, 1.0));
        float spec = pow(saturate(dot(N, H)), 42.0) * body;

        // Core vocal brightness & palette iridescence
        float hueT = angle / (2.0 * M_PI_F) + dist * 0.0022 - u.time * 0.14 + u.brightness * 0.25;
        float3 colA = foilPalette(hueT, palA, palB, palD);
        float3 colB = foilPalette(hueT + 0.26, palA, palB, palD);
        float3 blobCol = mix(colA, colB, fresnel);

        float coreHeat = exp(-dist * (0.016 - 0.007 * u.amplitude)) * (0.45 + 0.85 * u.amplitude + 0.35 * u.peak);
        float3 innerCore = mix(blobCol, float3(0.94, 0.98, 1.0), saturate(coreHeat * 0.65));

        // Selected keycap rim & neighboring keycap SDF light wrap
        float optRim = exp(-0.32 * dOptKey * dOptKey) * (0.85 + 0.65 * u.amplitude + 0.30 * u.micOpen);
        float neighborWrap = sdfEdge * exp(-dist * 0.0062) * (0.45 + 0.75 * u.amplitude);

        // Acoustic shockwave ring emitted during vocal peaks
        float ringR = 55.0 + fract(u.ripplePhase) * (230.0 + 140.0 * u.amplitude);
        float ring = exp(-0.0042 * pow(dist - ringR, 2.0)) * (1.0 - fract(u.ripplePhase)) * (0.24 + 0.80 * u.peak);

        float3 rgb = innerCore * (body * (0.85 + 0.75 * u.amplitude) + outerAura * 1.15)
                   + colB * (rimGlow * 1.2 + neighborWrap * 0.95 + ring)
                   + mix(colA, float3(0.95, 0.99, 1.0), 0.55) * (optRim + spec * 0.95);

        float alpha = saturate((max(body * 0.96, max(rimGlow * 0.92, outerAura * 0.85)) + optRim * 0.8 + neighborWrap * 0.55 + ring * 0.72) * u.visibility);
        rgb = gradeColor(rgb, hueShift, chroma) * intensity * u.visibility;
        float alphaGain = abs(intensity - 1.0) < 1e-4 ? 1.0 : min(1.35, 0.35 + 0.65 * intensity);
        float outA = saturate(alpha * alphaGain);
        rgb = clamp(rgb, 0.0, outA);
        pixels[idx] = uchar4(float4(rgb, outA) * 255.0 + 0.5);
    }
    """
}

/// GPU + fallback renderer for the dictation voice blob.
final class DictationBlobShader {
    private let lock = NSLock()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var pixelBuffer: MTLBuffer?

    init() {
        if let dev = MusicMetalContext.shared.device {
            let byteCount = MusicMetalContext.renderWidth * MusicMetalContext.renderHeight * 4
            pixelBuffer = dev.makeBuffer(length: byteCount, options: .storageModeShared)
        }
    }

    func render(uniforms: DictationMetalPipeline.UniformsGPU, colors: EffectColorParams) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let queue = MusicMetalContext.shared.queue,
              let sdfBuf = MusicMetalContext.shared.sdfBuffer,
              let pipe = DictationMetalPipeline.shared.pipeline,
              let pixBuf = pixelBuffer,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder()
        else { return nil }

        let rw = MusicMetalContext.renderWidth
        let rh = MusicMetalContext.renderHeight
        var dims = SIMD2<UInt32>(UInt32(rw), UInt32(rh))
        var u = uniforms
        let colorVecs = [colors.palA, colors.palB, colors.palD]

        enc.setComputePipelineState(pipe)
        enc.setBuffer(pixBuf, offset: 0, index: 0)
        enc.setBuffer(sdfBuf, offset: 0, index: 1)
        enc.setBytes(&dims, length: MemoryLayout<SIMD2<UInt32>>.size, index: 2)
        enc.setBytes(&u, length: MemoryLayout<DictationMetalPipeline.UniformsGPU>.stride, index: 3)
        enc.setBytes(colorVecs, length: colorVecs.count * MemoryLayout<SIMD4<Float>>.stride, index: 4)
        enc.dispatchThreads(MTLSize(width: rw, height: rh, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        guard cmd.status == .completed else { return nil }

        let data = Data(bytes: pixBuf.contents(), count: rw * rh * 4)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: rw,
            height: rh,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: rw * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

/// Stateful animation model for the dictation voice blob.
final class DictationBlobEffect {
    var anchor = DictationShortcut.rightOption { didSet { cachedImage = nil } }
    static let holdDebounce: TimeInterval = 0.06

    private let shader = DictationBlobShader()
    private(set) var isKeyHeld = false
    private(set) var holdStartedAt: TimeInterval?
    private(set) var visibility: Float = 0
    private(set) var smoothedAmplitude: Float = 0
    private(set) var smoothedPeak: Float = 0
    private(set) var smoothedBrightness: Float = 0
    private(set) var micOpen = false
    private(set) var animTime: TimeInterval = 0
    private var ripplePhase: Float = 0

    private var cachedImage: CGImage?
    private var cachedTime: TimeInterval = -1
    private var cachedColors: EffectColorParams?

    var isActive: Bool { isKeyHeld || visibility > 0.005 }

    func setKeyHeld(_ held: Bool, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if held && !isKeyHeld {
            holdStartedAt = now
        } else if !held {
            holdStartedAt = nil
        }
        isKeyHeld = held
    }

    func reset() {
        isKeyHeld = false
        holdStartedAt = nil
        visibility = 0
        smoothedAmplitude = 0
        smoothedPeak = 0
        smoothedBrightness = 0
        micOpen = false
        ripplePhase = 0
        cachedImage = nil
    }

    func step(dt: Double, now: TimeInterval, micSnapshot: PassiveMicSnapshot) {
        let safeDt = max(1.0 / 180.0, min(0.05, dt))
        animTime += safeDt
        micOpen = micSnapshot.externalMicOpen

        let debouncePassed = holdStartedAt.map { now - $0 >= Self.holdDebounce } ?? false
        let shouldShow = isKeyHeld && (micSnapshot.externalMicOpen || debouncePassed)

        if shouldShow {
            visibility = min(1.0, visibility + Float(safeDt * 7.5))
        } else {
            visibility = max(0.0, visibility - Float(safeDt * 3.4))
        }

        let targetAmp = isKeyHeld ? micSnapshot.amplitude : 0
        if targetAmp > smoothedAmplitude {
            smoothedAmplitude = smoothedAmplitude * 0.52 + targetAmp * 0.48
        } else {
            smoothedAmplitude = smoothedAmplitude * 0.85 + targetAmp * 0.15
        }

        let targetPeak = isKeyHeld ? micSnapshot.peak : 0
        smoothedPeak = max(smoothedPeak * 0.84, targetPeak)
        smoothedBrightness = smoothedBrightness * 0.72 + (isKeyHeld ? micSnapshot.brightness : 0) * 0.28

        if isKeyHeld {
            ripplePhase += Float(safeDt) * (0.45 + smoothedPeak * 1.45)
        }

        cachedImage = nil
    }

    func draw(in context: CGContext, colors: EffectColorParams) {
        guard visibility > 0.005, let keyRect = Action75.rects[anchor] else { return }
        let tile = keyRect.insetBy(dx: 5, dy: 5)

        let img: CGImage?
        if let cachedImage, cachedTime == animTime, cachedColors == colors {
            img = cachedImage
        } else {
            let uniforms = DictationMetalPipeline.UniformsGPU(
                time: Float(animTime),
                visibility: visibility,
                amplitude: smoothedAmplitude,
                peak: smoothedPeak,
                brightness: smoothedBrightness,
                micOpen: micOpen ? 1.0 : 0.0,
                ripplePhase: ripplePhase,
                keyCenter: SIMD2<Float>(Float(tile.midX), Float(tile.midY)),
                keyHalfSize: SIMD2<Float>(Float(tile.width * 0.5), Float(tile.height * 0.5))
            )
            img = shader.render(uniforms: uniforms, colors: colors)
            cachedImage = img
            cachedTime = animTime
            cachedColors = colors
        }

        if let img {
            context.saveGState()
            context.setBlendMode(.plusLighter)
            context.draw(img, in: CGRect(origin: .zero, size: Action75.canvas))
            context.restoreGState()
        } else {
            drawFallback(in: context, tile: tile, colors: colors)
        }
    }

    private func drawFallback(in context: CGContext, tile: CGRect, colors: EffectColorParams) {
        let center = CGPoint(x: tile.midX, y: tile.midY)
        let r = CGFloat((85.0 + 150.0 * smoothedAmplitude) * visibility)
        let col = colors.samplePalette(at: Float(fmod(animTime * 0.15, 1.0)))
        context.saveGState()
        context.setBlendMode(.plusLighter)
        context.setFillColor(col.withAlphaComponent(CGFloat(0.55 * visibility)).cgColor)
        context.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        context.restoreGState()
    }
}

/// Shared coordinator connecting shortcut state, PassiveMicMonitor, and both BoardViews.
final class DictationBlobController: ObservableObject {
    static let shared = DictationBlobController()

    @Published private(set) var statusText = "Ready"
    @Published private(set) var isExternalMicOpen: Bool = false
    @Published private(set) var liveAmplitude: Float = 0
    @Published private(set) var permissionDenied: Bool = false

    let effect = DictationBlobEffect()
    private let micMonitor = PassiveMicMonitor()
    private var enabled = true
    private(set) var shortcut = DictationShortcut.standard
    private var heldKeys: Set<UInt16> = []
    private var shortcutHeld: Bool { shortcut.keys.allSatisfy(heldKeys.contains) }
    private var previewUntil: TimeInterval?
    private var previewStart: TimeInterval = 0
    private var lastStepTime: TimeInterval = 0
    private var lastStatusPush: TimeInterval = 0

    var onStateChange: (() -> Void)?

    var isActive: Bool { enabled && effect.isActive }
    private var isPreviewing: Bool { previewUntil != nil }

    private init() {
        micMonitor.onChange = { [weak self] in
            self?.refreshPublishedState(now: ProcessInfo.processInfo.systemUptime)
            self?.onStateChange?()
        }
    }

    func setEnabled(_ newValue: Bool) {
        guard enabled != newValue else { return }
        enabled = newValue
        stop()
        onStateChange?()
    }

    func setShortcut(_ newValue: DictationShortcut) {
        guard shortcut != newValue else { return }
        shortcut = newValue
        effect.anchor = newValue.anchor
        stop()
        onStateChange?()
    }

    func setKey(_ code: UInt16, held: Bool, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard enabled, shortcut.keys.contains(code) else { return }
        let wasHeld = shortcutHeld
        if held { heldKeys.insert(code) } else { heldKeys.remove(code) }
        if wasHeld != shortcutHeld { syncEffectiveHold(at: now) }
    }

    func triggerPreview(duration: TimeInterval = 2.6, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard enabled else { return }
        previewStart = now
        previewUntil = now + max(0.4, duration)
        syncEffectiveHold(at: now)
    }

    private func syncEffectiveHold(at now: TimeInterval) {
        let physicalHeld = shortcutHeld
        let effectiveHeld = physicalHeld || isPreviewing
        let wasHeld = effect.isKeyHeld
        if wasHeld != effectiveHeld {
            effect.setKeyHeld(effectiveHeld, at: now)
            if effectiveHeld { lastStepTime = 0 }
        }
        micMonitor.setHoldActive(physicalHeld)
        refreshPublishedState(now: now)
        onStateChange?()
    }

    func stop() {
        heldKeys.removeAll()
        previewUntil = nil
        micMonitor.setHoldActive(false)
        effect.reset()
        lastStepTime = 0
        refreshPublishedState(now: ProcessInfo.processInfo.systemUptime)
    }

    func draw(in context: CGContext, now: TimeInterval, settings: EffectConfiguration) {
        guard enabled, settings.dictationVoiceBlob else { return }

        if let until = previewUntil, now >= until {
            previewUntil = nil
            syncEffectiveHold(at: now)
        }

        let dt = lastStepTime > 0 ? now - lastStepTime : (1.0 / 60.0)
        if lastStepTime == 0 || dt >= 1.0 / 90.0 {
            lastStepTime = now
            let snap: PassiveMicSnapshot
            if let until = previewUntil, now < until && !shortcutHeld {
                let u = now - previewStart
                let speech = Float(0.28 + 0.52 * abs(sin(u * 5.8)) * (0.65 + 0.35 * sin(u * 13.0)))
                snap = PassiveMicSnapshot(
                    externalMicOpen: true,
                    amplitude: speech,
                    peak: min(1.0, speech * 1.15),
                    brightness: Float(0.35 + 0.35 * abs(cos(u * 9.0))),
                    permissionDenied: false
                )
            } else {
                snap = micMonitor.currentSnapshot(now: now)
            }
            effect.step(dt: dt, now: now, micSnapshot: snap)
            if now - lastStatusPush >= 0.05 {
                lastStatusPush = now
                refreshPublishedState(now: now, snapshot: snap)
            }
        }

        effect.draw(in: context, colors: settings.colorParams)
    }

    private func refreshPublishedState(now: TimeInterval, snapshot: PassiveMicSnapshot? = nil) {
        let snap = snapshot ?? micMonitor.currentSnapshot(now: now)
        let held = effect.isKeyHeld
        let amp = effect.smoothedAmplitude
        let text: String
        if !enabled {
            text = "Off"
        } else if isPreviewing && !shortcutHeld {
            text = "Previewing voice blob…"
        } else if !held {
            text = "Ready"
        } else if snap.permissionDenied {
            text = "Microphone access needed"
        } else if snap.externalMicOpen {
            text = "Responding to your voice"
        } else {
            text = "Waiting for microphone"
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusText = text
            self.isExternalMicOpen = snap.externalMicOpen
            self.liveAmplitude = amp
            self.permissionDenied = snap.permissionDenied
        }
    }
}

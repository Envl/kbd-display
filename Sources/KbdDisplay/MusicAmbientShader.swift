import AppKit
import Metal
import simd

/// Shared Metal device, compiled compute pipelines, and prebaked 640x240 Action75 keycap SDF.
final class MusicMetalContext {
    static let shared = MusicMetalContext()

    static let renderWidth = 640
    static let renderHeight = 240
    static let waterWidth = 240
    static let waterHeight = 90

    let device: MTLDevice?
    let queue: MTLCommandQueue?
    let sdfBuffer: MTLBuffer?
    let waterImpulsePipe: MTLComputePipelineState?
    let waterStepPipe: MTLComputePipelineState?
    let waterRenderPipe: MTLComputePipelineState?
    let visualPipes: [MusicVisualStyle: MTLComputePipelineState]

    private init() {
        let rw = Self.renderWidth
        let rh = Self.renderHeight
        guard let dev = MTLCreateSystemDefaultDevice(),
              let cmdQueue = dev.makeCommandQueue()
        else {
            device = nil; queue = nil; sdfBuffer = nil
            waterImpulsePipe = nil; waterStepPipe = nil; waterRenderPipe = nil
            visualPipes = [:]
            return
        }

        let library: MTLLibrary
        do {
            library = try dev.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            print("MusicMetalContext shader compile error: \(error)")
            device = nil; queue = nil; sdfBuffer = nil
            waterImpulsePipe = nil; waterStepPipe = nil; waterRenderPipe = nil
            visualPipes = [:]
            return
        }

        func pipe(_ name: String) -> MTLComputePipelineState? {
            guard let fn = library.makeFunction(name: name) else { return nil }
            return try? dev.makeComputePipelineState(function: fn)
        }

        guard let bakePipe = pipe("musicBakeSDF"),
              let impulsePipe = pipe("waterImpulse"),
              let stepPipe = pipe("waterStep"),
              let renderPipe = pipe("waterRender"),
              let sdfBuf = dev.makeBuffer(length: rw * rh * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)
        else {
            device = nil; queue = nil; sdfBuffer = nil
            waterImpulsePipe = nil; waterStepPipe = nil; waterRenderPipe = nil
            visualPipes = [:]
            return
        }

        var pipes: [MusicVisualStyle: MTLComputePipelineState] = [:]
        let kernelMap: [(MusicVisualStyle, String)] = [
            (.auroraRibbons, "musicAurora"),
            (.ferrofluid, "musicFerrofluid"),
            (.plasmaNebula, "musicPlasmaNebula"),
            (.cymatics, "musicCymatics"),
            (.radialPulse, "musicRadialPulse"),
            (.audioFire, "musicAudioFire"),
            (.lavaLamp, "musicLavaLamp")
        ]
        for (style, fnName) in kernelMap {
            if let p = pipe(fnName) {
                pipes[style] = p
            }
        }

        device = dev
        queue = cmdQueue
        sdfBuffer = sdfBuf
        waterImpulsePipe = impulsePipe
        waterStepPipe = stepPipe
        waterRenderPipe = renderPipe
        visualPipes = pipes

        let keyBoxes: [SIMD4<Float>] = Action75.rects.values.map { rect in
            let tile = rect.insetBy(dx: 5, dy: 5)
            return SIMD4<Float>(Float(tile.midX), Float(tile.midY), Float(tile.width * 0.5), Float(tile.height * 0.5))
        }
        if let command = cmdQueue.makeCommandBuffer(),
           let encoder = command.makeComputeCommandEncoder() {
            var dims = SIMD2<UInt32>(UInt32(rw), UInt32(rh))
            var count = UInt32(keyBoxes.count)
            encoder.setComputePipelineState(bakePipe)
            encoder.setBuffer(sdfBuf, offset: 0, index: 0)
            encoder.setBytes(&dims, length: MemoryLayout<SIMD2<UInt32>>.size, index: 1)
            encoder.setBytes(keyBoxes, length: keyBoxes.count * MemoryLayout<SIMD4<Float>>.stride, index: 2)
            encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 3)
            encoder.dispatchThreads(MTLSize(width: rw, height: rh, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
        }
    }

    struct WaterImpulseGPU {
        var normPos: SIMD2<Float>
        var radius: Float
        var strength: Float
        var huePhase: Float
        var pad0: Float = 0
        var pad1: Float = 0
        var pad2: Float = 0
    }

    struct MusicUniformsGPU {
        var time: Float
        var subBass: Float
        var bass: Float
        var mids: Float
        var highs: Float
        var energy: Float
        var level: Float
        var beatPulse: Float
        var snarePulse: Float
        var hatPulse: Float
        var dominantPitch: Float
        var stereoBalance: Float
        var intensity: Float
        var reactivity: Float
        var beatCount: UInt32
        var pad: UInt32 = 0
    }
}

/// Per-renderer Metal simulation state (water ping-pong buffers & output frame) for 8 GPU music visuals.
final class MusicAmbientShader {
    private let ctx = MusicMetalContext.shared
    private let lock = NSLock()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private var waterPrev: MTLBuffer?
    private var waterCurr: MTLBuffer?
    private var waterNext: MTLBuffer?
    private var waterTintA: MTLBuffer?
    private var waterTintB: MTLBuffer?
    private var pixelBuffer: MTLBuffer?
    private(set) var waterEnergy: Float = 0

    init() {
        guard let dev = ctx.device else { return }
        let wCount = MusicMetalContext.waterWidth * MusicMetalContext.waterHeight
        let rCount = MusicMetalContext.renderWidth * MusicMetalContext.renderHeight
        waterPrev = dev.makeBuffer(length: wCount * MemoryLayout<Float>.stride, options: .storageModeShared)
        waterCurr = dev.makeBuffer(length: wCount * MemoryLayout<Float>.stride, options: .storageModeShared)
        waterNext = dev.makeBuffer(length: wCount * MemoryLayout<Float>.stride, options: .storageModeShared)
        waterTintA = dev.makeBuffer(length: wCount * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)
        waterTintB = dev.makeBuffer(length: wCount * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)
        pixelBuffer = dev.makeBuffer(length: rCount * 4, options: .storageModeShared)
        resetWater()
    }

    var isGPUAvailable: Bool {
        ctx.device != nil && ctx.queue != nil && ctx.sdfBuffer != nil && pixelBuffer != nil
    }

    func resetWater() {
        lock.lock()
        defer { lock.unlock() }
        let wCount = MusicMetalContext.waterWidth * MusicMetalContext.waterHeight
        if let waterPrev { memset(waterPrev.contents(), 0, wCount * MemoryLayout<Float>.stride) }
        if let waterCurr { memset(waterCurr.contents(), 0, wCount * MemoryLayout<Float>.stride) }
        if let waterNext { memset(waterNext.contents(), 0, wCount * MemoryLayout<Float>.stride) }
        if let waterTintA { memset(waterTintA.contents(), 0, wCount * MemoryLayout<SIMD4<Float>>.stride) }
        if let waterTintB { memset(waterTintB.contents(), 0, wCount * MemoryLayout<SIMD4<Float>>.stride) }
        waterEnergy = 0
    }

    func stepWater(impulses: [MusicMetalContext.WaterImpulseGPU], substeps: Int = 2) {
        lock.lock()
        defer { lock.unlock() }
        guard let queue = ctx.queue,
              let impPipe = ctx.waterImpulsePipe,
              let stepPipe = ctx.waterStepPipe,
              let wPrev = waterPrev,
              let wCurr = waterCurr,
              let wNext = waterNext,
              let tA = waterTintA,
              let tB = waterTintB,
              let command = queue.makeCommandBuffer()
        else { return }

        let ww = MusicMetalContext.waterWidth
        let wh = MusicMetalContext.waterHeight
        var wDims = SIMD2<UInt32>(UInt32(ww), UInt32(wh))
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: ww, height: wh, depth: 1)

        if !impulses.isEmpty, let enc = command.makeComputeCommandEncoder() {
            var count = UInt32(min(24, impulses.count))
            let clipped = Array(impulses.prefix(24))
            enc.setComputePipelineState(impPipe)
            enc.setBuffer(wCurr, offset: 0, index: 0)
            enc.setBuffer(tA, offset: 0, index: 1)
            enc.setBytes(&wDims, length: MemoryLayout<SIMD2<UInt32>>.size, index: 2)
            enc.setBytes(clipped, length: clipped.count * MemoryLayout<MusicMetalContext.WaterImpulseGPU>.stride, index: 3)
            enc.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 4)
            enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
            enc.endEncoding()
            for imp in clipped {
                waterEnergy = min(3.0, waterEnergy + abs(imp.strength) * 0.25)
            }
        }

        var prevBuf = wPrev
        var currBuf = wCurr
        var nextBuf = wNext
        var tintIn = tA
        var tintOut = tB

        for _ in 0..<max(1, substeps) {
            guard let enc = command.makeComputeCommandEncoder() else { break }
            enc.setComputePipelineState(stepPipe)
            enc.setBuffer(prevBuf, offset: 0, index: 0)
            enc.setBuffer(currBuf, offset: 0, index: 1)
            enc.setBuffer(nextBuf, offset: 0, index: 2)
            enc.setBuffer(tintIn, offset: 0, index: 3)
            enc.setBuffer(tintOut, offset: 0, index: 4)
            enc.setBytes(&wDims, length: MemoryLayout<SIMD2<UInt32>>.size, index: 5)
            enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
            enc.endEncoding()

            let tmp = prevBuf
            prevBuf = currBuf
            currBuf = nextBuf
            nextBuf = tmp
            swap(&tintIn, &tintOut)
        }

        waterPrev = prevBuf
        waterCurr = currBuf
        waterNext = nextBuf
        waterTintA = tintIn
        waterTintB = tintOut

        command.commit()
        command.waitUntilCompleted()

        waterEnergy *= 0.965
        if waterEnergy < 0.002 { waterEnergy = 0 }
    }

    func render(
        style: MusicVisualStyle,
        frame: MusicSpectrumFrame,
        time: TimeInterval,
        colors: EffectColorParams,
        intensity: Double,
        reactivity: Double
    ) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }

        guard let queue = ctx.queue,
              let sdfBuf = ctx.sdfBuffer,
              let pixBuf = pixelBuffer,
              let command = queue.makeCommandBuffer(),
              let enc = command.makeComputeCommandEncoder()
        else { return nil }

        let rw = MusicMetalContext.renderWidth
        let rh = MusicMetalContext.renderHeight
        var rDims = SIMD2<UInt32>(UInt32(rw), UInt32(rh))
        var wDims = SIMD2<UInt32>(UInt32(MusicMetalContext.waterWidth), UInt32(MusicMetalContext.waterHeight))

        var uniforms = MusicMetalContext.MusicUniformsGPU(
            time: Float(time),
            subBass: frame.subBass,
            bass: frame.bass,
            mids: frame.mids,
            highs: frame.highs,
            energy: frame.energy,
            level: frame.level,
            beatPulse: frame.beatPulse,
            snarePulse: frame.snarePulse,
            hatPulse: frame.hatPulse,
            dominantPitch: frame.dominantPitch,
            stereoBalance: frame.stereoBalance,
            intensity: Float(intensity),
            reactivity: Float(reactivity),
            beatCount: UInt32(truncatingIfNeeded: frame.beatCount)
        )
        let colorVecs = [colors.palA, colors.palB, colors.palD]
        let bands = frame.bands.count == 32 ? frame.bands : Array(repeating: Float(0), count: 32)

        if style == .waterPool {
            guard let waterRenderPipe = ctx.waterRenderPipe,
                  let wCurr = waterCurr,
                  let tA = waterTintA
            else { return nil }
            enc.setComputePipelineState(waterRenderPipe)
            enc.setBuffer(pixBuf, offset: 0, index: 0)
            enc.setBuffer(sdfBuf, offset: 0, index: 1)
            enc.setBuffer(wCurr, offset: 0, index: 2)
            enc.setBuffer(tA, offset: 0, index: 3)
            enc.setBytes(&rDims, length: MemoryLayout<SIMD2<UInt32>>.size, index: 4)
            enc.setBytes(&wDims, length: MemoryLayout<SIMD2<UInt32>>.size, index: 5)
            enc.setBytes(&uniforms, length: MemoryLayout<MusicMetalContext.MusicUniformsGPU>.stride, index: 6)
            enc.setBytes(bands, length: 32 * MemoryLayout<Float>.stride, index: 7)
            enc.setBytes(colorVecs, length: colorVecs.count * MemoryLayout<SIMD4<Float>>.stride, index: 8)
        } else {
            guard let pipe = ctx.visualPipes[style] else { return nil }
            enc.setComputePipelineState(pipe)
            enc.setBuffer(pixBuf, offset: 0, index: 0)
            enc.setBuffer(sdfBuf, offset: 0, index: 1)
            enc.setBytes(&rDims, length: MemoryLayout<SIMD2<UInt32>>.size, index: 2)
            enc.setBytes(&uniforms, length: MemoryLayout<MusicMetalContext.MusicUniformsGPU>.stride, index: 3)
            enc.setBytes(bands, length: 32 * MemoryLayout<Float>.stride, index: 4)
            enc.setBytes(colorVecs, length: colorVecs.count * MemoryLayout<SIMD4<Float>>.stride, index: 5)
        }

        enc.dispatchThreads(MTLSize(width: rw, height: rh, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }

        let byteCount = rw * rh * 4
        let data = Data(bytes: pixBuf.contents(), count: byteCount)
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

private extension MusicMetalContext {
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct WaterImpulse {
        float2 normPos;
        float radius;
        float strength;
        float huePhase;
        float pad0;
        float pad1;
        float pad2;
    };

    struct MusicUniforms {
        float time;
        float subBass;
        float bass;
        float mids;
        float highs;
        float energy;
        float level;
        float beatPulse;
        float snarePulse;
        float hatPulse;
        float dominantPitch;
        float stereoBalance;
        float intensity;
        float reactivity;
        uint beatCount;
        uint pad;
    };

    float roundedBoxSDF(float2 p, float2 b, float r) {
        float2 q = abs(p) - b + r;
        return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
    }

    kernel void musicBakeSDF(device float4 *sdfOut [[buffer(0)]],
                             constant uint2 &dims [[buffer(1)]],
                             constant float4 *keys [[buffer(2)]],
                             constant uint &keyCount [[buffer(3)]],
                             uint2 id [[thread_position_in_grid]]) {
        if (id.x >= dims.x || id.y >= dims.y) return;
        float2 pos = float2((float(id.x) + 0.5) * (1920.0 / float(dims.x)),
                            (float(dims.y - 1 - id.y) + 0.5) * (720.0 / float(dims.y)));
        float minD = 1e5;
        float secondD = 1e5;
        for (uint i = 0; i < keyCount; i++) {
            float4 k = keys[i];
            float d = roundedBoxSDF(pos - k.xy, k.zw, 12.0);
            if (d < minD) {
                secondD = minD;
                minD = d;
            } else if (d < secondD) {
                secondD = d;
            }
        }
        float eps = 2.0;
        float dx = 1e5, dy = 1e5;
        for (uint i = 0; i < keyCount; i++) {
            float4 k = keys[i];
            dx = min(dx, roundedBoxSDF(pos + float2(eps, 0.0) - k.xy, k.zw, 12.0));
            dy = min(dy, roundedBoxSDF(pos + float2(0.0, eps) - k.xy, k.zw, 12.0));
        }
        float2 grad = normalize(float2(dx - minD, dy - minD) + 1e-6);
        sdfOut[id.y * dims.x + id.x] = float4(minD, grad.x, grad.y, secondD - minD);
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

    float sampleBand(constant float *bands, float u) {
        float idx = clamp(u, 0.0, 1.0) * 31.0;
        int i0 = int(floor(idx));
        int i1 = min(31, i0 + 1);
        return mix(bands[i0], bands[i1], idx - float(i0));
    }

    uchar4 finishPixel(float3 rgb, float alpha, float3 palA, float3 palB, float3 palD,
                       float hueShift, float chroma, float intensity, float colorIntensity) {
        float3 graded = gradeColor(rgb, hueShift, chroma) * intensity * colorIntensity;
        float outA = saturate(alpha * min(1.35, 0.35 + 0.65 * colorIntensity) * saturate(intensity * 1.15));
        graded = clamp(graded, 0.0, outA);
        return uchar4(float4(graded, outA) * 255.0 + 0.5);
    }

    // MARK: - 1. Realistic Shallow-Water Pool Simulation

    kernel void waterImpulse(device float *curr [[buffer(0)]],
                             device float4 *tint [[buffer(1)]],
                             constant uint2 &wDims [[buffer(2)]],
                             constant WaterImpulse *impulses [[buffer(3)]],
                             constant uint &count [[buffer(4)]],
                             uint2 id [[thread_position_in_grid]]) {
        if (id.x >= wDims.x || id.y >= wDims.y) return;
        float2 gPos = float2(float(id.x) + 0.5, float(id.y) + 0.5);
        uint idx = id.y * wDims.x + id.x;
        float h = curr[idx];
        float4 dye = tint[idx];

        for (uint i = 0; i < count; i++) {
            WaterImpulse imp = impulses[i];
            float2 center = imp.normPos * float2(float(wDims.x), float(wDims.y));
            float2 diff = gPos - center;
            float r = max(1.5, imp.radius);
            float d2 = dot(diff, diff) / (r * r);
            if (d2 < 5.5) {
                float drop = imp.strength * exp(-d2);
                h += drop;
                float ringGlow = abs(drop) * 0.65;
                dye.rgb += float3(
                    0.5 + 0.5 * cos(6.28318 * (imp.huePhase + 0.00)),
                    0.5 + 0.5 * cos(6.28318 * (imp.huePhase + 0.33)),
                    0.5 + 0.5 * cos(6.28318 * (imp.huePhase + 0.67))
                ) * ringGlow;
                dye.w = min(2.0, dye.w + ringGlow);
            }
        }
        curr[idx] = clamp(h, -3.2, 3.2);
        tint[idx] = clamp(dye, 0.0, 2.0);
    }

    kernel void waterStep(device const float *prev [[buffer(0)]],
                          device const float *curr [[buffer(1)]],
                          device float *next [[buffer(2)]],
                          device const float4 *tintIn [[buffer(3)]],
                          device float4 *tintOut [[buffer(4)]],
                          constant uint2 &wDims [[buffer(5)]],
                          uint2 id [[thread_position_in_grid]]) {
        if (id.x >= wDims.x || id.y >= wDims.y) return;
        uint w = wDims.x;
        uint h = wDims.y;
        uint x = id.x;
        uint y = id.y;
        uint xm = (x > 0) ? x - 1 : 1;
        uint xp = (x + 1 < w) ? x + 1 : w - 2;
        uint ym = (y > 0) ? y - 1 : 1;
        uint yp = (y + 1 < h) ? y + 1 : h - 2;

        float c = curr[y * w + x];
        // 9-point isotropic Laplacian for circular artifact-free waves
        float card = curr[y * w + xm] + curr[y * w + xp] + curr[ym * w + x] + curr[yp * w + x];
        float diag = curr[ym * w + xm] + curr[ym * w + xp] + curr[yp * w + xm] + curr[yp * w + xp];
        float laplacian = card * 0.20 + diag * 0.05 - c;

        float c2 = 0.88;
        float damping = 0.985;
        bool onBoundary = (x == 0 || x == w - 1 || y == 0 || y == h - 1);
        float edgeLoss = onBoundary ? 0.92 : 1.0;

        float val = (2.0 * c - prev[y * w + x] + c2 * laplacian) * damping * edgeLoss;
        next[y * w + x] = clamp(val, -3.2, 3.2);

        float4 avgTint = (tintIn[y * w + x] * 4.0 + tintIn[y * w + xm] + tintIn[y * w + xp]
                        + tintIn[ym * w + x] + tintIn[yp * w + x]) / 8.0;
        tintOut[y * w + x] = avgTint * 0.986;
    }

    float sampleHeightBilinear(device const float *grid, uint2 wDims, float2 uv) {
        float2 p = clamp(uv, float2(0.0), float2(0.9999)) * float2(float(wDims.x - 1), float(wDims.y - 1));
        uint2 i0 = uint2(floor(p));
        uint2 i1 = min(i0 + 1, wDims - 1);
        float2 f = p - float2(i0);
        float a = grid[i0.y * wDims.x + i0.x];
        float b = grid[i0.y * wDims.x + i1.x];
        float c = grid[i1.y * wDims.x + i0.x];
        float d = grid[i1.y * wDims.x + i1.x];
        return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    }

    float4 sampleTintBilinear(device const float4 *grid, uint2 wDims, float2 uv) {
        float2 p = clamp(uv, float2(0.0), float2(0.9999)) * float2(float(wDims.x - 1), float(wDims.y - 1));
        uint2 i0 = uint2(floor(p));
        uint2 i1 = min(i0 + 1, wDims - 1);
        float2 f = p - float2(i0);
        float4 a = grid[i0.y * wDims.x + i0.x];
        float4 b = grid[i0.y * wDims.x + i1.x];
        float4 c = grid[i1.y * wDims.x + i0.x];
        float4 d = grid[i1.y * wDims.x + i1.x];
        return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    }

    kernel void waterRender(device uchar4 *pixels [[buffer(0)]],
                            constant float4 *sdfGrid [[buffer(1)]],
                            device const float *waterCurr [[buffer(2)]],
                            device const float4 *waterTint [[buffer(3)]],
                            constant uint2 &rDims [[buffer(4)]],
                            constant uint2 &wDims [[buffer(5)]],
                            constant MusicUniforms &u [[buffer(6)]],
                            constant float *bands [[buffer(7)]],
                            constant float4 *colorParams [[buffer(8)]],
                            uint2 id [[thread_position_in_grid]]) {
        if (id.x >= rDims.x || id.y >= rDims.y) return;
        uint idx = id.y * rDims.x + id.x;

        float2 uv = float2((float(id.x) + 0.5) / float(rDims.x),
                           1.0 - (float(id.y) + 0.5) / float(rDims.y));
        float2 texel = 1.0 / float2(float(wDims.x), float(wDims.y));

        float hC = sampleHeightBilinear(waterCurr, wDims, uv);
        float hL = sampleHeightBilinear(waterCurr, wDims, uv - float2(texel.x, 0.0));
        float hR = sampleHeightBilinear(waterCurr, wDims, uv + float2(texel.x, 0.0));
        float hU = sampleHeightBilinear(waterCurr, wDims, uv - float2(0.0, texel.y));
        float hD = sampleHeightBilinear(waterCurr, wDims, uv + float2(0.0, texel.y));

        float2 grad = float2(hR - hL, hD - hU) * 0.5;
        float curvature = max(0.0, -(hL + hR + hU + hD - 4.0 * hC));
        float slope = length(grad);
        float waveEnergy = saturate(abs(hC) * 0.75 + slope * 1.9 + curvature * 1.15);

        // Refracted 3D water normal
        float3 N = normalize(float3(-grad.x * 3.1, -grad.y * 3.1, 1.0));
        float3 V = float3(0.0, 0.0, 1.0);
        float fresnel = 0.04 + 0.96 * pow(1.0 - saturate(dot(N, V)), 3.6);

        // Refract UV onto submerged keycap floor
        float2 refrUV = clamp(uv + N.xy * 0.045, float2(0.0), float2(0.999));
        uint refX = min(rDims.x - 1, uint(refrUV.x * float(rDims.x)));
        uint refY = min(rDims.y - 1, uint((1.0 - refrUV.y) * float(rDims.y)));
        float4 sdfRef = sdfGrid[refY * rDims.x + refX];
        float keyEdge = exp(-0.085 * sdfRef.x * sdfRef.x);
        float channelGlow = smoothstep(20.0, 1.0, sdfRef.w) * smoothstep(-3.0, 6.0, sdfRef.x);

        float3 palA = colorParams[0].xyz;
        float3 palB = colorParams[1].xyz;
        float3 palD = colorParams[2].xyz;

        // Animated underwater caustic interference + physical wave convergence
        float2 causticUV = refrUV * float2(11.0, 4.2) + N.xy * 1.6;
        float c1 = sin(causticUV.x * 2.1 + u.time * 1.4 + sin(causticUV.y * 1.9 - u.time * 1.1));
        float c2 = cos(causticUV.y * 2.7 - u.time * 1.2 + cos(causticUV.x * 1.7 + u.time * 0.9));
        float web = pow(saturate(1.0 - abs(c1 + c2) * 0.55), 3.2);
        float physicalCaustic = saturate(curvature * 1.85 + slope * 0.9);
        float caustic = web * (0.14 + 0.55 * u.energy + 0.85 * waveEnergy) + physicalCaustic * 0.95;

        float4 dye = sampleTintBilinear(waterTint, wDims, uv);
        float bandAtX = sampleBand(bands, uv.x);
        float hueT = uv.x * 0.35 + hC * 0.25 + u.time * 0.04 + u.dominantPitch * 0.2;
        float3 deepCol = foilPalette(hueT, palA, palB, palD);
        float3 crestCol = foilPalette(hueT + 0.28, palA, palB, palD);
        float3 floorCol = deepCol * (0.16 + 0.34 * u.energy + 0.28 * bandAtX)
                        + deepCol * keyEdge * (0.15 + 0.55 * waveEnergy + 0.25 * u.beatPulse)
                        + crestCol * channelGlow * (0.08 + 0.35 * waveEnergy);

        // Specular sunlight / studio highlights on ripples
        float3 L1 = normalize(float3(0.38, -0.52, 0.76));
        float3 L2 = normalize(float3(-0.48, 0.32, 0.82));
        float3 H1 = normalize(L1 + V);
        float3 H2 = normalize(L2 + V);
        float spec1 = pow(saturate(dot(N, H1)), 54.0) * (0.25 + 1.45 * slope);
        float spec2 = pow(saturate(dot(N, H2)), 38.0) * (0.18 + 1.10 * slope);

        // Chromatic dispersion on steep wave slopes
        float3 dispCol = float3(
            foilPalette(hueT - 0.09, palA, palB, palD).r,
            foilPalette(hueT, palA, palB, palD).g,
            foilPalette(hueT + 0.09, palA, palB, palD).b
        );

        float3 waterBody = floorCol
                         + crestCol * caustic * 0.72
                         + dye.rgb * (0.28 * waveEnergy + 0.14)
                         + dispCol * fresnel * (0.45 + 0.75 * waveEnergy)
                         + mix(crestCol, float3(0.95, 0.99, 1.0), 0.72) * (spec1 + spec2);

        float activeFloor = max(waveEnergy, max(u.energy * 0.38, u.beatPulse * 0.42));
        float alpha = saturate(0.28 * activeFloor + waveEnergy * 0.88 + caustic * 0.35 + (spec1 + spec2) * 0.8);
        pixels[idx] = finishPixel(waterBody, alpha, palA, palB, palD,
                                  colorParams[0].w, colorParams[1].w, u.intensity, colorParams[2].w);
    }

    // MARK: - 2. Aurora Ribbons

    kernel void musicAurora(device uchar4 *pixels [[buffer(0)]],
                            constant float4 *sdfGrid [[buffer(1)]],
                            constant uint2 &dims [[buffer(2)]],
                            constant MusicUniforms &u [[buffer(3)]],
                            constant float *bands [[buffer(4)]],
                            constant float4 *colorParams [[buffer(5)]],
                            uint2 id [[thread_position_in_grid]]) {
        if (id.x >= dims.x || id.y >= dims.y) return;
        uint idx = id.y * dims.x + id.x;
        float2 uv = float2((float(id.x) + 0.5) / float(dims.x), 1.0 - (float(id.y) + 0.5) / float(dims.y));
        float4 sdf = sdfGrid[idx];
        float3 palA = colorParams[0].xyz, palB = colorParams[1].xyz, palD = colorParams[2].xyz;

        float3 col = float3(0.0);
        float totalA = 0.0;
        float bandVal = sampleBand(bands, uv.x);

        for (int layer = 0; layer < 4; layer++) {
            float fl = float(layer);
            float speed = 0.28 + fl * 0.14;
            float wave = sin(uv.x * (5.5 + fl * 2.1) + u.time * speed + fl * 1.7) * 0.12
                       + (fbm(float2(uv.x * 3.8 + u.time * 0.22, fl * 2.3)) - 0.5) * 0.28;
            float yCenter = 0.28 + fl * 0.14 + wave - bandVal * (0.16 + 0.10 * u.beatPulse);
            float dy = uv.y - yCenter;
            float curtain = exp(-pow(dy / (0.11 + 0.07 * bandVal), 2.0));
            // Vertical magnetic ray striations
            float rays = 0.55 + 0.45 * sin(uv.x * 78.0 + fbm(float2(uv.x * 12.0, u.time * 0.8 + fl)) * 7.0);
            float brightness = curtain * rays * (0.28 + 0.85 * bandVal + 0.35 * u.energy);
            float3 ribbonCol = foilPalette(uv.x * 0.55 + fl * 0.22 + u.time * 0.05, palA, palB, palD);
            col += ribbonCol * brightness;
            totalA = max(totalA, saturate(brightness));
        }

        // High-frequency twinkling stars above the aurora
        float2 starCell = floor(uv * float2(96.0, 36.0));
        float starRand = hash21(starCell);
        if (starRand > 0.972) {
            float2 f = fract(uv * float2(96.0, 36.0)) - 0.5;
            float twinkle = 0.4 + 0.6 * sin(u.time * 9.0 + starRand * 120.0);
            float star = exp(-dot(f, f) * 42.0) * (0.25 + 0.9 * u.highs + 0.5 * u.hatPulse) * twinkle;
            col += float3(0.85, 0.95, 1.0) * star;
            totalA = max(totalA, star);
        }

        float keyRim = exp(-0.18 * sdf.x * sdf.x) * (0.12 + 0.45 * u.beatPulse);
        col += col * keyRim;
        pixels[idx] = finishPixel(col, totalA, palA, palB, palD,
                                  colorParams[0].w, colorParams[1].w, u.intensity, colorParams[2].w);
    }

    // MARK: - 3. Ferrofluid Spikes

    kernel void musicFerrofluid(device uchar4 *pixels [[buffer(0)]],
                                constant float4 *sdfGrid [[buffer(1)]],
                                constant uint2 &dims [[buffer(2)]],
                                constant MusicUniforms &u [[buffer(3)]],
                                constant float *bands [[buffer(4)]],
                                constant float4 *colorParams [[buffer(5)]],
                                uint2 id [[thread_position_in_grid]]) {
        if (id.x >= dims.x || id.y >= dims.y) return;
        uint idx = id.y * dims.x + id.x;
        float2 uv = float2((float(id.x) + 0.5) / float(dims.x), 1.0 - (float(id.y) + 0.5) / float(dims.y));
        float3 palA = colorParams[0].xyz, palB = colorParams[1].xyz, palD = colorParams[2].xyz;

        float2 p = (uv - 0.5) * float2(2.6667, 1.0);
        float r = length(p);
        float a = atan2(p.y, p.x);

        float bandPolar = sampleBand(bands, abs(a) / M_PI_F);
        float spikeFreq = 10.0 + floor(u.dominantPitch * 12.0) * 2.0;
        float spikes = pow(abs(cos(a * spikeFreq + u.time * 1.3)), 2.2) * (0.12 + 0.34 * u.bass + 0.25 * u.beatPulse);
        float microSpikes = pow(abs(sin(r * 28.0 - u.time * 5.0 + a * 6.0)), 3.0) * (0.04 + 0.16 * u.highs);
        float dome = exp(-r * r * (2.6 - 1.1 * u.subBass)) * (0.65 + 0.55 * u.energy);

        float height = dome + spikes * exp(-r * 1.4) + microSpikes * exp(-r * 1.8) + bandPolar * 0.24 * exp(-abs(r - 0.42) * 5.0);
        float2 eps = float2(0.015, 0.0);
        float hx = exp(-dot(p + eps.xy, p + eps.xy) * 2.4) + 0.2 * sin((p.x + eps.x) * 18.0 + u.time * 3.0) * u.mids;
        float hy = exp(-dot(p + eps.yx, p + eps.yx) * 2.4) + 0.2 * cos((p.y + eps.x) * 18.0 - u.time * 2.6) * u.mids;
        float3 N = normalize(float3((height - hx) * 4.5, (height - hy) * 4.5, 1.0));

        float fresnel = pow(1.0 - saturate(N.z), 2.4);
        float3 L1 = normalize(float3(0.45, -0.55, 0.7));
        float3 L2 = normalize(float3(-0.6, 0.35, 0.72));
        float spec1 = pow(saturate(dot(N, normalize(L1 + float3(0, 0, 1)))), 48.0);
        float spec2 = pow(saturate(dot(N, normalize(L2 + float3(0, 0, 1)))), 32.0);

        float3 irid = foilPalette(fresnel * 1.2 + height * 0.6 + u.time * 0.08, palA, palB, palD);
        float3 metal = irid * (0.20 + 0.75 * fresnel + 0.35 * height) + float3(0.95, 0.98, 1.0) * (spec1 + spec2 * 0.75);
        float alpha = saturate(smoothstep(0.06, 0.32, height) * (0.45 + 0.55 * u.energy + 0.35 * u.beatPulse) + spec1);
        pixels[idx] = finishPixel(metal, alpha, palA, palB, palD,
                                  colorParams[0].w, colorParams[1].w, u.intensity, colorParams[2].w);
    }

    // MARK: - 4. Plasma Nebula

    kernel void musicPlasmaNebula(device uchar4 *pixels [[buffer(0)]],
                                  constant float4 *sdfGrid [[buffer(1)]],
                                  constant uint2 &dims [[buffer(2)]],
                                  constant MusicUniforms &u [[buffer(3)]],
                                  constant float *bands [[buffer(4)]],
                                  constant float4 *colorParams [[buffer(5)]],
                                  uint2 id [[thread_position_in_grid]]) {
        if (id.x >= dims.x || id.y >= dims.y) return;
        uint idx = id.y * dims.x + id.x;
        float2 uv = float2((float(id.x) + 0.5) / float(dims.x), 1.0 - (float(id.y) + 0.5) / float(dims.y));
        float3 palA = colorParams[0].xyz, palB = colorParams[1].xyz, palD = colorParams[2].xyz;

        float2 p = (uv - 0.5) * float2(3.6, 1.35);
        float t = u.time * (0.35 + 0.35 * u.energy);
        float2 q = float2(fbm(p + float2(t * 0.4, -t * 0.3)),
                          fbm(p + float2(-t * 0.35, t * 0.5) + 5.2));
        float n = fbm(p + q * (1.8 + 1.2 * u.mids));

        float r = length(uv - 0.5);
        float shock = exp(-42.0 * pow(r - fract(u.time * 0.85) * 0.75, 2.0)) * u.beatPulse;
        float bandVal = sampleBand(bands, uv.x);

        float lum = pow(n, 1.4) * (0.45 + 0.95 * u.energy + 0.45 * bandVal) + shock * 0.75;
        float3 col = foilPalette(n * 1.4 + q.x * 0.6 + u.dominantPitch * 0.4, palA, palB, palD) * lum;
        col += float3(0.95, 0.97, 1.0) * shock * 0.55;

        // Treble sparkle dust
        float spark = pow(hash21(floor(uv * float2(140.0, 54.0)) + floor(u.time * 12.0)), 18.0) * (u.highs + u.hatPulse);
        col += float3(1.0) * spark * 0.85;

        float alpha = saturate(lum * 0.95 + spark);
        pixels[idx] = finishPixel(col, alpha, palA, palB, palD,
                                  colorParams[0].w, colorParams[1].w, u.intensity, colorParams[2].w);
    }

    // MARK: - 5. Cymatics (Chladni Standing Waves)

    kernel void musicCymatics(device uchar4 *pixels [[buffer(0)]],
                              constant float4 *sdfGrid [[buffer(1)]],
                              constant uint2 &dims [[buffer(2)]],
                              constant MusicUniforms &u [[buffer(3)]],
                              constant float *bands [[buffer(4)]],
                              constant float4 *colorParams [[buffer(5)]],
                              uint2 id [[thread_position_in_grid]]) {
        if (id.x >= dims.x || id.y >= dims.y) return;
        uint idx = id.y * dims.x + id.x;
        float2 uv = float2((float(id.x) + 0.5) / float(dims.x), 1.0 - (float(id.y) + 0.5) / float(dims.y));
        float4 sdf = sdfGrid[idx];
        float3 palA = colorParams[0].xyz, palB = colorParams[1].xyz, palD = colorParams[2].xyz;

        float2 p = (uv - 0.5) * float2(2.6667, 1.0);
        float n1 = 2.0 + floor(u.dominantPitch * 5.0);
        float m1 = 3.0 + floor(u.mids * 5.0);
        float n2 = n1 + 2.0;
        float m2 = max(1.0, m1 - 1.0);

        float ch1 = cos(n1 * M_PI_F * p.x) * cos(m1 * M_PI_F * p.y) - cos(m1 * M_PI_F * p.x) * cos(n1 * M_PI_F * p.y);
        float ch2 = cos(n2 * M_PI_F * p.x) * cos(m2 * M_PI_F * p.y) - cos(m2 * M_PI_F * p.x) * cos(n2 * M_PI_F * p.y);
        float blend = 0.5 + 0.5 * sin(u.time * 0.7 + u.beatPulse * 1.8);
        float nodal = mix(ch1, ch2, blend);

        float line = exp(-abs(nodal) * (9.5 - 3.5 * u.beatPulse)) * (0.45 + 0.85 * u.energy);
        float r = length(p);
        float ring = exp(-16.0 * pow(abs(sin(r * (8.0 + 4.0 * u.bass) - u.time * 3.2)), 2.0)) * (0.25 + 0.6 * u.beatPulse);
        float sdfRim = exp(-0.14 * sdf.x * sdf.x) * 0.35;

        float field = line + ring * 0.55 + line * sdfRim;
        float3 col = foilPalette(abs(nodal) * 0.5 + r * 0.35 + u.time * 0.06, palA, palB, palD) * field;
        col += float3(0.95, 0.98, 1.0) * pow(line, 2.2) * 0.45;
        float alpha = saturate(field);
        pixels[idx] = finishPixel(col, alpha, palA, palB, palD,
                                  colorParams[0].w, colorParams[1].w, u.intensity, colorParams[2].w);
    }

    // MARK: - 6. Radial Pulse

    kernel void musicRadialPulse(device uchar4 *pixels [[buffer(0)]],
                                 constant float4 *sdfGrid [[buffer(1)]],
                                 constant uint2 &dims [[buffer(2)]],
                                 constant MusicUniforms &u [[buffer(3)]],
                                 constant float *bands [[buffer(4)]],
                                 constant float4 *colorParams [[buffer(5)]],
                                 uint2 id [[thread_position_in_grid]]) {
        if (id.x >= dims.x || id.y >= dims.y) return;
        uint idx = id.y * dims.x + id.x;
        float2 uv = float2((float(id.x) + 0.5) / float(dims.x), 1.0 - (float(id.y) + 0.5) / float(dims.y));
        float3 palA = colorParams[0].xyz, palB = colorParams[1].xyz, palD = colorParams[2].xyz;

        float2 p = (uv - 0.5) * float2(2.6667, 1.0);
        float r = length(p);
        float a = atan2(p.y, p.x);
        float normA = abs(a) / M_PI_F;
        float bandVal = sampleBand(bands, normA);

        float baseR = 0.20 + 0.08 * u.beatPulse;
        float targetR = baseR + bandVal * (0.34 + 0.16 * u.bass);
        float spectrumGlow = exp(-pow((r - targetR) * 18.0, 2.0)) * (0.55 + 0.75 * bandVal);
        float coreFill = smoothstep(targetR + 0.02, targetR - 0.06, r) * (0.14 + 0.38 * u.energy);

        // Outward beat shockwave rings
        float waveR = fract(u.time * 0.75) * 1.45;
        float shockRing = exp(-pow((r - waveR) * 22.0, 2.0)) * (u.beatPulse * 0.9 + 0.15) * (1.0 - waveR / 1.5);
        float spoke = pow(abs(cos(a * 16.0)), 14.0) * smoothstep(baseR, targetR, r) * bandVal * 0.65;

        float lum = spectrumGlow + coreFill + shockRing + spoke;
        float3 col = foilPalette(normA * 0.7 + r * 0.4 - u.time * 0.08, palA, palB, palD) * lum;
        col += float3(0.95, 0.98, 1.0) * (spectrumGlow * 0.35 + shockRing * 0.45);
        pixels[idx] = finishPixel(col, saturate(lum), palA, palB, palD,
                                  colorParams[0].w, colorParams[1].w, u.intensity, colorParams[2].w);
    }

    // MARK: - 7. Audio Fire

    kernel void musicAudioFire(device uchar4 *pixels [[buffer(0)]],
                               constant float4 *sdfGrid [[buffer(1)]],
                               constant uint2 &dims [[buffer(2)]],
                               constant MusicUniforms &u [[buffer(3)]],
                               constant float *bands [[buffer(4)]],
                               constant float4 *colorParams [[buffer(5)]],
                               uint2 id [[thread_position_in_grid]]) {
        if (id.x >= dims.x || id.y >= dims.y) return;
        uint idx = id.y * dims.x + id.x;
        float2 uv = float2((float(id.x) + 0.5) / float(dims.x), 1.0 - (float(id.y) + 0.5) / float(dims.y));
        float4 sdf = sdfGrid[idx];
        float3 palA = colorParams[0].xyz, palB = colorParams[1].xyz, palD = colorParams[2].xyz;

        // Bottom of keyboard is uv.y = 1.0; fire rises upward toward uv.y = 0.0
        float hFromBottom = 1.0 - uv.y;
        float bandVal = sampleBand(bands, uv.x);
        float flameReach = 0.24 + bandVal * 0.62 + u.beatPulse * 0.24;

        float2 flow = float2(uv.x * 11.0, hFromBottom * 5.2 + u.time * (2.6 + 2.4 * u.energy));
        float turb = fbm(flow + float2(fbm(flow * 0.6) * 1.4, 0.0));
        float fuel = (flameReach - hFromBottom) / max(0.18, flameReach) + (turb - 0.46) * 0.78;
        float body = smoothstep(0.02, 0.55, fuel) * smoothstep(0.0, 0.06, hFromBottom + 0.03);
        float hot = smoothstep(0.45, 0.98, fuel);
        float plasmaCore = smoothstep(0.76, 1.08, fuel) * saturate(u.bass * 0.9 + u.beatPulse * 0.8);

        float3 fireCol = mix(float3(0.86, 0.12, 0.16), float3(1.0, 0.48, 0.06), smoothstep(0.05, 0.48, fuel));
        fireCol = mix(fireCol, float3(1.0, 0.90, 0.36), hot);
        fireCol = mix(fireCol, float3(0.32, 0.84, 1.0), plasmaCore * 0.75);
        fireCol = mix(fireCol, foilPalette(uv.x * 0.6 + hFromBottom * 0.4, palA, palB, palD), 0.22);

        float sdfWrap = 1.0 + 0.22 * exp(-0.08 * sdf.x * sdf.x);
        float alpha = saturate(body * sdfWrap);
        pixels[idx] = finishPixel(fireCol * alpha, alpha, palA, palB, palD,
                                  colorParams[0].w, colorParams[1].w, u.intensity, colorParams[2].w);
    }

    // MARK: - 8. Lava Lamp Metaballs

    kernel void musicLavaLamp(device uchar4 *pixels [[buffer(0)]],
                              constant float4 *sdfGrid [[buffer(1)]],
                              constant uint2 &dims [[buffer(2)]],
                              constant MusicUniforms &u [[buffer(3)]],
                              constant float *bands [[buffer(4)]],
                              constant float4 *colorParams [[buffer(5)]],
                              uint2 id [[thread_position_in_grid]]) {
        if (id.x >= dims.x || id.y >= dims.y) return;
        uint idx = id.y * dims.x + id.x;
        float2 uv = float2((float(id.x) + 0.5) / float(dims.x), 1.0 - (float(id.y) + 0.5) / float(dims.y));
        float3 palA = colorParams[0].xyz, palB = colorParams[1].xyz, palD = colorParams[2].xyz;

        float2 p = uv * float2(2.6667, 1.0);
        float field = 0.0;
        float2 grad = float2(0.0);
        float hueAccum = 0.0;

        for (int i = 0; i < 9; i++) {
            float fi = float(i);
            float b = bands[(i * 3) % 32];
            float cx = 0.25 + 2.16 * (0.5 + 0.46 * sin(u.time * (0.28 + fi * 0.05) + fi * 1.9));
            float cy = 0.5 + 0.36 * cos(u.time * (0.36 + fi * 0.06) + fi * 2.3) - b * 0.14;
            float2 d = p - float2(cx, cy);
            float r = 0.16 + 0.11 * b + 0.06 * u.beatPulse;
            float d2 = max(0.004, dot(d, d));
            float contrib = (r * r) / d2;
            field += contrib;
            grad += (-2.0 * contrib / d2) * d;
            hueAccum += contrib * (fi * 0.13 + b * 0.25);
        }

        float body = smoothstep(0.88, 1.32, field);
        float rim = smoothstep(0.72, 1.05, field) - smoothstep(1.05, 1.55, field);
        float3 N = normalize(float3(grad * 0.35, 1.0));
        float spec = pow(saturate(dot(N, normalize(float3(0.4, -0.5, 0.85)))), 36.0) * body;

        float3 blobCol = foilPalette(hueAccum / max(0.1, field) + u.time * 0.05, palA, palB, palD);
        float3 col = blobCol * (body * (0.45 + 0.65 * u.energy) + rim * 0.75) + float3(0.95, 0.98, 1.0) * spec * 0.7;
        float alpha = saturate(body * 0.92 + rim * 0.55);
        pixels[idx] = finishPixel(col, alpha, palA, palB, palD,
                                  colorParams[0].w, colorParams[1].w, u.intensity, colorParams[2].w);
    }
    """
}

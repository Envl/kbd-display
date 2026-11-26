import AppKit
import Metal

/// Real-time full-board Metal shader with multi-hit metaball merging and keycap SDF light wrapping.
final class LiveBoardShader {
    static let shared = LiveBoardShader()

    private static let gridWidth = 960
    private static let gridHeight = 360

    struct GPUHit {
        var start: SIMD2<Float>
        var end: SIMD2<Float>
        var current: SIMD2<Float>
        var control: SIMD2<Float>
        var keyCenter: SIMD2<Float>
        var keyHalfSize: SIMD2<Float>
        var progress: Float
        var alpha: Float
        var age: Float
        var heat: Float
        var radius: Float
        var seed: Float
        var isRepeat: UInt32
        var flags: UInt32
    }

    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let livePipeline: MTLComputePipelineState?
    private let sdfBuffer: MTLBuffer?
    private let pixelBuffer: MTLBuffer?
    private let lock = NSLock()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private init() {
        let width = Self.gridWidth
        let height = Self.gridHeight
        guard let dev = MTLCreateSystemDefaultDevice(),
              let cmdQueue = dev.makeCommandQueue(),
              let library = try? dev.makeLibrary(source: Self.shaderSource, options: nil),
              let bakeFn = library.makeFunction(name: "bakeKeySDF"),
              let liveFn = library.makeFunction(name: "liveBoard"),
              let bakePipe = try? dev.makeComputePipelineState(function: bakeFn),
              let livePipe = try? dev.makeComputePipelineState(function: liveFn),
              let sdfBuf = dev.makeBuffer(length: width * height * MemoryLayout<SIMD4<Float>>.stride,
                                          options: .storageModeShared),
              let pixBuf = dev.makeBuffer(length: width * height * 4, options: .storageModeShared)
        else {
            device = nil
            queue = nil
            livePipeline = nil
            sdfBuffer = nil
            pixelBuffer = nil
            return
        }
        device = dev
        queue = cmdQueue
        livePipeline = livePipe
        sdfBuffer = sdfBuf
        pixelBuffer = pixBuf

        // Precompute the Signed Distance Field (distance, normal.x, normal.y, inter-key ridge)
        // of all Action75 keycap rounded rectangles once on the GPU.
        let keyBoxes: [SIMD4<Float>] = Action75.rects.values.map { rect in
            let tile = rect.insetBy(dx: 5, dy: 5)
            return SIMD4<Float>(Float(tile.midX), Float(tile.midY), Float(tile.width * 0.5), Float(tile.height * 0.5))
        }
        if let command = cmdQueue.makeCommandBuffer(),
           let encoder = command.makeComputeCommandEncoder() {
            var dims = SIMD2<UInt32>(UInt32(width), UInt32(height))
            var count = UInt32(keyBoxes.count)
            encoder.setComputePipelineState(bakePipe)
            encoder.setBuffer(sdfBuf, offset: 0, index: 0)
            encoder.setBytes(&dims, length: MemoryLayout<SIMD2<UInt32>>.size, index: 1)
            encoder.setBytes(keyBoxes, length: keyBoxes.count * MemoryLayout<SIMD4<Float>>.stride, index: 2)
            encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 3)
            encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
        }
    }

    func draw(hits: [(beam: KeyBeam, age: TimeInterval)], in context: CGContext, settings: EffectConfiguration) {
        let active = hits.filter { $0.age >= 0 && $0.age < BlastEffect.duration }
        guard !active.isEmpty else { return }

        var gpuHits: [GPUHit] = []
        gpuHits.reserveCapacity(min(16, active.count))

        for (beam, age) in active.suffix(16) {
            let t = age / BlastEffect.duration
            let isRepeat = beam.length == 0
            let showFlame = settings.shows(.fire, for: beam)
            var flags: UInt32 = 0
            if !isRepeat && settings[.glow] { flags |= 1 }
            if settings[.border] { flags |= 2 }
            if showFlame { flags |= 4 }
            guard flags != 0 else { continue }
            if !beam.suppressesKeyFlash { flags |= 8 }

            let timing = BlastEffect.timing(at: t)
            let arc = BlastEffect.arcGeometry(for: beam, progress: CGFloat(timing.x))
            let tile = beam.keyFrame.insetBy(dx: 5, dy: 5)
            let radius = Float(min(330, 230 + beam.length * 0.08) * settings[.glowSize] * 0.5)
            let seed = Float((beam.sparks.first?.reach ?? 0.5) * 6.28318 + (beam.sparks.first?.lane ?? 0) * 3.1)
            let startFrac = Float(settings[.startingFraction])
            let effectiveHeat = showFlame
                ? Float(settings[.peakScale]) * (startFrac + (1 - startFrac) * Float(beam.flameHeat))
                : Float(beam.flameHeat)

            gpuHits.append(GPUHit(
                start: SIMD2(Float(beam.start.x), Float(beam.start.y)),
                end: SIMD2(Float(beam.end.x), Float(beam.end.y)),
                current: SIMD2(Float(arc.worldPoint.x), Float(arc.worldPoint.y)),
                control: SIMD2(Float(arc.worldControl.x), Float(arc.worldControl.y)),
                keyCenter: SIMD2(Float(tile.midX), Float(tile.midY)),
                keyHalfSize: SIMD2(Float(tile.width * 0.5), Float(tile.height * 0.5)),
                progress: timing.x,
                alpha: timing.y,
                age: Float(t),
                heat: effectiveHeat,
                radius: max(24, radius),
                seed: seed,
                isRepeat: isRepeat ? 1 : 0,
                flags: flags
            ))
        }

        if !gpuHits.isEmpty {
            if let cgImage = renderGPU(hits: gpuHits, borderBrightness: Float(settings[.borderBrightness]),
                                       colors: settings.colorParams) {
                context.saveGState()
                context.setBlendMode(.plusLighter)
                context.draw(cgImage, in: CGRect(origin: .zero, size: Action75.canvas))
                context.restoreGState()
            } else {
                // Fallback if Metal is unavailable
                var plasmaFallback = settings
                plasmaFallback.style = .plasma
                for (beam, age) in active {
                    BlastEffect.shared.draw(beam, age: age, settings: plasmaFallback)
                }
                return
            }
        }

        // Layer high-precision vector particles & single-key effects (Lightning / Ice / Water Wave / flame embers) on top.
        for (beam, age) in active {
            let t = age / BlastEffect.duration
            let isRepeat = beam.length == 0
            SingleKeyEffects.drawVectors(for: beam, in: context, time: t, settings: settings)
            if settings[.particles] && settings.shows(.fire, for: beam) {
                context.saveGState()
                context.setBlendMode(.plusLighter)
                context.translateBy(x: beam.keyFrame.midX, y: beam.keyFrame.midY - 5)
                let start = settings[.startingFraction]
                let scale = settings[.peakScale] * (start + (1 - start) * beam.flameHeat)
                context.scaleBy(x: scale, y: scale)
                context.setLineCap(.round)
                FlamePlume.drawParticles(in: context, sparks: beam.sparks, heat: beam.flameHeat,
                                         time: t, settings: settings, plasma: true)
                context.restoreGState()
            }
            if !isRepeat && settings[.particles] {
                let diameter = min(330, 230 + beam.length * 0.08) * settings[.glowSize]
                context.saveGState()
                context.translateBy(x: beam.start.x, y: beam.start.y)
                context.rotate(by: beam.heading)
                BlastEffect.drawPlasmaSparks(beam.sparks, in: context, beam: beam, height: diameter,
                                             time: t, size: settings[.particleSize], colors: settings.colorParams)
                context.restoreGState()
            }
        }
    }

    private func renderGPU(hits: [GPUHit], borderBrightness: Float, colors: EffectColorParams) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let queue, let livePipeline, let sdfBuffer, let pixelBuffer,
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder()
        else { return nil }

        let width = Self.gridWidth
        let height = Self.gridHeight
        var dims = SIMD2<UInt32>(UInt32(width), UInt32(height))
        var count = UInt32(hits.count)
        var brightness = borderBrightness
        let colorVecs = [colors.palA, colors.palB, colors.palD]

        encoder.setComputePipelineState(livePipeline)
        encoder.setBuffer(pixelBuffer, offset: 0, index: 0)
        encoder.setBuffer(sdfBuffer, offset: 0, index: 1)
        encoder.setBytes(&dims, length: MemoryLayout<SIMD2<UInt32>>.size, index: 2)
        encoder.setBytes(hits, length: hits.count * MemoryLayout<GPUHit>.stride, index: 3)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 4)
        encoder.setBytes(&brightness, length: MemoryLayout<Float>.size, index: 5)
        encoder.setBytes(colorVecs, length: colorVecs.count * MemoryLayout<SIMD4<Float>>.stride, index: 6)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }

        let byteCount = width * height * 4
        let data = Data(bytes: pixelBuffer.contents(), count: byteCount)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct GPUHit {
        float2 start;
        float2 end;
        float2 current;
        float2 control;
        float2 keyCenter;
        float2 keyHalfSize;
        float progress;
        float alpha;
        float age;
        float heat;
        float radius;
        float seed;
        uint isRepeat;
        uint flags;
    };

    float roundedBoxSDF(float2 p, float2 b, float r) {
        float2 q = abs(p) - b + r;
        return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
    }

    kernel void bakeKeySDF(device float4 *sdfOut [[buffer(0)]],
                           constant uint2 &dims [[buffer(1)]],
                           constant float4 *keys [[buffer(2)]],
                           constant uint &keyCount [[buffer(3)]],
                           uint2 id [[thread_position_in_grid]]) {
        if (id.x >= dims.x || id.y >= dims.y) return;
        // Map row id.y so CGContext.draw aligns row 0 with maxY (720) and row H-1 with minY (0).
        float2 pos = float2((float(id.x) + 0.5) * 2.0, float(dims.y - 1 - id.y) * 2.0 + 1.0);
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
        float eps = 1.5;
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
        return 0.55 * valueNoise(p) + 0.30 * valueNoise(p * 2.12 + 7.3) + 0.15 * valueNoise(p * 4.27 + 19.1);
    }

    float3 foilPalette(float t, float3 a, float3 b, float3 d) {
        return a + b * cos(2.0 * M_PI_F * (0.5 * t + d));
    }

    float3 chromaticPalette(float hue, float dispersion, float3 a, float3 b, float3 d) {
        float3 r = foilPalette(hue - dispersion, a, b, d);
        float3 g = foilPalette(hue, a, b, d);
        float3 bl = foilPalette(hue + dispersion, a, b, d);
        return float3(r.r, g.g, bl.b);
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

    // Distance and parameter t along the active portion [0, uMax] of a quadratic Bezier curve.
    float2 segmentCurve(float2 p, float2 a, float2 c, float2 b, float uMax) {
        float2 prev = a;
        float minDist = 1e5;
        float bestU = 0.0;
        const int steps = 8;
        for (int i = 1; i <= steps; i++) {
            float u = uMax * float(i) / float(steps);
            float iu = 1.0 - u;
            float2 cur = iu * iu * a + 2.0 * iu * u * c + u * u * b;
            float2 seg = cur - prev;
            float len2 = max(1e-4, dot(seg, seg));
            float h = saturate(dot(p - prev, seg) / len2);
            float d = length(p - (prev + seg * h));
            if (d < minDist) {
                minDist = d;
                bestU = uMax * (float(i - 1) + h) / float(steps);
            }
            prev = cur;
        }
        return float2(minDist, bestU);
    }

    kernel void liveBoard(device uchar4 *pixels [[buffer(0)]],
                          constant float4 *sdfGrid [[buffer(1)]],
                          constant uint2 &dims [[buffer(2)]],
                          constant GPUHit *hits [[buffer(3)]],
                          constant uint &hitCount [[buffer(4)]],
                          constant float &borderBrightness [[buffer(5)]],
                          constant float4 *colorParams [[buffer(6)]],
                          uint2 id [[thread_position_in_grid]]) {
        if (id.x >= dims.x || id.y >= dims.y) return;
        uint idx = id.y * dims.x + id.x;
        float2 pos = float2((float(id.x) + 0.5) * 2.0, float(dims.y - 1 - id.y) * 2.0 + 1.0);
        float4 sdf = sdfGrid[idx];
        float keyDist = sdf.x;
        float2 keyNormal = sdf.yz;
        float interKeyRidge = sdf.w;

        float3 palA = colorParams[0].xyz;
        float3 palB = colorParams[1].xyz;
        float3 palD = colorParams[2].xyz;
        float hueShift = colorParams[0].w;
        float chroma = colorParams[1].w;
        float intensity = colorParams[2].w;
        float auxHueShift = hueShift + (palD.x - 0.61018468);

        // Accumulators for multi-hit metaball liquid light, SDF rim lighting, and vortex flames.
        float metaballField = 0.0;
        float2 fieldGrad = float2(0.0);
        float weightedHue = 0.0;
        float weightSum = 0.0;
        float wakeGlow = 0.0;
        float3 wakeColorSum = float3(0.0);
        float3 borderRgb = float3(0.0);
        float borderAlpha = 0.0;
        float3 flameRgb = float3(0.0);
        float flameAlpha = 0.0;

        for (uint i = 0; i < hitCount; i++) {
            GPUHit hit = hits[i];
            float dTargetKey = roundedBoxSDF(pos - hit.keyCenter, hit.keyHalfSize, 12.0);
            float effKeyDist = min(keyDist, dTargetKey);

            // 1. Traveling Metaball Orb & Curved Plasma Wake (flag bit 0)
            if ((hit.flags & 1u) != 0u && hit.isRepeat == 0u) {
                float2 toOrb = pos - hit.current;
                float distOrb = length(toOrb);
                float R = hit.radius;

                if (distOrb < R * 1.85) {
                    float2 uvOrb = toOrb / R;
                    float rNorm = length(uvOrb);
                    float nWarp = fbm(uvOrb * 2.6 + float2(hit.age * 4.5, hit.seed));
                    float effR = max(0.001, rNorm + (nWarp - 0.5) * 0.16 * saturate(rNorm));

                    // Smooth metaball potential that merges neighboring simultaneous hits
                    float pot = saturate(1.0 - effR) * saturate(1.0 - effR * 0.65);
                    pot = pot * pot * (3.0 - 2.0 * pot);
                    float focus = 4.0 * hit.progress * (1.0 - hit.progress);
                    float opacity = hit.alpha * mix(0.38, 1.0, focus);
                    float contrib = pot * opacity;

                    // Arrival shockwave ring inside the metaball field
                    float shockPhase = saturate((hit.age - 0.35) / 0.55);
                    float shockRing = exp(-48.0 * pow(rNorm - (0.28 + 0.68 * shockPhase), 2.0))
                                    * smoothstep(0.32, 0.48, hit.age) * (1.0 - shockPhase);
                    contrib += shockRing * 0.55 * hit.alpha;

                    if (contrib > 1e-4) {
                        metaballField += contrib;
                        float2 dir = toOrb / max(1.0, distOrb);
                        fieldGrad += dir * (-2.2 * contrib / R);
                        float hue = hit.progress * 0.92 + (toOrb.x / R) * 0.38 + (toOrb.y / R) * 0.16
                                  + nWarp * 0.24 + sin(distOrb * 0.08 - hit.age * 16.0) * 0.06;
                        weightedHue += hue * contrib;
                        weightSum += contrib;
                    }
                }

                // Curved plasma comet wake along the quadratic Bezier path
                float2 bboxMin = min(min(hit.start, hit.current), hit.control) - float2(R * 0.7);
                float2 bboxMax = max(max(hit.start, hit.current), hit.control) + float2(R * 0.7);
                if (pos.x >= bboxMin.x && pos.x <= bboxMax.x && pos.y >= bboxMin.y && pos.y <= bboxMax.y && hit.progress > 0.02) {
                    float2 curve = segmentCurve(pos, hit.start, hit.control, hit.end, hit.progress);
                    float dCurve = curve.x;
                    float uAlong = curve.y / max(0.01, hit.progress);
                    float wakeHalfW = R * (0.06 + 0.24 * pow(uAlong, 1.35));
                    if (dCurve < wakeHalfW * 1.6) {
                        float turb = fbm(pos * 0.028 - float2(hit.age * 9.0, hit.seed));
                        float ribbon = saturate(1.0 - (dCurve + (turb - 0.5) * 14.0) / wakeHalfW);
                        ribbon = ribbon * ribbon;
                        float fade = saturate((0.88 - hit.age) / 0.52) * uAlong;
                        float wAlpha = 0.56 * ribbon * fade * hit.alpha;
                        float3 wCol = chromaticPalette(uAlong * 0.85 + turb * 0.3 + hit.age * 0.4, 0.09 * chroma, palA, palB, palD);
                        wCol = mix(wCol, float3(0.92, 0.98, 1.0), pow(ribbon, 3.0) * 0.65);
                        wCol = gradeColor(wCol, hueShift, chroma);
                        wakeGlow += wAlpha;
                        wakeColorSum += wCol * wAlpha;
                    }
                }
            }

            // 2. Keycap SDF Specular Rim-Lighting, Destination Flash & Neighbor Spill (flag bit 1)
            if ((hit.flags & 2u) != 0u) {
                if ((hit.flags & 8u) != 0u && hit.age < 0.66) {
                    float contact = pow(max(0.0, 1.0 - hit.age / 0.35), 2.0);
                    float arrival = 0.75 * pow(max(0.0, 1.0 - abs(hit.age - 0.33) / 0.24), 2.0);
                    float light = smoothstep(0.0f, \(BlastEffect.outlineFadeIn)f, hit.age) * max(contact, arrival) * borderBrightness;
                    if (abs(dTargetKey) < 15.0 && light > 0.005) {
                        float rim = exp(-0.42 * dTargetKey * dTargetKey);
                        float halo = 0.48 * exp(-0.045 * dTargetKey * dTargetKey) * step(-5.5, dTargetKey);
                        float shock = 0.52 * exp(-0.18 * pow(dTargetKey - 18.0 * saturate((hit.age - 0.24) / 0.34), 2.0))
                                    * smoothstep(0.22, 0.32, hit.age) * (1.0 - smoothstep(0.45, 0.64, hit.age));
                        float intensityFlash = saturate((rim + halo + shock) * light);
                        float3 flashCol = mix(float3(0.42, 0.78, 1.0), float3(0.92, 0.96, 1.0), rim);
                        flashCol = mix(flashCol, chromaticPalette(hit.age * 1.4 + dTargetKey * 0.03, 0.11 * chroma, palA, palB, palD), shock * 0.75);
                        flashCol = gradeColor(flashCol, auxHueShift, chroma);
                        borderRgb += flashCol * intensityFlash;
                        borderAlpha = max(borderAlpha, intensityFlash);
                    }
                }

                // Proximity SDF light wrapping on neighboring keycaps & inter-key channels
                float2 lightPos = hit.isRepeat != 0u ? hit.keyCenter : hit.current;
                float2 toLight = lightPos - pos;
                float distLight = length(toLight);
                float spillRange = hit.isRepeat != 0u ? (210.0 + 110.0 * hit.heat) : (hit.radius * 1.45);
                if (distLight < spillRange && abs(effKeyDist) < 13.0 && dTargetKey > 3.0) {
                    float prox = pow(1.0 - distLight / spillRange, 2.0);
                    float2 lDir = toLight / max(1.0, distLight);
                    float facing = saturate(dot(keyNormal, lDir) * 0.65 + 0.45);
                    float sdfRim = exp(-0.28 * effKeyDist * effKeyDist) * facing;
                    float channelGlow = 0.35 * exp(-0.08 * max(0.0, effKeyDist)) * smoothstep(22.0, 2.0, interKeyRidge);
                    float spill = saturate((sdfRim + channelGlow) * prox * hit.alpha * borderBrightness * 0.95);
                    float3 spillCol = hit.isRepeat != 0u
                        ? gradeColor(mix(float3(1.0, 0.42, 0.12), float3(0.28, 0.78, 1.0), saturate(hit.heat * 0.85)), auxHueShift, chroma)
                        : gradeColor(chromaticPalette(hit.progress + distLight * 0.003, 0.08 * chroma, palA, palB, palD), hueShift, chroma);
                    borderRgb += spillCol * spill;
                    borderAlpha = max(borderAlpha, spill);
                }
            }

            // 3. Live Procedural SDF-Wrapped Vortex Plume (flag bit 2)
            if ((hit.flags & 4u) != 0u) {
                float scale = max(0.18, hit.heat);
                float2 local = (pos - float2(hit.keyCenter.x, hit.keyCenter.y - 5.0)) / scale;
                if (abs(local.x) < 190.0 && local.y > -340.0 && local.y < 55.0) {
                    float x = local.x / 160.0;
                    float h = clamp(-local.y / 320.0 + 0.12, 0.0, 1.2);
                    float t = hit.age;
                    float growth = 0.30 + 0.70 * (1.0 - pow(1.0 - saturate(t / 0.30), 3.0));
                    float lift = 0.10 + 0.32 * t * t;
                    float y = (h - lift) / growth;
                    float rise = y * 4.0 - t * 6.2;
                    float roll = fbm(float2(x * 2.8 + 9.0 + hit.seed, rise * 0.72));
                    float sway = (roll - 0.5) * (0.24 + 0.46 * saturate(y)) + 0.07 * sin(y * 9.8 - t * 7.8 + hit.seed);
                    float2 flow = float2((x - sway) * 4.8 + 13.0, rise);
                    float folds = fbm(flow + float2(1.4 * roll, hit.seed));
                    float wisps = fbm(flow * float2(3.0, 0.90) + 1.6 * folds);
                    float width = 0.56 - 0.29 * saturate(y);
                    float side = (x - sway) / width;

                    // Wrap flame around keycap SDF edges & inter-key channels
                    float sdfBoost = exp(-0.04 * abs(effKeyDist)) * 0.22;
                    float fuel = 1.02 - side * side - y * 1.42 + (folds - 0.5) * 1.38 + (wisps - 0.5) * 0.70 + sdfBoost;
                    float base = smoothstep(-0.09, 0.05, y - 0.11 * side * side + 0.12 * (folds - 0.5));
                    float shell = smoothstep(-0.12, 0.28, fuel) * base;
                    float hot = smoothstep(0.14, 1.02, fuel + 0.22 * (wisps - 0.5));
                    float ridge = pow(1.0 - abs(2.0 * wisps - 1.0), 3.0) * smoothstep(0.0, 0.35, fuel);

                    float overheat = saturate((scale - 0.35) / 0.65);
                    float baseJet = exp(-3.2 * side * side - 5.0 * max(0.0, y - 0.08) * max(0.0, y - 0.08))
                                  * smoothstep(-0.06, 0.08, y) * overheat;

                    float3 tint = mix(float3(0.88, 0.10, 0.24), float3(1.0, 0.44, 0.06), smoothstep(-0.10, 0.42, fuel));
                    tint = mix(tint, float3(1.0, 0.88, 0.36), hot);
                    tint = mix(tint, float3(0.22, 0.78, 1.0), saturate(baseJet * 1.15 + ridge * 0.45 * overheat));
                    tint = mix(tint, float3(0.98, 0.99, 1.0), saturate(hot * hot * 0.78 + baseJet * 0.82 + ridge * 0.38));

                    float halo = 0.48 * exp(-2.8 * side * side - 4.3 * (y - 0.19) * (y - 0.19)) * smoothstep(-0.13, 0.04, y);
                    float fade = (0.55 + 0.45 * smoothstep(0.0, 0.07, t)) * (1.0 - smoothstep(0.48, 1.0, t));
                    float body = shell * 0.95;
                    float a = saturate((body + halo * (1.0 - body)) * fade);
                    float3 haloCol = mix(float3(1.0, 0.25, 0.10), float3(0.25, 0.68, 1.0), overheat * saturate(1.0 - y));
                    float3 fRgb = gradeColor(tint * body + haloCol * halo * (1.0 - body), auxHueShift, chroma) * fade;
                    flameRgb += fRgb;
                    flameAlpha = max(flameAlpha, a);
                }
            }
        }

        // Evaluate the unified metaball liquid surface with Keycap SDF refraction
        float3 orbRgb = float3(0.0);
        float orbAlpha = 0.0;
        if (metaballField > 0.002) {
            float body = smoothstep(0.02, 0.62, metaballField);
            float avgHue = weightedHue / max(1e-4, weightSum);

            // Perturb surface normal by keycap SDF border gradient so liquid light wraps around keys
            float sdfEdge = exp(-0.12 * keyDist * keyDist);
            float2 refractXY = fieldGrad * 18.0 + keyNormal * sdfEdge * 0.42;
            float nz = sqrt(max(0.02, 1.0 - saturate(dot(refractXY, refractXY))));
            float3 normal = normalize(float3(refractXY, nz));

            float fresnel = pow(1.0 - normal.z, 2.6);
            float dispersion = (0.06 + 0.14 * fresnel + 0.06 * sdfEdge) * chroma;
            float3 foil = 0.90 * (0.52 * chromaticPalette(avgHue, dispersion, palA, palB, palD)
                        + 0.24 * (chromaticPalette(avgHue - 0.16, dispersion, palA, palB, palD)
                                + chromaticPalette(avgHue + 0.16, dispersion, palA, palB, palD)));
            foil = gradeColor(foil, hueShift, chroma);

            float3 halfVec = normalize(normalize(float3(0.35, 0.52, 0.92)) + float3(0.0, 0.0, 1.0));
            float gloss = pow(saturate(dot(normal, halfVec)), 54.0);
            float sdfSpec = sdfEdge * pow(saturate(dot(normal.xy, keyNormal)), 2.0) * 0.55;

            // Channel boost in the gaps between physical keycaps
            float channelBoost = 1.0 + 0.28 * smoothstep(-2.0, 6.0, keyDist) * smoothstep(24.0, 2.0, interKeyRidge);
            orbAlpha = saturate(body * channelBoost);
            orbRgb = foil * orbAlpha + (foil * (fresnel * 0.65 + sdfSpec) + gloss * 1.15) * orbAlpha * 0.85;
        }

        float3 totalRgb = (orbRgb + wakeColorSum + borderRgb + flameRgb) * intensity;
        float alphaGain = abs(intensity - 1.0) < 1e-4 ? 1.0 : min(1.35, 0.35 + 0.65 * intensity);
        float totalAlpha = saturate(max(max(orbAlpha, saturate(wakeGlow)), max(borderAlpha, flameAlpha)) * alphaGain);
        totalRgb = clamp(totalRgb, 0.0, totalAlpha);
        pixels[idx] = uchar4(float4(totalRgb, totalAlpha) * 255.0 + 0.5);
    }
    """
}

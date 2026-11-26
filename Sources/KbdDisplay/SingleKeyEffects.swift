import AppKit

enum SingleKeyEffect: CaseIterable {
    case fire, lightning, ice, waterWave, confetti, blackHole
}

/// Procedural single-key effects anchored on the struck keycap.
/// All share the same Start (% of peak), Peak size, and Taps to full heat scaling controls as Fire.
enum SingleKeyEffects {
    static func drawVectors(for beam: KeyBeam, in context: CGContext, time: Double, settings: EffectConfiguration) {
        for effect in SingleKeyEffect.allCases where settings.shows(effect, for: beam) {
            let draw: (CGContext, CGRect, [BeamSpark], Double, Double, EffectConfiguration) -> Void
            switch effect {
            case .fire: continue
            case .lightning: draw = drawLightning
            case .ice: draw = drawIce
            case .waterWave: draw = drawWaterWave
            case .confetti: draw = drawConfetti
            case .blackHole: draw = drawBlackHole
            }
            draw(context, beam.keyFrame, beam.sparks, beam.flameHeat, time, settings)
        }
    }

    /// Shared scale & opacity envelope derived from startingFraction, peakScale, and repeat heat.
    private static func envelope(heat: Double, settings: EffectConfiguration) -> (scale: Double, intensity: Double) {
        let start = settings[.startingFraction]
        let peak = settings[.peakScale]
        let fraction = start + (1.0 - start) * heat
        let scale = peak * fraction
        let intensity = 0.48 + 0.52 * fraction
        return (scale, intensity)
    }

    /// High-voltage branching Tesla lightning bolts, ionized core flash, and crackling micro-arcs.
    static func drawLightning(in context: CGContext, key: CGRect, sparks: [BeamSpark],
                              heat: Double, time: Double, settings: EffectConfiguration) {
        guard time >= 0, time < 1 else { return }
        let env = envelope(heat: heat, settings: settings)
        let colors = settings.colorParams
        let center = CGPoint(x: key.midX, y: key.midY)
        let life = min(1, time * 24) * pow(max(0, 1 - time), 1.75)
        let flicker = 0.60 + 0.40 * abs(sin(time * 78.0 + (sparks.first?.reach ?? 0.3) * 11.0))
        let power = life * flicker * env.intensity
        guard power > 0.01 else { return }

        let seedBase = UInt64(abs((sparks.first?.lane ?? 0.17) * 100_000))
            ^ (UInt64(abs((sparks.first?.reach ?? 0.53) * 100_000)) << 17)
            ^ UInt64(Int(key.midX) * 73856093 ^ Int(key.midY) * 19349663)

        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.plusLighter)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // 1. Subtle ionized core flash scaled proportionally to current heat/size
        let flashAlpha = min(1, power * (0.55 + 0.45 * heat))
        let coreRadius = (24 + 28 * env.scale) * (1.0 - 0.35 * time)
        let outerTint = colors.apply(to: NSColor(srgbRed: 0.36, green: 0.46, blue: 1.0, alpha: flashAlpha * 0.46))
        let midTint = colors.apply(to: NSColor(srgbRed: 0.30, green: 0.88, blue: 1.0, alpha: flashAlpha * 0.80))
        let whiteCore = colors.apply(to: NSColor(srgbRed: 0.94, green: 0.98, blue: 1.0, alpha: flashAlpha))

        context.saveGState()
        context.setFillColor(outerTint.cgColor)
        context.setShadow(offset: .zero, blur: 16 * CGFloat(max(0.35, env.scale)), color: midTint.cgColor)
        context.fillEllipse(in: CGRect(x: center.x - coreRadius * 0.5, y: center.y - coreRadius * 0.5,
                                       width: coreRadius, height: coreRadius))
        context.restoreGState()

        // 2. Jagged fractal branching bolts scaled from compact micro-sparks (at Start %) to peak storm bolts
        let snapStep = UInt64(time * 14.0)
        var rng = SplitMix(seed: seedBase ^ (snapStep &* 0x9E3779B97F4A7C15))
        let boltCount = max(2, Int((2.0 + 3.0 * min(1.3, env.scale)).rounded()))
        let reach = (64 + 78 * env.scale) * (0.65 + 0.35 * min(1, time * 5.0))
        let widthScale = max(0.45, settings[.particleSize]) * (0.55 + 0.45 * min(1.4, env.scale))

        for b in 0..<boltCount {
            let baseAngle = (Double(b) / Double(boltCount)) * 2.0 * .pi + rng.next(in: -0.45...0.45)
            let length = reach * rng.next(in: 0.65...1.08)
            let startOffset = CGPoint(x: center.x + cos(baseAngle) * 8, y: center.y + sin(baseAngle) * 8)
            let endPoint = CGPoint(x: center.x + cos(baseAngle) * length, y: center.y + sin(baseAngle) * length)

            let mainPoints = fractalBolt(from: startOffset, to: endPoint, generations: 4,
                                         displacement: (11 + 14 * env.scale), rng: &rng)
            strokeBolt(mainPoints, in: context, width: 1.8 * widthScale,
                       outer: outerTint, mid: midTint, core: whiteCore, alpha: power)

            // Secondary forks appear more prominently as heat/scale grows
            let branches = env.scale > 0.55 ? 2 : (env.scale > 0.30 ? 1 : 0)
            for _ in 0..<branches {
                guard mainPoints.count > 4 else { continue }
                let idx = Int(rng.next(in: 2...Double(mainPoints.count - 3)))
                let origin = mainPoints[idx]
                let forkAngle = baseAngle + (rng.nextUnit() < 0.5 ? -1 : 1) * rng.next(in: 0.35...0.85)
                let forkLen = length * rng.next(in: 0.30...0.52)
                let forkEnd = CGPoint(x: origin.x + cos(forkAngle) * forkLen,
                                      y: origin.y + sin(forkAngle) * forkLen)
                let forkPoints = fractalBolt(from: origin, to: forkEnd, generations: 3,
                                             displacement: 7 + 8 * env.scale, rng: &rng)
                strokeBolt(forkPoints, in: context, width: 1.1 * widthScale,
                           outer: outerTint, mid: midTint, core: whiteCore, alpha: power * 0.78)
            }
        }

        // 3. Electric corona ring hugging the keycap border
        let coronaRect = key.insetBy(dx: 5, dy: 5)
        let coronaPoints = jaggedKeyPerimeter(coronaRect, segments: 20, jitter: 1.8 + 2.8 * env.scale, rng: &rng)
        strokeBolt(coronaPoints, in: context, width: 1.15 * widthScale,
                   outer: outerTint, mid: midTint, core: whiteCore, alpha: power * 0.62, closed: true)
    }

    /// Crystalline frost bloom: 6-fold dendritic snowflake arms, faceted prism shards, and diamond dust.
    static func drawIce(in context: CGContext, key: CGRect, sparks: [BeamSpark],
                        heat: Double, time: Double, settings: EffectConfiguration) {
        guard time >= 0, time < 1 else { return }
        let env = envelope(heat: heat, settings: settings)
        let colors = settings.colorParams
        let center = CGPoint(x: key.midX, y: key.midY)
        let grow = 1.0 - pow(1.0 - min(1.0, time / 0.24), 3.0)
        let fade = min(1.0, time * 14.0) * (1.0 - smoothstep(0.45, 1.0, time)) * env.intensity
        guard fade > 0.01 else { return }

        let seedBase = UInt64(abs((sparks.first?.reach ?? 0.41) * 100_000))
            ^ (UInt64(abs((sparks.first?.lane ?? -0.22) * 100_000)) << 19)
            ^ UInt64(Int(key.midX) * 2654435761 ^ Int(key.midY) * 2246822519)
        var rng = SplitMix(seed: seedBase)

        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.plusLighter)
        context.setLineCap(.round)
        context.setLineJoin(.miter)

        let radiusScale = (0.34 + 0.66 * env.scale) * grow
        let baseRotation = rng.next(in: 0...(Double.pi / 3.0)) + time * 0.14
        let glacialBlue = colors.apply(to: NSColor(srgbRed: 0.22, green: 0.72, blue: 1.0, alpha: fade * 0.65))
        let frostCyan = colors.apply(to: NSColor(srgbRed: 0.62, green: 0.94, blue: 1.0, alpha: fade * 0.85))
        let crystalWhite = colors.apply(to: NSColor(srgbRed: 0.94, green: 0.99, blue: 1.0, alpha: fade * 0.92))
        let deepIndigo = colors.apply(to: NSColor(srgbRed: 0.34, green: 0.46, blue: 1.0, alpha: fade * 0.42))

        // 1. Sub-key frost mist halo
        context.saveGState()
        let haloR = 88.0 * radiusScale
        context.setFillColor(deepIndigo.withAlphaComponent(fade * 0.18).cgColor)
        context.setShadow(offset: .zero, blur: 16 * CGFloat(max(0.35, env.scale)), color: glacialBlue.cgColor)
        context.fillEllipse(in: CGRect(x: center.x - haloR, y: center.y - haloR, width: haloR * 2, height: haloR * 2))
        context.restoreGState()

        // 2. 6-fold symmetric crystalline snowflake dendrites radiating from the key center
        let armLength = 108.0 * radiusScale
        let hexInner = 30.0 * radiusScale
        let hexPath = CGMutablePath()
        for i in 0..<6 {
            let a = baseRotation + Double(i) * (.pi / 3.0)
            let p = CGPoint(x: center.x + cos(a) * hexInner, y: center.y + sin(a) * hexInner)
            if i == 0 { hexPath.move(to: p) } else { hexPath.addLine(to: p) }
        }
        hexPath.closeSubpath()

        context.setFillColor(glacialBlue.withAlphaComponent(fade * 0.16).cgColor)
        context.addPath(hexPath)
        context.fillPath()
        context.setStrokeColor(crystalWhite.withAlphaComponent(fade * 0.78).cgColor)
        context.setLineWidth(1.0 + 0.6 * CGFloat(min(1.4, env.scale)))
        context.addPath(hexPath)
        context.strokePath()

        let dendritePath = CGMutablePath()
        for i in 0..<6 {
            let angle = baseRotation + Double(i) * (.pi / 3.0)
            let dir = CGPoint(x: cos(angle), y: sin(angle))
            let tip = CGPoint(x: center.x + dir.x * armLength, y: center.y + dir.y * armLength)
            dendritePath.move(to: center)
            dendritePath.addLine(to: tip)

            let fractions = env.scale > 0.45 ? [0.38, 0.64, 0.84] : [0.55, 0.80]
            for frac in fractions {
                let branchOrigin = CGPoint(x: center.x + dir.x * armLength * frac,
                                           y: center.y + dir.y * armLength * frac)
                let needleLen = armLength * (0.32 - 0.14 * frac)
                for side in [-1.0, 1.0] {
                    let na = angle + side * (.pi / 3.0)
                    dendritePath.move(to: branchOrigin)
                    dendritePath.addLine(to: CGPoint(x: branchOrigin.x + cos(na) * needleLen,
                                                     y: branchOrigin.y + sin(na) * needleLen))
                }
            }
        }
        let lineScale = CGFloat(0.55 + 0.45 * min(1.4, env.scale))
        context.setShadow(offset: .zero, blur: 8 * lineScale, color: glacialBlue.cgColor)
        context.setStrokeColor(glacialBlue.cgColor)
        context.setLineWidth(3.0 * lineScale)
        context.addPath(dendritePath)
        context.strokePath()
        context.setStrokeColor(crystalWhite.cgColor)
        context.setLineWidth(1.2 * lineScale)
        context.addPath(dendritePath)
        context.strokePath()

        // 3. Faceted diamond ice shards erupting outward
        let shardCount = max(4, Int((4.0 + 6.0 * min(1.3, env.scale)).rounded()))
        for i in 0..<shardCount {
            let angle = baseRotation + Double(i) * (2.0 * .pi / Double(shardCount)) + rng.next(in: -0.22...0.22)
            let dist = (22 + rng.next(in: 14...78) * radiusScale) + time * (10 + 14 * env.scale)
            let shardLen = (9 + rng.next(in: 5...15) * (0.45 + 0.55 * env.scale)) * (1.0 - 0.35 * time)
            let shardW = shardLen * 0.28
            let cosA = cos(angle), sinA = sin(angle)
            let origin = CGPoint(x: center.x + cosA * dist, y: center.y + sinA * dist)
            let tip = CGPoint(x: origin.x + cosA * shardLen, y: origin.y + sinA * shardLen)
            let left = CGPoint(x: origin.x + cosA * shardLen * 0.35 - sinA * shardW,
                               y: origin.y + sinA * shardLen * 0.35 + cosA * shardW)
            let right = CGPoint(x: origin.x + cosA * shardLen * 0.35 + sinA * shardW,
                                y: origin.y + sinA * shardLen * 0.35 - cosA * shardW)

            let shard = CGMutablePath()
            shard.move(to: origin); shard.addLine(to: left); shard.addLine(to: tip); shard.addLine(to: right)
            shard.closeSubpath()

            context.setFillColor(frostCyan.withAlphaComponent(fade * 0.36).cgColor)
            context.addPath(shard)
            context.fillPath()
            context.setStrokeColor(crystalWhite.withAlphaComponent(fade * 0.80).cgColor)
            context.setLineWidth(0.95)
            context.addPath(shard)
            context.strokePath()
        }

        // 4. Frosted crystalline key border
        let frostTile = key.insetBy(dx: 5, dy: 5)
        let borderPath = CGPath(roundedRect: frostTile, cornerWidth: 12, cornerHeight: 12, transform: nil)
        context.setShadow(offset: .zero, blur: 9 * lineScale, color: glacialBlue.cgColor)
        context.setStrokeColor(frostCyan.withAlphaComponent(fade * 0.68).cgColor)
        context.setLineWidth(1.4 + 1.4 * CGFloat(min(1.4, env.scale)))
        context.addPath(borderPath)
        context.strokePath()

        // 5. Glittering 4-point diamond frost dust
        let dustCount = max(5, Int((5.0 + 10.0 * min(1.3, env.scale)).rounded()))
        for _ in 0..<dustCount {
            let a = rng.next(in: 0...(2.0 * .pi))
            let r = rng.next(in: 18...115) * (0.35 + 0.65 * time) * (0.4 + 0.6 * env.scale)
            let driftY = time * time * (12 + 14 * env.scale)
            let pos = CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r + driftY)
            let twinkle = 0.4 + 0.6 * abs(sin(time * 24.0 + a * 5.0))
            let s = (2.0 + rng.next(in: 0...2.6)) * twinkle * (1.0 - 0.45 * time)
            let star = CGMutablePath()
            star.move(to: CGPoint(x: pos.x - s, y: pos.y))
            star.addLine(to: CGPoint(x: pos.x + s, y: pos.y))
            star.move(to: CGPoint(x: pos.x, y: pos.y - s))
            star.addLine(to: CGPoint(x: pos.x, y: pos.y + s))
            context.setStrokeColor(crystalWhite.withAlphaComponent(fade * twinkle).cgColor)
            context.setLineWidth(1.0)
            context.addPath(star)
            context.strokePath()
        }
    }

    /// Single-key Water Wave splash: concentric capillary ripple rings, caustic crown, and flying droplets.
    static func drawWaterWave(in context: CGContext, key: CGRect, sparks: [BeamSpark],
                              heat: Double, time: Double, settings: EffectConfiguration) {
        guard time >= 0, time < 1 else { return }
        let env = envelope(heat: heat, settings: settings)
        let colors = settings.colorParams
        let center = CGPoint(x: key.midX, y: key.midY)
        let fade = min(1.0, time * 16.0) * (1.0 - smoothstep(0.55, 1.0, time)) * env.intensity
        guard fade > 0.01 else { return }

        let seedBase = UInt64(abs((sparks.first?.reach ?? 0.63) * 100_000))
            ^ (UInt64(abs((sparks.first?.lane ?? 0.31) * 100_000)) << 15)
            ^ (UInt64(max(0, Int(key.midX))) &* 11400714819323198485)
            ^ (UInt64(max(0, Int(key.midY))) &* 14029467366897019727)
        var rng = SplitMix(seed: seedBase)

        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.plusLighter)
        context.setLineCap(.round)

        let maxRadius = 56.0 + 115.0 * env.scale
        let deepAqua = colors.apply(to: NSColor(srgbRed: 0.08, green: 0.56, blue: 0.96, alpha: fade * 0.70))
        let foamCyan = colors.apply(to: NSColor(srgbRed: 0.45, green: 0.94, blue: 1.0, alpha: fade * 0.92))
        let specWhite = colors.apply(to: NSColor(srgbRed: 0.92, green: 0.99, blue: 1.0, alpha: fade))

        // 1. Soft aquatic caustic pool under the keycap
        let poolR = (28.0 + 46.0 * env.scale) * (0.4 + 0.6 * min(1, time * 3.5))
        context.saveGState()
        context.setFillColor(deepAqua.withAlphaComponent(fade * 0.22 * (1 - time)).cgColor)
        context.setShadow(offset: .zero, blur: 18 * CGFloat(max(0.4, env.scale)), color: deepAqua.cgColor)
        context.fillEllipse(in: CGRect(x: center.x - poolR, y: center.y - poolR, width: poolR * 2, height: poolR * 2))
        context.restoreGState()

        // 2. Staggered concentric water ripple rings with organic sinusoidal wave undulation
        let ringCount = env.scale > 0.65 ? 4 : (env.scale > 0.32 ? 3 : 2)
        for rIdx in 0..<ringCount {
            let delay = Double(rIdx) * 0.11
            let localT = (time - delay) / (1.0 - delay)
            guard localT > 0, localT < 1 else { continue }
            let ease = 1.0 - pow(1.0 - localT, 2.3)
            let radius = 14.0 + (maxRadius - 14.0) * ease
            let ringAlpha = min(1.0, localT * 10.0) * pow(1.0 - localT, 1.45) * env.intensity
            guard ringAlpha > 0.01 else { continue }

            let segments = 48
            let waveAmp = (2.2 + 4.5 * env.scale) * (1.0 - 0.65 * localT)
            let phase = Double(rIdx) * 1.9 + time * 9.0
            let path = CGMutablePath()
            for s in 0...segments {
                let theta = (Double(s) / Double(segments)) * 2.0 * .pi
                let wobble = sin(theta * 6.0 + phase) * waveAmp * 0.65
                    + cos(theta * 11.0 - phase * 1.3) * waveAmp * 0.35
                let rad = radius + wobble
                let p = CGPoint(x: center.x + cos(theta) * rad, y: center.y + sin(theta) * rad)
                if s == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()

            let baseW = CGFloat((2.4 + 2.8 * env.scale) * (1.0 - 0.55 * localT))
            // Wide deep aqua trough glow
            context.setStrokeColor(deepAqua.withAlphaComponent(ringAlpha * 0.45).cgColor)
            context.setLineWidth(baseW * 3.0)
            context.addPath(path)
            context.strokePath()
            // Bright cyan capillary crest
            context.setStrokeColor(foamCyan.withAlphaComponent(ringAlpha * 0.85).cgColor)
            context.setLineWidth(baseW * 1.2)
            context.addPath(path)
            context.strokePath()
            // Specular caustic highlight filament
            context.setStrokeColor(specWhite.withAlphaComponent(ringAlpha * 0.70).cgColor)
            context.setLineWidth(max(0.8, baseW * 0.45))
            context.addPath(path)
            context.strokePath()
        }

        // 3. Flying water splash droplets arcing outward from the crest
        let dropCount = max(4, Int((5.0 + 10.0 * min(1.3, env.scale)).rounded()))
        for _ in 0..<dropCount {
            let angle = rng.next(in: 0...(2.0 * .pi))
            let speed = rng.next(in: 0.55...1.15) * maxRadius
            let birth = rng.next(in: 0...0.16)
            let life = (time - birth) / 0.68
            guard life > 0, life < 1 else { continue }
            let dist = 16.0 + speed * (1.0 - pow(1.0 - life, 2.1))
            let dropYGravity = 16.0 * life * life
            let pos = CGPoint(x: center.x + cos(angle) * dist, y: center.y + sin(angle) * dist + dropYGravity)
            let dropAlpha = min(1.0, life * 12.0) * (1.0 - life) * env.intensity
            let dropR = CGFloat((1.6 + rng.next(in: 0...2.4)) * (0.55 + 0.45 * env.scale) * (1.0 - 0.35 * life))
            context.setFillColor(foamCyan.withAlphaComponent(dropAlpha * 0.72).cgColor)
            context.fillEllipse(in: CGRect(x: pos.x - dropR * 1.4, y: pos.y - dropR * 1.4,
                                           width: dropR * 2.8, height: dropR * 2.8))
            context.setFillColor(specWhite.withAlphaComponent(dropAlpha * 0.95).cgColor)
            context.fillEllipse(in: CGRect(x: pos.x - dropR * 0.65, y: pos.y - dropR * 0.65,
                                           width: dropR * 1.3, height: dropR * 1.3))
        }
    }

    /// Single-key Confetti Burst: 3D tumbling colorful geometric ribbons and mini streamers popping upward.
    static func drawConfetti(in context: CGContext, key: CGRect, sparks: [BeamSpark],
                             heat: Double, time: Double, settings: EffectConfiguration) {
        guard time >= 0, time < 1 else { return }
        let env = envelope(heat: heat, settings: settings)
        let colors = settings.colorParams
        let center = CGPoint(x: key.midX, y: key.midY)
        let fade = min(1.0, time * 18.0) * (1.0 - smoothstep(0.62, 1.0, time)) * env.intensity
        guard fade > 0.01 else { return }

        let seedBase = UInt64(abs((sparks.first?.lane ?? 0.27) * 100_000))
            ^ (UInt64(abs((sparks.first?.reach ?? 0.71) * 100_000)) << 13)
            ^ (UInt64(max(0, Int(key.midX))) &* 6364136223846793005)
            ^ (UInt64(max(0, Int(key.midY))) &* 1442695040888963407)
        var rng = SplitMix(seed: seedBase)

        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.plusLighter)

        let pieceCount = max(8, Int((10.0 + 22.0 * min(1.4, env.scale)).rounded()))
        let sizeMul = max(0.5, settings[.particleSize]) * (0.65 + 0.50 * min(1.4, env.scale))
        let spread = 68.0 + 135.0 * env.scale

        for i in 0..<pieceCount {
            let launchAngle = -Double.pi * 0.5 + rng.next(in: -1.45...1.45)
            let speed = rng.next(in: 0.45...1.15) * spread
            let drag = 1.0 - pow(1.0 - time, 2.2)
            let flutter = sin(time * rng.next(in: 9.0...17.0) + Double(i)) * (6.0 + 10.0 * env.scale) * time
            let gravity = (95.0 + 85.0 * env.scale) * time * time
            let x = center.x + cos(launchAngle) * speed * drag + flutter
            let y = center.y + sin(launchAngle) * speed * drag + gravity

            let spin = rng.next(in: 0...(2.0 * .pi)) + time * rng.next(in: 8.0...18.0)
            let tumble = max(0.18, abs(cos(time * rng.next(in: 10.0...22.0) + Double(i) * 1.7)))
            let w = (6.5 + rng.next(in: 0...4.5)) * sizeMul
            let h = (3.4 + rng.next(in: 0...2.4)) * sizeMul * tumble

            let color = colors.samplePalette(at: Float(fmod(Double(i) * 0.17 + rng.next(in: 0...0.2), 1.0)))
                .withAlphaComponent(fade * (0.72 + 0.28 * tumble))

            context.saveGState()
            context.translateBy(x: x, y: y)
            context.rotate(by: spin)
            context.setFillColor(color.cgColor)
            if i % 4 == 0 {
                // Confetti star dot
                context.fillEllipse(in: CGRect(x: -h, y: -h, width: h * 2, height: h * 2))
            } else {
                // Tumbling ribbon rectangle
                context.fill(CGRect(x: -w * 0.5, y: -h * 0.5, width: w, height: h))
            }
            context.restoreGState()
        }
    }

    /// Single-key Black Hole singularity: dark event horizon, swirling relativistic accretion ring, and inward matter streaks.
    static func drawBlackHole(in context: CGContext, key: CGRect, sparks: [BeamSpark],
                              heat: Double, time: Double, settings: EffectConfiguration) {
        guard time >= 0, time < 1 else { return }
        let env = envelope(heat: heat, settings: settings)
        let colors = settings.colorParams
        let center = CGPoint(x: key.midX, y: key.midY)
        let open = 1.0 - pow(1.0 - min(1.0, time / 0.22), 3.0)
        let collapse = 1.0 - smoothstep(0.58, 1.0, time)
        let presence = open * collapse
        guard presence > 0.01 else { return }

        let seedBase = UInt64(abs((sparks.first?.reach ?? 0.51) * 100_000))
            ^ (UInt64(abs((sparks.first?.lane ?? -0.14) * 100_000)) << 17)
            ^ (UInt64(max(0, Int(key.midX))) &* 2862933555777941757)
        var rng = SplitMix(seed: seedBase)

        let horizonR = (14.0 + 26.0 * env.scale) * presence
        let diskR = (38.0 + 78.0 * env.scale) * (0.55 + 0.45 * open)

        context.saveGState()
        defer { context.restoreGState() }

        // 1. Dark event horizon void (normal blend punches a deep black core over keycaps)
        context.setBlendMode(.normal)
        context.setFillColor(NSColor(white: 0, alpha: min(0.95, presence * 0.92)).cgColor)
        context.fillEllipse(in: CGRect(x: center.x - horizonR, y: center.y - horizonR,
                                       width: horizonR * 2, height: horizonR * 2))

        // 2. Relativistic accretion disk rings & gravitational lensing glow (additive)
        context.setBlendMode(.plusLighter)
        context.setLineCap(.round)
        let rimColor = colors.apply(to: NSColor(srgbRed: 0.72, green: 0.34, blue: 1.0, alpha: presence * env.intensity))
        let photonColor = colors.apply(to: NSColor(srgbRed: 1.0, green: 0.76, blue: 0.42, alpha: presence * env.intensity))
        let hotCore = colors.apply(to: NSColor(srgbRed: 0.96, green: 0.98, blue: 1.0, alpha: presence * env.intensity))

        // Photon sphere bright thin ring right outside the horizon
        let photonRect = CGRect(x: center.x - horizonR * 1.15, y: center.y - horizonR * 1.15,
                                width: horizonR * 2.3, height: horizonR * 2.3)
        context.setShadow(offset: .zero, blur: 14 * CGFloat(max(0.4, env.scale)), color: rimColor.cgColor)
        context.setStrokeColor(hotCore.withAlphaComponent(presence * 0.85 * env.intensity).cgColor)
        context.setLineWidth(1.6 + 1.2 * CGFloat(min(1.4, env.scale)))
        context.strokeEllipse(in: photonRect)

        // Tilted swirling accretion disk arcs
        let tilt = (sparks.first?.lane ?? 0.15) * 0.9
        let arcCount = 4 + Int((env.scale * 4.0).rounded())
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: tilt)
        for i in 0..<arcCount {
            let orbitFrac = 0.42 + 0.58 * (Double(i) / Double(max(1, arcCount - 1)))
            let rx = diskR * orbitFrac
            let ry = rx * 0.42
            let spinAngle = time * (9.5 - 3.5 * orbitFrac) + Double(i) * 1.7
            let sweep = 1.6 + rng.next(in: 0.4...1.5)
            let segs = 18
            let arcPath = CGMutablePath()
            for s in 0...segs {
                let a = spinAngle + sweep * (Double(s) / Double(segs))
                let p = CGPoint(x: cos(a) * rx, y: sin(a) * ry)
                if s == 0 { arcPath.move(to: p) } else { arcPath.addLine(to: p) }
            }
            let c = i % 2 == 0 ? photonColor : rimColor
            context.setStrokeColor(c.withAlphaComponent(presence * (0.45 + 0.35 * (1 - orbitFrac)) * env.intensity).cgColor)
            context.setLineWidth(CGFloat(1.4 + 2.2 * (1 - orbitFrac)) * CGFloat(max(0.5, env.scale)))
            context.addPath(arcPath)
            context.strokePath()
        }
        context.restoreGState()

        // 3. Matter streaks spiraling INWARD toward the event horizon
        let streakCount = max(6, Int((7.0 + 11.0 * min(1.3, env.scale)).rounded()))
        for i in 0..<streakCount {
            let startAngle = rng.next(in: 0...(2.0 * .pi))
            let startR = diskR * rng.next(in: 0.85...1.45)
            let localT = fmod(time * rng.next(in: 1.1...1.7) + Double(i) * 0.13, 1.0)
            let r1 = startR * (1.0 - localT * 0.82) + horizonR * 0.9 * localT
            let r0 = min(startR * 1.5, r1 + 14.0 + 22.0 * env.scale * (1.0 - localT))
            let a1 = startAngle + localT * 3.8
            let a0 = startAngle + max(0, localT - 0.12) * 3.8
            let p0 = CGPoint(x: center.x + cos(a0) * r0, y: center.y + sin(a0) * r0)
            let p1 = CGPoint(x: center.x + cos(a1) * r1, y: center.y + sin(a1) * r1)
            let streakAlpha = sin(localT * .pi) * presence * env.intensity * 0.85
            let sc = colors.samplePalette(at: Float(fmod(Double(i) * 0.21 + localT * 0.4, 1.0)))
                .withAlphaComponent(streakAlpha)
            context.setStrokeColor(sc.cgColor)
            context.setLineWidth(CGFloat(1.1 + 1.4 * env.scale) * CGFloat(1.0 - 0.5 * localT))
            context.move(to: p0)
            context.addLine(to: p1)
            context.strokePath()
        }
    }

    // MARK: - Procedural Geometry Helpers

    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { self.state = seed == 0 ? 0x517cc1b727220a95 : seed }
        mutating func nextUnit() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z = z ^ (z >> 31)
            return Double(z >> 11) / Double(1 << 53)
        }
        mutating func next(in range: ClosedRange<Double>) -> Double {
            range.lowerBound + (range.upperBound - range.lowerBound) * nextUnit()
        }
    }

    private static func fractalBolt(from start: CGPoint, to end: CGPoint, generations: Int,
                                    displacement: Double, rng: inout SplitMix) -> [CGPoint] {
        var pts = [start, end]
        var disp = displacement
        for _ in 0..<generations {
            var next: [CGPoint] = [pts[0]]
            next.reserveCapacity(pts.count * 2)
            for i in 0..<(pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                let mid = CGPoint(x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5)
                let dx = b.x - a.x, dy = b.y - a.y
                let len = max(1.0, hypot(dx, dy))
                let nx = -dy / len, ny = dx / len
                let offset = rng.next(in: -disp...disp)
                next.append(CGPoint(x: mid.x + nx * offset, y: mid.y + ny * offset))
                next.append(b)
            }
            pts = next
            disp *= 0.54
        }
        return pts
    }

    private static func jaggedKeyPerimeter(_ rect: CGRect, segments: Int, jitter: Double, rng: inout SplitMix) -> [CGPoint] {
        var pts: [CGPoint] = []
        pts.reserveCapacity(segments)
        let perim = 2.0 * (rect.width + rect.height)
        for i in 0..<segments {
            var d = perim * Double(i) / Double(segments)
            var p: CGPoint
            if d < rect.width {
                p = CGPoint(x: rect.minX + d, y: rect.minY)
            } else if d < rect.width + rect.height {
                d -= rect.width
                p = CGPoint(x: rect.maxX, y: rect.minY + d)
            } else if d < 2 * rect.width + rect.height {
                d -= rect.width + rect.height
                p = CGPoint(x: rect.maxX - d, y: rect.maxY)
            } else {
                d -= 2 * rect.width + rect.height
                p = CGPoint(x: rect.minX, y: rect.maxY - d)
            }
            p.x += rng.next(in: -jitter...jitter)
            p.y += rng.next(in: -jitter...jitter)
            pts.append(p)
        }
        return pts
    }

    private static func strokeBolt(_ points: [CGPoint], in context: CGContext, width: CGFloat,
                                   outer: NSColor, mid: NSColor, core: NSColor, alpha: Double, closed: Bool = false) {
        guard points.count >= 2 else { return }
        let path = CGMutablePath()
        path.move(to: points[0])
        for p in points.dropFirst() { path.addLine(to: p) }
        if closed { path.closeSubpath() }

        context.setStrokeColor(outer.withAlphaComponent(alpha * 0.32).cgColor)
        context.setLineWidth(width * 4.0)
        context.addPath(path)
        context.strokePath()

        context.setStrokeColor(mid.withAlphaComponent(alpha * 0.75).cgColor)
        context.setLineWidth(width * 1.8)
        context.addPath(path)
        context.strokePath()

        context.setStrokeColor(core.withAlphaComponent(alpha).cgColor)
        context.setLineWidth(max(0.85, width * 0.68))
        context.addPath(path)
        context.strokePath()
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
}

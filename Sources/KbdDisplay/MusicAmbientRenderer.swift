import AppKit
import Foundation
import simd

/// Renders all 12 Music Ambient visuals (8 Metal GPU simulations + 4 CoreGraphics vector modes)
/// and supports smooth auto-cycling between visuals.
final class MusicAmbientRenderer {
    private struct Star {
        var x: Float
        var y: Float
        var z: Float
        var prevZ: Float
        var colorPhase: Float
    }

    private struct BeatRing {
        var radius: CGFloat
        var maxRadius: CGFloat
        var bornAt: TimeInterval
        var duration: TimeInterval
        var colorPhase: Float
    }

    let shader = MusicAmbientShader()
    private static let maximumKeyImpulse: Float = 0.52
    private var availableKeyImpulse = maximumKeyImpulse
    private var pendingKeyImpulses: [MusicMetalContext.WaterImpulseGPU] = []
    private var lastFrame: MusicSpectrumFrame = .silent
    private var animTime: TimeInterval = 0
    private var cycleStartedAt: TimeInterval?
    private var cycleOffset: Int = 0
    private var rngState: UInt64 = 0xD00D_F00D_1337_BEEF

    private var stars: [Star] = []
    private var warpRings: [BeatRing] = []
    private var matrixBeatRings: [BeatRing] = []

    private var cachedImage: CGImage?
    private var cachedStyle: MusicVisualStyle?
    private var cachedTime: TimeInterval = -1
    private var cachedColorParams: EffectColorParams?
    private var cachedIntensity: Double = -1

    init() {
        stars = (0..<110).map { _ in makeStar(z: Float.random(in: 0.08...1.0)) }
    }

    func reset() {
        shader.resetWater()
        availableKeyImpulse = Self.maximumKeyImpulse
        pendingKeyImpulses.removeAll()
        lastFrame = .silent
        cycleStartedAt = nil
        cycleOffset = 0
        warpRings.removeAll()
        matrixBeatRings.removeAll()
        invalidateCache()
    }

    func invalidateCache() {
        cachedImage = nil
        cachedStyle = nil
        cachedTime = -1
    }

    func injectKeyImpulse(at boardPoint: CGPoint, strength: Double = 1.0) {
        let nx = Float(max(0.02, min(0.98, boardPoint.x / Action75.canvas.width)))
        let ny = Float(max(0.02, min(0.98, boardPoint.y / Action75.canvas.height)))
        pendingKeyImpulses.append(MusicMetalContext.WaterImpulseGPU(
            normPos: SIMD2(nx, ny),
            radius: 3.8,
            strength: 0.38 * Float(min(1.4, max(0.3, strength))),
            huePhase: nx * 0.7 + ny * 0.3
        ))
        if pendingKeyImpulses.count > 16 {
            pendingKeyImpulses.removeFirst(pendingKeyImpulses.count - 16)
        }
    }

    func currentVisualStyle(for settings: EffectConfiguration, at now: TimeInterval = 0) -> MusicVisualStyle {
        guard settings.musicAutoCycle else { return settings.musicVisual }
        let all = MusicVisualStyle.allCases
        let baseIdx = all.firstIndex(of: settings.musicVisual) ?? 0
        let elapsed = cycleStartedAt.map { max(0, now - $0) } ?? 0
        let step = Int(elapsed / 18.0)
        return all[(baseIdx + step + cycleOffset) % all.count]
    }

    func advanceCycle(baseStyle: MusicVisualStyle) -> MusicVisualStyle {
        let all = MusicVisualStyle.allCases
        let idx = all.firstIndex(of: baseStyle) ?? 0
        return all[(idx + 1) % all.count]
    }

    private func nextUnit() -> Float {
        rngState &+= 0x9E3779B97F4A7C15
        var z = rngState
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return Float(z >> 40) / Float(1 << 24)
    }

    private func makeStar(z: Float) -> Star {
        var x = nextUnit() * 2.0 - 1.0
        let y = nextUnit() * 2.0 - 1.0
        if abs(x) < 0.06 && abs(y) < 0.06 {
            x = x >= 0 ? 0.14 : -0.14
        }
        return Star(x: x, y: y, z: z, prevZ: z, colorPhase: nextUnit())
    }

    func step(frame: MusicSpectrumFrame, dt: Double, now: TimeInterval, settings: EffectConfiguration) {
        let safeDt = max(1.0 / 120.0, min(0.05, dt))
        animTime += safeDt
        lastFrame = frame
        if cycleStartedAt == nil { cycleStartedAt = now }

        let activeStyle = currentVisualStyle(for: settings, at: now)
        let react = Float(settings[.musicReactivity])

        // Let one tap make a clear ripple; keys in a chord share the available strength.
        availableKeyImpulse = min(Self.maximumKeyImpulse, availableKeyImpulse + Float(safeDt) * 1.45)
        if activeStyle == .waterPool {
            var impulses = pendingKeyImpulses
            pendingKeyImpulses.removeAll(keepingCapacity: true)
            let requested = impulses.reduce(Float.zero) { $0 + $1.strength }
            if requested > availableKeyImpulse {
                let scale = availableKeyImpulse / requested
                for i in impulses.indices { impulses[i].strength *= scale }
            }
            availableKeyImpulse = max(0, availableKeyImpulse - requested)

            if frame.beatTriggered {
                // Main bass drop crater positioned with stereo balance + slight organic wander
                let bx = max(0.14, min(0.86, 0.5 + frame.stereoBalance * 0.24 + (nextUnit() - 0.5) * 0.22))
                let by = 0.28 + nextUnit() * 0.44
                let amp = (1.65 + frame.subBass * 1.15) * react
                impulses.append(MusicMetalContext.WaterImpulseGPU(
                    normPos: SIMD2(bx, by),
                    radius: 11.5 + frame.subBass * 3.5,
                    strength: amp,
                    huePhase: frame.dominantPitch + nextUnit() * 0.2
                ))
                if frame.bass > 0.58 {
                    let bx2 = max(0.12, min(0.88, 1.0 - bx + (nextUnit() - 0.5) * 0.14))
                    let by2 = 0.25 + nextUnit() * 0.50
                    impulses.append(MusicMetalContext.WaterImpulseGPU(
                        normPos: SIMD2(bx2, by2),
                        radius: 9.0,
                        strength: amp * 0.72,
                        huePhase: frame.dominantPitch + 0.35
                    ))
                }
            }

            if frame.snareTriggered {
                let sx = max(0.10, min(0.90, 0.2 + frame.dominantPitch * 0.6 + (nextUnit() - 0.5) * 0.16))
                let sy = 0.22 + nextUnit() * 0.56
                impulses.append(MusicMetalContext.WaterImpulseGPU(
                    normPos: SIMD2(sx, sy),
                    radius: 6.5,
                    strength: (1.15 + frame.mids * 0.7) * react,
                    huePhase: 0.45 + frame.dominantPitch * 0.5
                ))
            }

            if frame.hatTriggered || (frame.highs > 0.38 && nextUnit() > 0.55) {
                let drops = frame.hatTriggered ? 2 : 1
                for _ in 0..<drops {
                    impulses.append(MusicMetalContext.WaterImpulseGPU(
                        normPos: SIMD2(0.08 + nextUnit() * 0.84, 0.12 + nextUnit() * 0.76),
                        radius: 2.8 + nextUnit() * 1.4,
                        strength: (0.62 + frame.highs * 0.6) * react,
                        huePhase: 0.75 + nextUnit() * 0.25
                    ))
                }
            }

            // Continuous subtle edge swells driven by 6 sampled FFT bands so melody gently ripples the pool
            if !frame.isSilent {
                for i in 0..<6 {
                    let u = (Float(i) + 0.5) / 6.0
                    let bandEnergy = frame.bands[min(31, i * 5 + 1)]
                    if bandEnergy > 0.14 {
                        let edgeY: Float = (i % 2 == 0) ? 0.08 : 0.92
                        let waveOsc = sin(Float(animTime) * (3.2 + Float(i) * 0.7))
                        impulses.append(MusicMetalContext.WaterImpulseGPU(
                            normPos: SIMD2(u, edgeY),
                            radius: 5.5,
                            strength: bandEnergy * 0.22 * waveOsc * react,
                            huePhase: u
                        ))
                    }
                }
            }

            shader.stepWater(impulses: impulses, substeps: 2)
        } else {
            pendingKeyImpulses.removeAll()
        }

        // 2. Step Starfield Warp
        if activeStyle == .starfieldWarp {
            let speed = Float(safeDt) * (0.28 + frame.energy * 1.15 + frame.beatPulse * 1.45) * react
            for i in 0..<stars.count {
                stars[i].prevZ = stars[i].z
                stars[i].z -= speed * (0.6 + stars[i].colorPhase * 0.7)
                if stars[i].z <= 0.03 {
                    stars[i] = makeStar(z: 1.0)
                }
            }
            if frame.beatTriggered {
                warpRings.append(BeatRing(
                    radius: 20,
                    maxRadius: 1120,
                    bornAt: now,
                    duration: 0.85,
                    colorPhase: frame.dominantPitch
                ))
                if warpRings.count > 8 { warpRings.removeFirst(warpRings.count - 8) }
            }
            warpRings.removeAll { now - $0.bornAt >= $0.duration }
        }

        // 3. Step Key Matrix EQ beat rings
        if activeStyle == .keyMatrixEQ {
            if frame.beatTriggered {
                matrixBeatRings.append(BeatRing(
                    radius: 30,
                    maxRadius: 1150,
                    bornAt: now,
                    duration: 0.72,
                    colorPhase: frame.dominantPitch
                ))
                if matrixBeatRings.count > 6 { matrixBeatRings.removeFirst(matrixBeatRings.count - 6) }
            }
            matrixBeatRings.removeAll { now - $0.bornAt >= $0.duration }
        }

        invalidateCache()
    }

    func draw(in context: CGContext, now: TimeInterval, settings: EffectConfiguration, frame: MusicSpectrumFrame? = nil) {
        let activeFrame = frame ?? lastFrame
        let style = currentVisualStyle(for: settings, at: now)
        let colors = settings.colorParams
        let intensity = settings[.musicIntensity]
        let reactivity = settings[.musicReactivity]

        if settings.musicAutoCycle, let started = cycleStartedAt {
            let cycleLen = 18.0
            let posInCycle = fmod(max(0, now - started), cycleLen)
            let fadeDur = 1.6
            if posInCycle > cycleLen - fadeDur {
                let blend = (posInCycle - (cycleLen - fadeDur)) / fadeDur
                let nextStyle = advanceCycle(baseStyle: style)
                context.saveGState()
                context.setAlpha(CGFloat(1.0 - blend))
                drawStyle(style, frame: activeFrame, in: context, now: now, colors: colors, intensity: intensity, reactivity: reactivity)
                context.restoreGState()

                context.saveGState()
                context.setAlpha(CGFloat(blend))
                drawStyle(nextStyle, frame: activeFrame, in: context, now: now, colors: colors, intensity: intensity, reactivity: reactivity)
                context.restoreGState()
                return
            }
        }

        drawStyle(style, frame: activeFrame, in: context, now: now, colors: colors, intensity: intensity, reactivity: reactivity)
    }

    private func drawStyle(
        _ style: MusicVisualStyle,
        frame: MusicSpectrumFrame,
        in context: CGContext,
        now: TimeInterval,
        colors: EffectColorParams,
        intensity: Double,
        reactivity: Double
    ) {
        switch style {
        case .waterPool, .auroraRibbons, .ferrofluid, .plasmaNebula, .cymatics, .radialPulse, .audioFire, .lavaLamp:
            let img: CGImage?
            if let cachedImage, cachedStyle == style, cachedTime == animTime,
               cachedColorParams == colors, abs(cachedIntensity - intensity) < 1e-5 {
                img = cachedImage
            } else {
                img = shader.render(
                    style: style,
                    frame: frame,
                    time: animTime,
                    colors: colors,
                    intensity: intensity,
                    reactivity: reactivity
                )
                cachedImage = img
                cachedStyle = style
                cachedTime = animTime
                cachedColorParams = colors
                cachedIntensity = intensity
            }
            if let img {
                context.saveGState()
                context.setBlendMode(.plusLighter)
                context.draw(img, in: CGRect(origin: .zero, size: Action75.canvas))
                context.restoreGState()
            } else if style == .waterPool {
                // CPU fallback if Metal unavailable
                drawSpectrumBars(frame: frame, in: context, colors: colors, intensity: intensity)
            }

        case .spectrumBars:
            drawSpectrumBars(frame: frame, in: context, colors: colors, intensity: intensity)

        case .keyMatrixEQ:
            drawKeyMatrixEQ(frame: frame, in: context, now: now, colors: colors, intensity: intensity)

        case .oscilloscope:
            drawOscilloscope(frame: frame, in: context, colors: colors, intensity: intensity)

        case .starfieldWarp:
            drawStarfieldWarp(frame: frame, in: context, now: now, colors: colors, intensity: intensity)
        }
    }

    // MARK: - CoreGraphics Vector Visuals

    private func drawSpectrumBars(frame: MusicSpectrumFrame, in context: CGContext, colors: EffectColorParams, intensity: Double) {
        let count = MusicSpectrumFrame.bandCount
        let padX: CGFloat = 28
        let usableW = Action75.canvas.width - padX * 2
        let colW = usableW / CGFloat(count)
        let barW = colW * 0.72
        let floorY: CGFloat = 650
        let maxBarH: CGFloat = 560
        let segPitch: CGFloat = 22
        let segH: CGFloat = 15
        let gain = min(1.35, max(0.15, intensity))

        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.plusLighter)

        // Subtle beat-reactive baseline horizon
        let baseCol = colors.samplePalette(at: Float(fmod(animTime * 0.08, 1.0)))
        context.setFillColor(baseCol.withAlphaComponent(CGFloat(0.14 + 0.25 * Double(frame.beatPulse)) * gain).cgColor)
        context.fill(CGRect(x: padX, y: floorY + 2, width: usableW, height: 3))

        for i in 0..<count {
            let amp = CGFloat(min(1.0, frame.bands[i]))
            let peak = CGFloat(min(1.0, frame.peaks[i]))
            let x = padX + CGFloat(i) * colW + (colW - barW) * 0.5
            let barH = amp * maxBarH
            let segCount = max(1, Int(barH / segPitch))

            let bandT = Float(i) / Float(count - 1)
            for s in 0..<segCount {
                let segY = floorY - CGFloat(s + 1) * segPitch
                let heightFrac = Float(s) / Float(Int(maxBarH / segPitch))
                let col = colors.samplePalette(at: fmod(bandT * 0.75 + heightFrac * 0.35 + Float(animTime * 0.05), 1.0))
                let alpha = CGFloat(min(1.0, (0.55 + 0.45 * Double(amp)) * gain))
                let rect = CGRect(x: x, y: segY, width: barW, height: segH)
                let path = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
                context.setFillColor(col.withAlphaComponent(alpha).cgColor)
                context.addPath(path)
                context.fillPath()
            }

            // Mirror floor reflection
            if barH > 12 {
                let reflH = min(56, barH * 0.16)
                let reflRect = CGRect(x: x, y: floorY + 8, width: barW, height: reflH)
                let col = colors.samplePalette(at: fmod(bandT * 0.75 + Float(animTime * 0.05), 1.0))
                context.setFillColor(col.withAlphaComponent(CGFloat(0.22 * Double(amp) * gain)).cgColor)
                context.fill(reflRect)
            }

            // Floating peak-hold cap
            if peak > 0.04 {
                let peakY = floorY - peak * maxBarH - 6
                let capCol = colors.apply(to: NSColor.white.withAlphaComponent(CGFloat(0.88 * gain)))
                context.setFillColor(capCol.cgColor)
                let capRect = CGRect(x: x, y: peakY, width: barW, height: 5)
                let capPath = CGPath(roundedRect: capRect, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
                context.addPath(capPath)
                context.fillPath()
            }
        }
    }

    private func drawKeyMatrixEQ(
        frame: MusicSpectrumFrame,
        in context: CGContext,
        now: TimeInterval,
        colors: EffectColorParams,
        intensity: Double
    ) {
        let gain = min(1.35, max(0.15, intensity))
        let rowCount = CGFloat(Action75.rows.count)
        let center = CGPoint(x: Action75.canvas.width * 0.5, y: Action75.canvas.height * 0.5)

        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.plusLighter)

        for (code, rect) in Action75.rects {
            let tile = rect.insetBy(dx: 5, dy: 5)
            let normX = Float(max(0, min(0.999, rect.midX / Action75.canvas.width)))
            let bandIdx = min(31, Int(normX * 32.0))
            let amp = frame.bands[bandIdx]

            // Row 0 is top (F-row), row 5 is bottom (spacebar)
            let rowFromTop = Int((rect.midY / Action75.canvas.height) * rowCount)
            let rowFromBottom = Float(max(0, 5 - rowFromTop))
            let rowThreshold = rowFromBottom / 5.5
            let rowStrength = max(0, min(1, (amp - rowThreshold) * 3.2))

            // Beat shockwave ring modulation across physical keys
            var rippleBoost: Float = 0
            let distFromCenter = hypot(rect.midX - center.x, rect.midY - center.y)
            for ring in matrixBeatRings {
                let age = now - ring.bornAt
                guard age >= 0, age < ring.duration else { continue }
                let u = age / ring.duration
                let r = ring.radius + (ring.maxRadius - ring.radius) * CGFloat(1.0 - pow(1.0 - u, 2.0))
                let delta = abs(distFromCenter - r)
                if delta < 95 {
                    rippleBoost = max(rippleBoost, Float((1.0 - delta / 95.0) * (1.0 - u)) * 0.85)
                }
            }

            let lit = min(1.0, rowStrength + rippleBoost * 0.7 + frame.beatPulse * 0.18)
            guard lit > 0.02 || frame.energy > 0.06 else { continue }

            let colorPhase = fmod(normX * 0.8 + Float(rowFromBottom) * 0.08 + Float(animTime * 0.06), 1.0)
            let col = colors.samplePalette(at: colorPhase)
            let fillAlpha = CGFloat(min(0.92, (Double(lit) * 0.72 + Double(frame.energy) * 0.12) * gain))
            let strokeAlpha = CGFloat(min(1.0, (0.28 + Double(lit) * 0.72) * gain))

            let path = CGPath(roundedRect: tile, cornerWidth: 12, cornerHeight: 12, transform: nil)
            context.setFillColor(col.withAlphaComponent(fillAlpha).cgColor)
            context.addPath(path)
            context.fillPath()

            context.setStrokeColor(col.withAlphaComponent(strokeAlpha).cgColor)
            context.setLineWidth(2.5 + CGFloat(lit) * 2.5)
            context.addPath(path)
            context.strokePath()

            if lit > 0.35, let legend = Action75.legends[code], !legend.isEmpty {
                let textRect = CGRect(x: tile.minX, y: tile.midY - 15, width: tile.width, height: 32)
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                legend.draw(in: textRect, withAttributes: [
                    .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
                    .foregroundColor: NSColor(white: 1.0, alpha: min(1.0, CGFloat(lit) * 0.95)),
                    .paragraphStyle: style
                ])
            }
        }
    }

    private func drawOscilloscope(frame: MusicSpectrumFrame, in context: CGContext, colors: EffectColorParams, intensity: Double) {
        let w = Action75.canvas.width
        let h = Action75.canvas.height
        let midY = h * 0.5
        let gain = min(1.35, max(0.15, intensity))
        let samples = frame.waveform
        guard samples.count >= 2 else { return }

        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.plusLighter)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // Center harmonic Lissajous ring reacting to bass & beat
        let center = CGPoint(x: w * 0.5, y: midY)
        let ringBaseR: CGFloat = 115 + CGFloat(frame.beatPulse) * 58
        let ringPath = CGMutablePath()
        let ringSteps = 96
        for i in 0...ringSteps {
            let a = CGFloat(i) / CGFloat(ringSteps) * 2.0 * .pi
            let bandIdx = min(31, Int((abs(sin(a * 2.0))) * 31.0))
            let mod = CGFloat(frame.bands[bandIdx]) * 85.0 + CGFloat(sin(Double(a) * 5.0 + animTime * 4.0)) * CGFloat(frame.mids) * 24.0
            let r = ringBaseR + mod
            let pt = CGPoint(x: center.x + cos(a) * r * 1.45, y: center.y + sin(a) * r)
            if i == 0 { ringPath.move(to: pt) } else { ringPath.addLine(to: pt) }
        }
        ringPath.closeSubpath()
        let ringCol = colors.samplePalette(at: fmod(Float(animTime * 0.12) + 0.35, 1.0))
        context.setStrokeColor(ringCol.withAlphaComponent(CGFloat((0.28 + 0.55 * Double(frame.energy)) * gain)).cgColor)
        context.setLineWidth(4.5)
        context.addPath(ringPath)
        context.strokePath()

        // Main CRT waveform spline + mirrored echo trace
        let waveAmp: CGFloat = 245 * CGFloat(0.45 + 0.55 * min(1.4, Double(frame.level) + 0.35))
        func buildWavePath(scale: CGFloat, phaseOffset: CGFloat) -> CGMutablePath {
            let path = CGMutablePath()
            for i in 0..<samples.count {
                let u = CGFloat(i) / CGFloat(samples.count - 1)
                let x = u * w
                let env = sin(u * .pi)
                let y = midY + CGFloat(samples[i]) * waveAmp * scale * (0.35 + 0.65 * env) + phaseOffset
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            return path
        }

        let mainPath = buildWavePath(scale: 1.0, phaseOffset: 0)
        let echoPath = buildWavePath(scale: -0.55, phaseOffset: 0)

        let echoCol = colors.samplePalette(at: fmod(Float(animTime * 0.1) + 0.6, 1.0))
        context.setStrokeColor(echoCol.withAlphaComponent(CGFloat(0.32 * gain)).cgColor)
        context.setLineWidth(3.0)
        context.addPath(echoPath)
        context.strokePath()

        let glowCol = colors.samplePalette(at: fmod(Float(animTime * 0.1), 1.0))
        context.setStrokeColor(glowCol.withAlphaComponent(CGFloat(0.34 * gain)).cgColor)
        context.setLineWidth(14.0)
        context.addPath(mainPath)
        context.strokePath()

        context.setStrokeColor(glowCol.withAlphaComponent(CGFloat(0.85 * gain)).cgColor)
        context.setLineWidth(5.0)
        context.addPath(mainPath)
        context.strokePath()

        let coreCol = colors.apply(to: NSColor.white.withAlphaComponent(CGFloat(min(1.0, 0.92 * gain))))
        context.setStrokeColor(coreCol.cgColor)
        context.setLineWidth(2.0)
        context.addPath(mainPath)
        context.strokePath()
    }

    private func drawStarfieldWarp(
        frame: MusicSpectrumFrame,
        in context: CGContext,
        now: TimeInterval,
        colors: EffectColorParams,
        intensity: Double
    ) {
        let cx = Action75.canvas.width * 0.5
        let cy = Action75.canvas.height * 0.5
        let gain = min(1.35, max(0.15, intensity))

        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.plusLighter)
        context.setLineCap(.round)

        // Central warp core glow
        let coreR: CGFloat = 140 + CGFloat(frame.beatPulse) * 90
        let coreCol = colors.samplePalette(at: fmod(Float(animTime * 0.08), 1.0))
        context.setFillColor(coreCol.withAlphaComponent(CGFloat((0.10 + 0.24 * Double(frame.beatPulse)) * gain)).cgColor)
        context.fillEllipse(in: CGRect(x: cx - coreR, y: cy - coreR * 0.55, width: coreR * 2, height: coreR * 1.1))

        // Expanding beat rings
        for ring in warpRings {
            let age = now - ring.bornAt
            guard age >= 0, age < ring.duration else { continue }
            let u = age / ring.duration
            let r = ring.radius + (ring.maxRadius - ring.radius) * CGFloat(u * u * (1.6 - 0.6 * u))
            let alpha = CGFloat((1.0 - u) * 0.68 * gain)
            let col = colors.samplePalette(at: ring.colorPhase)
            context.setStrokeColor(col.withAlphaComponent(alpha).cgColor)
            context.setLineWidth(CGFloat(4.5 * (1.0 - 0.5 * u)))
            context.strokeEllipse(in: CGRect(x: cx - r, y: cy - r * 0.45, width: r * 2, height: r * 0.9))
        }

        // 3D perspective star streaks
        let projScaleX: CGFloat = 680
        let projScaleY: CGFloat = 340
        for star in stars {
            let z0 = max(0.03, CGFloat(star.z))
            let z1 = max(0.04, CGFloat(star.prevZ))
            let x0 = cx + CGFloat(star.x) / z0 * projScaleX
            let y0 = cy + CGFloat(star.y) / z0 * projScaleY
            let x1 = cx + CGFloat(star.x) / z1 * projScaleX
            let y1 = cy + CGFloat(star.y) / z1 * projScaleY
            guard x0 >= -40, x0 <= Action75.canvas.width + 40,
                  y0 >= -40, y0 <= Action75.canvas.height + 40 else { continue }

            let proximity = 1.0 - Double(star.z)
            let alpha = CGFloat(min(1.0, (0.25 + proximity * 0.85) * (0.45 + 0.55 * Double(frame.energy)) * gain))
            let col = colors.samplePalette(at: fmod(star.colorPhase + Float(animTime * 0.05), 1.0))
            context.setStrokeColor(col.withAlphaComponent(alpha).cgColor)
            context.setLineWidth(CGFloat(1.2 + proximity * 3.4 + Double(frame.hatPulse) * 1.4))
            context.move(to: CGPoint(x: x1, y: y1))
            context.addLine(to: CGPoint(x: x0, y: y0))
            context.strokePath()

            let headR = CGFloat(1.2 + proximity * 2.2)
            let tipCol = colors.apply(to: NSColor.white.withAlphaComponent(alpha))
            context.setFillColor(tipCol.cgColor)
            context.fillEllipse(in: CGRect(x: x0 - headR, y: y0 - headR, width: headR * 2, height: headR * 2))
        }
    }
}

/// Shared coordinator syncing MusicAudioEngine and MusicAmbientRenderer across both BoardView instances.
final class MusicAmbientController {
    static let shared = MusicAmbientController()

    let renderer = MusicAmbientRenderer()
    private var activeEnabled = false
    private var activeSource: MusicAudioSource?
    private var lastStepTime: TimeInterval = 0

    private init() {}

    func configure(settings: EffectConfiguration) {
        if settings.musicAmbient {
            if !activeEnabled || activeSource != settings.musicAudioSource {
                activeEnabled = true
                activeSource = settings.musicAudioSource
                lastStepTime = 0
                MusicAudioEngine.shared.start(source: settings.musicAudioSource)
            }
        } else if activeEnabled {
            stop()
        }
    }

    func stop() {
        activeEnabled = false
        activeSource = nil
        lastStepTime = 0
        MusicAudioEngine.shared.stop()
        renderer.reset()
    }

    func injectKeyImpulse(at boardPoint: CGPoint, strength: Double = 1.0) {
        guard activeEnabled else { return }
        renderer.injectKeyImpulse(at: boardPoint, strength: strength)
    }

    func draw(in context: CGContext, now: TimeInterval, settings: EffectConfiguration) {
        guard settings.musicAmbient else { return }
        configure(settings: settings)
        let dt = lastStepTime > 0 ? now - lastStepTime : (1.0 / 60.0)
        if lastStepTime == 0 || dt >= 1.0 / 90.0 {
            lastStepTime = now
            let frame = MusicAudioEngine.shared.sampleFrame(
                at: now,
                sensitivity: settings[.musicSensitivity],
                reactivity: settings[.musicReactivity]
            )
            renderer.step(frame: frame, dt: dt, now: now, settings: settings)
        }
        renderer.draw(in: context, now: now, settings: settings)
    }
}

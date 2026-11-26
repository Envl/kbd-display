import AppKit
import Metal

struct KeyPressHistory {
    private var lastCenter: CGPoint?
    private var lastRepeat: TimeInterval?
    private var heat = 0.0

    mutating func record(key: CGRect, sparks: [BeamSpark], at now: TimeInterval, tapsToFullHeat: Double = 5) -> KeyBeam {
        let center = CGPoint(x: key.midX, y: key.midY)
        if center == lastCenter {
            if let lastRepeat {
                let interval = max(0, now - lastRepeat)
                // Taps at 220 ms or faster get the full increment. Wider
                // spacing both adds less heat and lets the existing heat dissipate.
                let kick = min(1, max(0, (0.70 - interval) / 0.48)) / tapsToFullHeat
                let cooling = max(0, interval - 0.22) / 0.72
                heat = min(1, max(0, heat - cooling) + kick)
            }
            lastRepeat = now
        } else {
            heat = 0
            lastRepeat = nil
        }
        let beam = KeyBeam(previous: lastCenter, key: key, sparks: sparks, flameHeat: heat)
        lastCenter = center
        return beam
    }
}

/// The endpoints and heading are in the Action75's native board coordinates.
struct KeyBeam {
    let start: CGPoint
    let end: CGPoint
    let heading: CGFloat
    let length: CGFloat
    let keyFrame: CGRect
    let sparks: [BeamSpark]

    let flameHeat: Double
    var randomSingleKeyEffect: SingleKeyEffect?
    var suppressesKeyFlash = false

    fileprivate init(previous: CGPoint?, key: CGRect, sparks: [BeamSpark], flameHeat: Double) {
        self.flameHeat = flameHeat
        self.sparks = sparks
        keyFrame = key
        let target = CGPoint(x: key.midX, y: key.midY)
        end = target
        start = previous ?? CGPoint(x: end.x - 96, y: end.y)
        heading = atan2(end.y - start.y, end.x - start.x)
        length = hypot(end.x - start.x, end.y - start.y)
    }
}

/// Sample once on key-down so a particle keeps the same trajectory across frames.
struct BeamSpark {
    let birth: Double
    let reach: Double
    let lane: Double
    let width: CGFloat
    let tint: NSColor

    static func burst(density: Double = 1) -> [BeamSpark] {
        let count = Int((Double(Int.random(in: 20...28)) * density).rounded())
        return (0..<count).map { i in
            // Stagger births along the original sweep, with independent lanes and sizes.
            let phase = (Double(i) + Double.random(in: 0..<1)) / Double(count)
            let size = Double.random(in: 0..<1)
            let color = Double.random(in: 0..<1)
            return BeamSpark(birth: 0.05 + phase * 0.245, reach: Double.random(in: 0...1),
                             lane: Double.random(in: -0.5...0.5), width: 3.8 + 7.2 * size * size,
                             tint: color < 0.4 ? .systemCyan : (color < 0.65 ? .white : .systemYellow))
        }
    }
}

final class BlastEffect {
    static let shared = BlastEffect()
    static let duration: TimeInterval = 0.80
    private static let frameCount = 49
    private static let sweepFraction = 1.1 / 1.7
    private var frames: [CGImage] = []
    private var flameFrames: [CGImage] = []
    private var plasmaOrbFrames: [CGImage] = []
    private var plasmaWakeFrames: [CGImage] = []
    private var plasmaFlameColdFrames: [CGImage] = []
    private var plasmaFlameHotFrames: [CGImage] = []
    private var requestedColors = EffectColorParams()
    private let bakeQueue = DispatchQueue(label: "com.kbd-display.shader-bake", qos: .userInteractive)

    private init() {
        scheduleBake(for: EffectColorParams())
    }

    private func ensureFrames(for colors: EffectColorParams) {
        guard colors != requestedColors else { return }
        requestedColors = colors
        scheduleBake(for: colors)
    }

    private func scheduleBake(for colors: EffectColorParams) {
        bakeQueue.async { [weak self] in
            let orb = Self.makeFrames(effect: .orb, colors: colors)
            let flame = Self.makeFrames(effect: .flame, colors: colors)
            let pOrb = Self.makeFrames(effect: .plasmaOrb, colors: colors)
            let pWake = Self.makeFrames(effect: .plasmaWake, colors: colors)
            let pCold = Self.makeFrames(effect: .plasmaFlameCold, colors: colors)
            let pHot = Self.makeFrames(effect: .plasmaFlameHot, colors: colors)
            DispatchQueue.main.async {
                guard let self, self.requestedColors == colors else { return }
                self.frames = orb
                self.flameFrames = flame
                self.plasmaOrbFrames = pOrb
                self.plasmaWakeFrames = pWake
                self.plasmaFlameColdFrames = pCold
                self.plasmaFlameHotFrames = pHot
            }
        }
    }

    func draw(_ hits: [(beam: KeyBeam, age: TimeInterval)], settings: EffectConfiguration = EffectConfiguration()) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let blade = settings[.glow] ? settings.travelBlade : nil
        var layers = settings
        if blade != nil { layers[.glow] = false }
        if settings.style == .liquidSDF {
            LiveBoardShader.shared.draw(hits: hits, in: context, settings: layers)
        } else {
            for (beam, age) in hits where age >= 0 && age < Self.duration {
                drawBaked(beam, age: age, in: context, settings: layers)
            }
        }
        if let blade {
            for (beam, age) in hits.suffix(16) where beam.length > 0 && age >= 0 && age < Self.duration {
                let seed: UInt64 = (beam.sparks.first?.lane ?? 0) < 0 ? 1 : 0
                BladeTrailRenderer.draw(blade, from: beam.start, to: beam.end,
                                        thickness: 17 * settings[.glowSize], elapsed: age,
                                        opacity: min(1, settings[.intensity]), seed: seed, in: context)
            }
        }
    }

    func draw(_ beam: KeyBeam, age: TimeInterval, settings: EffectConfiguration = EffectConfiguration()) {
        draw([(beam, age)], settings: settings)
    }

    private func drawBaked(_ beam: KeyBeam, age: TimeInterval, in context: CGContext, settings: EffectConfiguration) {
        let colors = settings.colorParams
        ensureFrames(for: colors)
        if settings.style == .plasma {
            drawPlasma(beam, age: age, in: context, settings: settings, colors: colors)
            return
        }
        let t = age / Self.duration
        if settings[.border] && !beam.suppressesKeyFlash {
            Self.drawKeyFlash(in: context, key: beam.keyFrame, age: age, brightness: settings[.borderBrightness], colors: colors)
        }
        if settings.shows(.fire, for: beam) {
            let frame = flameFrames.isEmpty ? nil : flameFrames[Int((t * Double(flameFrames.count - 1)).rounded())]
            FlamePlume.draw(in: context, key: beam.keyFrame, sparks: beam.sparks, heat: beam.flameHeat,
                            time: t, frame: frame, settings: settings)
        }
        SingleKeyEffects.drawVectors(for: beam, in: context, time: t, settings: settings)
        if beam.length == 0 { return }
        let timing = Self.timing(at: t)
        let diameter = min(330, 230 + beam.length * 0.08) * settings[.glowSize]
        let centerX = beam.length * CGFloat(timing.x)
        let rect = CGRect(x: centerX - diameter/2, y: -diameter/2, width: diameter, height: diameter)

        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: beam.start.x, y: beam.start.y)
        context.rotate(by: beam.heading)
        if settings[.glow] {
            Self.drawWake(in: context, length: centerX, height: diameter, time: t, colors: colors)
            if !frames.isEmpty {
                let index = Int((t * Double(frames.count - 1)).rounded())
                context.draw(frames[index], in: rect)
            } else {
                Self.drawFallbackOrb(in: context, rect: rect, diameter: diameter, alpha: CGFloat(timing.y), colors: colors)
            }
        }
        if settings[.particles] {
            Self.drawSparks(beam.sparks, in: context, distance: beam.length, height: diameter,
                            time: t, size: settings[.particleSize], colors: colors)
        }
    }

    private func drawPlasma(_ beam: KeyBeam, age: TimeInterval, in context: CGContext,
                            settings: EffectConfiguration, colors: EffectColorParams) {
        let t = age / Self.duration
        let timing = Self.timing(at: t)
        let arc = Self.arcGeometry(for: beam, progress: CGFloat(timing.x))

        if settings[.border] {
            if !beam.suppressesKeyFlash {
                Self.drawPlasmaKeyFlash(in: context, key: beam.keyFrame, age: age,
                                       brightness: settings[.borderBrightness], colors: colors)
            }
            Self.drawProximitySpill(in: context, beam: beam, orbPoint: arc.worldPoint,
                                    progress: Double(timing.x), alpha: Double(timing.y),
                                    age: age, brightness: settings[.borderBrightness], colors: colors)
        }
        if settings.shows(.fire, for: beam) {
            let idx = Int((t * Double(Self.frameCount - 1)).rounded())
            let cold = plasmaFlameColdFrames.isEmpty
                ? (flameFrames.isEmpty ? nil : flameFrames[idx])
                : plasmaFlameColdFrames[idx]
            let hot = plasmaFlameHotFrames.isEmpty ? nil : plasmaFlameHotFrames[idx]
            FlamePlume.draw(in: context, key: beam.keyFrame, sparks: beam.sparks, heat: beam.flameHeat,
                            time: t, frame: cold, hotFrame: hot, settings: settings)
        }
        SingleKeyEffects.drawVectors(for: beam, in: context, time: t, settings: settings)
        if beam.length == 0 { return }

        let diameter = min(345, 240 + beam.length * 0.085) * settings[.glowSize]
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: beam.start.x, y: beam.start.y)
        context.rotate(by: beam.heading)

        if settings[.glow] {
            let index = Int((t * Double(Self.frameCount - 1)).rounded())
            let wakeFrame = plasmaWakeFrames.isEmpty ? nil : plasmaWakeFrames[index]
            Self.drawPlasmaWake(in: context, localOrb: arc.localPoint, localAngle: arc.localAngle,
                                height: diameter, time: t, frame: wakeFrame, colors: colors)

            context.saveGState()
            context.setBlendMode(.plusLighter)
            context.translateBy(x: arc.localPoint.x, y: arc.localPoint.y)
            context.rotate(by: arc.localAngle)
            let orbRect = CGRect(x: -diameter / 2, y: -diameter / 2, width: diameter, height: diameter)
            let orbSource = !plasmaOrbFrames.isEmpty ? plasmaOrbFrames : frames
            if !orbSource.isEmpty {
                context.draw(orbSource[index], in: orbRect)
            } else {
                Self.drawFallbackOrb(in: context, rect: orbRect, diameter: diameter, alpha: CGFloat(timing.y), colors: colors)
            }
            context.restoreGState()
        }
        if settings[.particles] {
            Self.drawPlasmaSparks(beam.sparks, in: context, beam: beam, height: diameter,
                                  time: t, size: settings[.particleSize], colors: colors)
        }
    }

    private static func drawFallbackOrb(in context: CGContext, rect: CGRect, diameter: CGFloat,
                                        alpha: CGFloat, colors: EffectColorParams = EffectColorParams()) {
        context.saveGState()
        context.setAlpha(alpha * CGFloat(min(1.35, 0.35 + 0.65 * colors.intensity)))
        context.clip(to: rect)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        let grad = NSGradient(colors: [
            colors.samplePalette(at: 0.0).withAlphaComponent(0),
            colors.samplePalette(at: 0.25).withAlphaComponent(0.24),
            colors.apply(to: .white),
            colors.samplePalette(at: 0.75).withAlphaComponent(0.3),
            colors.samplePalette(at: 1.0).withAlphaComponent(0)
        ]) ?? Self.fallback
        grad?.draw(from: CGPoint(x: rect.minX, y: 0), to: CGPoint(x: rect.maxX, y: 0), options: [])
        context.setBlendMode(.destinationIn)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        Self.roundMask?.draw(fromCenter: center, radius: 0, toCenter: center, radius: diameter/2,
                             options: .drawsAfterEndingLocation)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    struct ArcGeometry {
        let localPoint: CGPoint
        let localAngle: CGFloat
        let maxArc: CGFloat
        let worldPoint: CGPoint
        let worldControl: CGPoint
    }

    static func arcGeometry(for beam: KeyBeam, progress u: CGFloat) -> ArcGeometry {
        guard beam.length > 0 else {
            return ArcGeometry(localPoint: .zero, localAngle: 0, maxArc: 0,
                               worldPoint: beam.end, worldControl: beam.end)
        }
        let lane = CGFloat(beam.sparks.first?.lane ?? 0.18)
        let sign: CGFloat = lane >= 0 ? 1 : -1
        let maxArc = min(56, beam.length * 0.13) * sign * (0.55 + 0.9 * abs(lane))
        let localX = beam.length * u
        let localY = 4 * maxArc * u * (1 - u)
        let localAngle = atan2(4 * maxArc * (1 - 2 * u), max(1, beam.length))
        let cosH = cos(beam.heading), sinH = sin(beam.heading)
        let worldPoint = CGPoint(x: beam.start.x + localX * cosH - localY * sinH,
                                 y: beam.start.y + localX * sinH + localY * cosH)
        let ctrlLocalX = beam.length * 0.5
        let ctrlLocalY = 2 * maxArc
        let worldControl = CGPoint(x: beam.start.x + ctrlLocalX * cosH - ctrlLocalY * sinH,
                                   y: beam.start.y + ctrlLocalX * sinH + ctrlLocalY * cosH)
        return ArcGeometry(localPoint: CGPoint(x: localX, y: localY), localAngle: localAngle,
                           maxArc: maxArc, worldPoint: worldPoint, worldControl: worldControl)
    }

    static func drawHeldKeyOutline(in context: CGContext, key: CGRect, age: Double, brightness: Double,
                                   colors: EffectColorParams) {
        let pulse = pow(max(0, 1 - max(0, age) / 0.22), 2)
        let stroke = colors.apply(to: NSColor(srgbRed: 0.86, green: 0.91, blue: 1, alpha: 1))
        let halo = colors.apply(to: NSColor(srgbRed: 0.42, green: 0.68, blue: 1, alpha: 0.80))
        let path = CGPath(roundedRect: key.insetBy(dx: 7, dy: 7), cornerWidth: 12, cornerHeight: 12, transform: nil)
        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.plusLighter)
        context.setAlpha(brightness)
        context.setShadow(offset: .zero, blur: 5 + 10 * pulse, color: halo.cgColor)
        context.setStrokeColor(stroke.cgColor)
        context.setLineWidth(2.5 + 6.5 * pulse)
        context.addPath(path)
        context.strokePath()
    }

    // The destination responds to a tap, then catches a softer glint as the orb arrives.
    static func drawKeyFlash(in context: CGContext, key: CGRect, age: Double, brightness: Double = 1,
                             colors: EffectColorParams = EffectColorParams()) {
        guard age >= 0, age < 0.62 else { return }
        let contact = pow(max(0, 1 - age / 0.34), 2)
        let arrival = 0.6 * pow(max(0, 1 - abs(age - 0.32) / 0.23), 2)
        let light = max(contact, arrival)
        let inset = 5 + 3 * contact
        let cap = CGPath(roundedRect: key.insetBy(dx: inset, dy: inset), cornerWidth: 12, cornerHeight: 12, transform: nil)
        let shadowColor = colors.apply(to: NSColor(srgbRed: 0.64, green: 0.76, blue: 1, alpha: 0.9))
        let strokeColor = colors.apply(to: NSColor(srgbRed: 0.86, green: 0.91, blue: 1, alpha: 0.80))
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(light * brightness)
        context.setShadow(offset: .zero, blur: 8, color: shadowColor.cgColor)
        context.setStrokeColor(strokeColor.cgColor)
        context.setLineWidth(1.5 + 2 * contact)
        context.addPath(cap)
        context.strokePath()
    }

    static func drawPlasmaKeyFlash(in context: CGContext, key: CGRect, age: Double, brightness: Double = 1,
                                   colors: EffectColorParams = EffectColorParams()) {
        guard age >= 0, age < 0.66 else { return }
        let contact = pow(max(0, 1 - age / 0.35), 2)
        let arrival = 0.75 * pow(max(0, 1 - abs(age - 0.32) / 0.24), 2)
        let light = max(contact, arrival) * brightness
        let inset = 5 + 2.5 * contact
        let capRect = key.insetBy(dx: inset, dy: inset)
        let cap = CGPath(roundedRect: capRect, cornerWidth: 12, cornerHeight: 12, transform: nil)

        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.plusLighter)

        // Chromatic outer bloom + crisp inner rim
        context.setAlpha(light)
        let hueShift = min(1, max(0, (age - 0.12) / 0.38))
        let outerColor = colors.apply(to: NSColor(srgbRed: 0.28 + 0.65 * hueShift, green: 0.78 - 0.25 * hueShift,
                                                  blue: 1.0, alpha: 0.85))
        let strokeColor = colors.apply(to: NSColor(srgbRed: 0.88, green: 0.95, blue: 1, alpha: 0.92))
        context.setShadow(offset: .zero, blur: 13, color: outerColor.cgColor)
        context.setStrokeColor(strokeColor.cgColor)
        context.setLineWidth(1.8 + 2.4 * contact)
        context.addPath(cap)
        context.strokePath()

        // Expanding arrival shockwave ring outside the key border
        if age > 0.20, age < 0.60 {
            let shockT = (age - 0.20) / 0.40
            let expand = 3 + 16 * (1 - pow(1 - shockT, 2))
            let shockAlpha = (1 - shockT) * (1 - shockT) * 0.62 * brightness
            let shockRect = key.insetBy(dx: 5 - expand, dy: 5 - expand)
            let shockPath = CGPath(roundedRect: shockRect, cornerWidth: 12 + expand * 0.6,
                                   cornerHeight: 12 + expand * 0.6, transform: nil)
            let shockShadow = colors.apply(to: NSColor(srgbRed: 0.45, green: 0.88, blue: 1, alpha: 0.8))
            let shockStroke = colors.apply(to: NSColor(srgbRed: 0.65, green: 0.92, blue: 1, alpha: 0.75))
            context.setAlpha(shockAlpha)
            context.setShadow(offset: .zero, blur: 10, color: shockShadow.cgColor)
            context.setStrokeColor(shockStroke.cgColor)
            context.setLineWidth(1.4 * (1 - 0.5 * shockT))
            context.addPath(shockPath)
            context.strokePath()
        }
    }

    // Illuminates neighboring keycap borders as the orb travels past them or erupts into a hot flame.
    private static func drawProximitySpill(in context: CGContext, beam: KeyBeam, orbPoint: CGPoint,
                                           progress: Double, alpha: Double, age: Double, brightness: Double,
                                           colors: EffectColorParams) {
        guard alpha > 0.02, brightness > 0.01 else { return }
        let isRepeat = beam.length == 0
        let lightOrigin = isRepeat ? beam.end : orbPoint
        let maxDist: CGFloat = isRepeat ? (200 + 110 * beam.flameHeat) : 230
        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.plusLighter)

        for frame in Action75.rects.values {
            if abs(frame.midX - beam.keyFrame.midX) < 2 && abs(frame.midY - beam.keyFrame.midY) < 2 { continue }
            let dx = frame.midX - lightOrigin.x
            let dy = frame.midY - lightOrigin.y
            let dist = hypot(dx, dy)
            guard dist < maxDist else { continue }
            let falloff = pow(1 - dist / maxDist, 2.1)
            let intensity = Double(falloff) * alpha * brightness * (isRepeat ? (0.28 + 0.52 * beam.flameHeat) : 0.54)
            guard intensity > 0.015 else { continue }

            let tile = frame.insetBy(dx: 5.5, dy: 5.5)
            let path = CGPath(roundedRect: tile, cornerWidth: 12, cornerHeight: 12, transform: nil)
            let rawColor: NSColor
            if isRepeat {
                let b = min(1, 0.16 + 0.84 * beam.flameHeat)
                rawColor = NSColor(srgbRed: 1 - 0.45 * beam.flameHeat, green: 0.42 + 0.36 * beam.flameHeat,
                                   blue: b, alpha: intensity)
            } else {
                let phase = Float(progress + Double(dist / maxDist) * 0.35)
                rawColor = colors.samplePalette(at: phase).withAlphaComponent(intensity)
            }
            let color = isRepeat ? colors.apply(to: rawColor) : rawColor
            context.setShadow(offset: .zero, blur: 9, color: color.cgColor)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(1.3 + 1.2 * falloff)
            context.addPath(path)
            context.strokePath()
        }
    }

    // A translucent ribbon connects the crossed keys while the brighter crest advances.
    private static let wake = NSGradient(colors: [
        NSColor.systemBlue.withAlphaComponent(0), NSColor.systemBlue,
        NSColor.systemCyan, NSColor.white, NSColor.systemOrange.withAlphaComponent(0)
    ])

    private static func drawWake(in context: CGContext, length: CGFloat, height: CGFloat, time: Double,
                                 colors: EffectColorParams = EffectColorParams()) {
        guard length > 1, time < 0.8 else { return }
        let fade = min(1, (0.8 - time) / 0.52)
        let halfHeight = height * 0.22
        let wakeGrad = NSGradient(colors: [
            colors.samplePalette(at: 0.05).withAlphaComponent(0),
            colors.samplePalette(at: 0.22),
            colors.samplePalette(at: 0.45),
            colors.apply(to: .white),
            colors.samplePalette(at: 0.85).withAlphaComponent(0)
        ]) ?? wake
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: CGRect(x: 0, y: -halfHeight, width: length, height: 2 * halfHeight))
        context.setAlpha(0.38 * fade * fade * min(1, length / 180) * Double(min(1.35, 0.35 + 0.65 * colors.intensity)))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        wakeGrad?.draw(from: .zero, to: CGPoint(x: length, y: 0), options: [])
        context.setBlendMode(.destinationIn)
        feather?.draw(from: CGPoint(x: 0, y: -halfHeight), to: CGPoint(x: 0, y: halfHeight), options: [])
        context.endTransparencyLayer()
    }

    private static func drawPlasmaWake(in context: CGContext, localOrb: CGPoint, localAngle: CGFloat,
                                       height: CGFloat, time: Double, frame: CGImage?,
                                       colors: EffectColorParams = EffectColorParams()) {
        let chord = hypot(localOrb.x, localOrb.y)
        guard chord > 2, time < 0.86 else { return }
        let fade = min(1, (0.86 - time) / 0.54)
        let halfHeight = height * 0.28
        let chordAngle = atan2(localOrb.y, localOrb.x)

        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.plusLighter)
        context.rotate(by: chordAngle)
        let rect = CGRect(x: 0, y: -halfHeight, width: chord, height: 2 * halfHeight)
        if let frame {
            context.setAlpha(0.88 * fade * min(1, chord / 140))
            context.draw(frame, in: rect)
        } else {
            drawWake(in: context, length: chord, height: height, time: time, colors: colors)
        }
    }

    private static let fallback = NSGradient(colors: [
        NSColor.systemBlue.withAlphaComponent(0), NSColor.systemCyan.withAlphaComponent(0.24),
        .white, NSColor.systemOrange.withAlphaComponent(0.3), NSColor.systemOrange.withAlphaComponent(0)
    ])
    private static let roundMask = NSGradient(colors: [NSColor.white, .white, .clear])
    private static let feather = NSGradient(colors: [NSColor.clear, .white, .clear])

    // Same easeOutQuart traversal and cubic outro as Glimm's playSweep,
    // compressed from the homepage's 1100:600 ms phases to one keyboard hit.
    static func timing(at t: Double) -> SIMD2<Float> {
        let travel = min(1, t / sweepFraction)
        let outro = max(0, (t - sweepFraction) / (1 - sweepFraction))
        let fade = outro < 0.5 ? 4 * pow(outro, 3) : 1 - pow(2 - 2*outro, 3)/2
        return SIMD2(Float(1 - pow(1 - travel, 4)), Float(0.95 * (1 - fade)))
    }

    private static func drawSparks(_ sparks: [BeamSpark], in context: CGContext, distance: CGFloat, height: CGFloat,
                                   time: Double, size: CGFloat, colors: EffectColorParams = EffectColorParams()) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        for spark in sparks {
            let age = (time - spark.birth) / (0.40 + spark.reach * 0.29)
            guard age > 0, age < 1 else { continue }
            let originX = distance * CGFloat(timing(at: spark.birth).x)
            func point(_ age: Double) -> CGPoint {
                let coast = 1 - pow(1 - max(0, age), 2.6)
                return CGPoint(x: originX + (18 + 48 * spark.reach) * coast,
                               y: spark.lane * (height * 0.48 + 46 * coast) + 6 * age * age)
            }
            let alpha = min(1, age * 12) * (1 - age) * (1 - age)
            let color = colors.apply(to: spark.tint.withAlphaComponent(alpha))
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(size * spark.width * (1 - 0.35 * age))
            context.move(to: point(age - 0.085))
            context.addLine(to: point(age))
            context.strokePath()
        }
    }

    static func drawPlasmaSparks(_ sparks: [BeamSpark], in context: CGContext, beam: KeyBeam,
                                 height: CGFloat, time: Double, size: CGFloat,
                                 colors: EffectColorParams = EffectColorParams()) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.plusLighter)
        context.setLineCap(.round)
        for spark in sparks {
            let age = (time - spark.birth) / (0.44 + spark.reach * 0.32)
            guard age > 0, age < 1 else { continue }
            let birthProgress = CGFloat(timing(at: spark.birth).x)
            let birthArc = arcGeometry(for: beam, progress: birthProgress)
            let phase = spark.reach * 6.28318 + spark.lane * 4.0

            func point(_ a: Double) -> CGPoint {
                let clamped = max(0, a)
                let coast = 1 - pow(1 - clamped, 2.5)
                let curlX = cos(clamped * 8.5 + phase) * 11 * clamped * spark.reach
                let curlY = sin(clamped * 8.5 + phase) * 15 * clamped
                return CGPoint(
                    x: birthArc.localPoint.x + (22 + 56 * spark.reach) * coast + curlX,
                    y: birthArc.localPoint.y + spark.lane * (height * 0.48 + 52 * coast) + curlY
                )
            }

            let alpha = min(1, age * 12) * (1 - age) * (1 - age)
            let p0 = point(age - 0.095)
            let pMid = point(age - 0.045)
            let p1 = point(age)
            let lineW = size * spark.width * (1 - 0.38 * age)
            let tinted = colors.apply(to: spark.tint)

            let path = CGMutablePath()
            path.move(to: p0)
            path.addQuadCurve(to: p1, control: pMid)

            // Outer bloom halo
            context.setStrokeColor(tinted.withAlphaComponent(alpha * 0.38).cgColor)
            context.setLineWidth(lineW * 2.25)
            context.addPath(path)
            context.strokePath()

            // Crisp plasma streak
            context.setStrokeColor(tinted.withAlphaComponent(alpha * 0.95).cgColor)
            context.setLineWidth(lineW * 0.92)
            context.addPath(path)
            context.strokePath()

            // White-hot leading ember head
            let headR = max(1.4, lineW * 0.65)
            let headColor = colors.apply(to: NSColor.white.withAlphaComponent(alpha * 0.92))
            context.setFillColor(headColor.cgColor)
            context.fillEllipse(in: CGRect(x: p1.x - headR, y: p1.y - headR, width: headR * 2, height: headR * 2))
        }
    }

    enum Effect { case orb, flame, plasmaOrb, plasmaWake, plasmaFlameCold, plasmaFlameHot }

    static func makeFrames(effect: Effect = .orb, colors: EffectColorParams = EffectColorParams()) -> [CGImage] {
        let side: Int
        let source: String
        let functionName: String
        switch effect {
        case .orb:
            side = 160; source = shader; functionName = "blast"
        case .flame:
            side = 224; source = FlamePlume.shader; functionName = "flame"
        case .plasmaOrb:
            side = 192; source = shader; functionName = "plasmaOrb"
        case .plasmaWake:
            side = 192; source = shader; functionName = "plasmaWake"
        case .plasmaFlameCold:
            side = 224; source = FlamePlume.shader; functionName = "plasmaFlameCold"
        case .plasmaFlameHot:
            side = 224; source = FlamePlume.shader; functionName = "plasmaFlameHot"
        }
        let count = frameCount
        let stride = side * side * 4
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: source, options: nil),
              let function = library.makeFunction(name: functionName),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let pixels = device.makeBuffer(length: stride * count, options: .storageModeShared),
              let command = queue.makeCommandBuffer()
        else { return [] }
        var dimensions = SIMD2<UInt32>(UInt32(side), UInt32(count))
        let timing = (0..<count).map { Self.timing(at: Double($0) / Double(count - 1)) }
        let colorVecs = [colors.palA, colors.palB, colors.palD]
        guard let encoder = command.makeComputeCommandEncoder() else { return [] }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(pixels, offset: 0, index: 0)
        encoder.setBytes(&dimensions, length: MemoryLayout.size(ofValue: dimensions), index: 1)
        encoder.setBytes(timing, length: timing.count * MemoryLayout<SIMD2<Float>>.stride, index: 2)
        encoder.setBytes(colorVecs, length: colorVecs.count * MemoryLayout<SIMD4<Float>>.stride, index: 3)
        encoder.dispatchThreads(MTLSize(width: side, height: side, depth: count),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return [] }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return (0..<count).compactMap { index in
            let data = Data(bytes: pixels.contents().advanced(by: index * stride), count: stride)
            guard let provider = CGDataProvider(data: data as CFData) else { return nil }
            return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: side * 4, space: space,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }

    // Native adaptation of glimm 0.3.0 (MIT, see Licenses/Glimm.txt).
    // Coefficients are accentChain(["#0000ff","#00ffff","#ffffff","#ffff00","#ff0000"])
    // evaluated by the pinned library, as configured by Shell Click's GlimmSweep.svelte.
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    float3 foilPalette(float t, constant float4 *colorParams) {
        float3 a = colorParams[0].xyz;
        float3 b = colorParams[1].xyz;
        float3 d = colorParams[2].xyz;
        return a + b*cos(2.0*M_PI_F*(0.5*t+d));
    }

    float3 chromaticFoil(float hue, float dispersion, constant float4 *colorParams) {
        float3 r = foilPalette(hue - dispersion, colorParams);
        float3 g = foilPalette(hue, colorParams);
        float3 b = foilPalette(hue + dispersion, colorParams);
        return float3(r.r, g.g, b.b);
    }

    float3 gradeColor(float3 rgb, constant float4 *colorParams) {
        float hueShift = colorParams[0].w;
        float chroma = colorParams[1].w;
        float intensity = colorParams[2].w;
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
        return max(float3(0.0), c * intensity);
    }

    float hashCell(float2 p) {
        float3 q = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
        q += dot(q, q.yzx + 33.33);
        return fract((q.x + q.y) * q.z);
    }

    float vnoise(float2 p) {
        float2 i = floor(p), f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        return mix(mix(hashCell(i), hashCell(i + float2(1, 0)), f.x),
                   mix(hashCell(i + float2(0, 1)), hashCell(i + 1.0), f.x), f.y);
    }

    float fbm(float2 p) {
        return 0.54 * vnoise(p) + 0.31 * vnoise(p * 2.17 + 6.4) + 0.15 * vnoise(p * 4.35 + 15.8);
    }

    kernel void blast(device uchar4 *pixels [[buffer(0)]], constant uint2 &size [[buffer(1)]],
                      constant float2 *timing [[buffer(2)]], constant float4 *colorParams [[buffer(3)]],
                      uint3 id [[thread_position_in_grid]]) {
        float2 uv = (float2(id.xy)+0.5)/float(size.x);
        float across = uv.y;
        float progress = timing[id.z].x, alpha = timing[id.z].y;
        float seconds = float(id.z)/float(size.y-1) * 0.8;
        float tw = seconds * 0.9;
        // Bake the light around a stationary crest. Board-space travel is applied at draw time.
        float axis = progress + (uv.x-0.5)*0.85;
        float2 p = (uv - 0.5) * 2.0;
        float radius = length(p);
        float roundness = sqrt(saturate(1.0 - dot(p,p)));
        float3 normal = normalize(float3(p * 0.70, max(0.01, roundness)));
        float focus = 4.0*progress*(1.0-progress);
        float haze = 1.0 - smoothstep(0.0, 1.0, radius);
        float body = mix(haze, 1.0 - smoothstep(0.52, 0.86, radius), 0.56);
        float opacity = alpha * mix(0.30, 1.0, focus);

        float ripple = 0.015*0.75*sin(across*12.0+axis*3.0+tw*0.40);
        float hue = normal.x*0.12 + axis*0.90 + across*0.16 + ripple + seconds*0.04;
        float3 foil = 0.84*(0.5*foilPalette(hue, colorParams)
                    + 0.25*(foilPalette(hue-0.18, colorParams)+foilPalette(hue+0.18, colorParams)));
        float3 halfVector = normalize(normalize(float3(0.35,0.55,0.9))+float3(0,0,1));
        float gloss = pow(saturate(dot(normal,halfVector)),80.0);
        float fresnel = pow(1.0-normal.z,3.0);
        float highlight = body*opacity*0.8;
        float intensity = colorParams[2].w;
        float alphaGain = abs(intensity - 1.0) < 1e-4 ? 1.0 : min(1.35, 0.35 + 0.65 * intensity);
        float a = saturate(body*opacity*alphaGain);
        float3 rgb = gradeColor(foil*body*opacity + (foil*fresnel*0.55+gloss*1.1)*highlight, colorParams);
        // CGImage's premultiplied format requires every color component <= alpha.
        pixels[(id.z*size.x+id.y)*size.x+id.x] = uchar4(float4(clamp(rgb,0.0,a),a)*255.0+0.5);
    }

    kernel void plasmaOrb(device uchar4 *pixels [[buffer(0)]], constant uint2 &size [[buffer(1)]],
                          constant float2 *timing [[buffer(2)]], constant float4 *colorParams [[buffer(3)]],
                          uint3 id [[thread_position_in_grid]]) {
        float2 uv = (float2(id.xy) + 0.5) / float(size.x);
        float t = float(id.z) / float(size.y - 1);
        float progress = timing[id.z].x, alpha = timing[id.z].y;
        float2 p = (uv - 0.5) * 2.0;
        float radius = length(p);

        // Domain-warped caustic normal perturbation inside the plasma sphere
        float2 flow = p * 2.4 + float2(-t * 4.8, sin(t * 5.0) * 0.6);
        float warp1 = fbm(flow);
        float warp2 = fbm(flow * 1.9 + float2(warp1 * 2.2, t * 3.2));
        float caustic = pow(1.0 - abs(2.0 * warp2 - 1.0), 3.0);

        float roundness = sqrt(saturate(1.0 - dot(p, p)));
        float2 warpedP = p * 0.72 + (float2(warp1, warp2) - 0.5) * 0.28 * saturate(1.0 - radius * 0.5);
        float3 normal = normalize(float3(warpedP, max(0.015, roundness)));

        float focus = 4.0 * progress * (1.0 - progress);
        float haze = 1.0 - smoothstep(0.0, 1.0, radius);
        float core = 1.0 - smoothstep(0.44, 0.84, radius + (warp1 - 0.5) * 0.12 * radius);
        float body = mix(haze, core, 0.60);

        // Expanding impact shockwave ring as the orb lands
        float shockT = saturate((t - 0.34) / 0.58);
        float shockRadius = 0.24 + 0.70 * (1.0 - pow(1.0 - shockT, 2.2));
        float shockRing = exp(-55.0 * pow(radius - shockRadius, 2.0))
                        * smoothstep(0.32, 0.45, t) * (1.0 - shockT) * smoothstep(1.0, 0.88, radius);

        float opacity = alpha * mix(0.36, 1.0, focus);
        float fresnel = pow(1.0 - normal.z, 2.5);
        float axis = progress + (uv.x - 0.5) * 0.88;
        float hue = normal.x * 0.16 + axis * 0.92 + uv.y * 0.18 + (warp2 - 0.5) * 0.28 + t * 0.12;
        float chroma = colorParams[1].w;
        float dispersion = (0.05 + 0.15 * fresnel + 0.08 * caustic + 0.10 * shockRing) * max(0.25, chroma);

        float3 foil = 0.90 * (0.50 * chromaticFoil(hue, dispersion, colorParams)
                    + 0.25 * (chromaticFoil(hue - 0.17, dispersion, colorParams)
                            + chromaticFoil(hue + 0.17, dispersion, colorParams)));
        float3 halfVector = normalize(normalize(float3(0.38, 0.52, 0.92)) + float3(0, 0, 1));
        float gloss = pow(saturate(dot(normal, halfVector)), 64.0);
        float filament = caustic * smoothstep(0.92, 0.18, radius) * 0.55;

        float intensity = colorParams[2].w;
        float alphaGain = abs(intensity - 1.0) < 1e-4 ? 1.0 : min(1.35, 0.35 + 0.65 * intensity);
        float baseA = saturate((body + shockRing * 0.65) * opacity);
        float a = saturate(baseA * alphaGain);
        float3 rawRgb = foil * baseA + (foil * (fresnel * 0.68 + shockRing * 0.95) + (gloss * 1.15 + filament) * float3(0.92, 0.98, 1.0)) * baseA * 0.85;
        float3 rgb = gradeColor(rawRgb, colorParams);
        pixels[(id.z * size.x + id.y) * size.x + id.x] = uchar4(float4(clamp(rgb, 0.0, a), a) * 255.0 + 0.5);
    }

    kernel void plasmaWake(device uchar4 *pixels [[buffer(0)]], constant uint2 &size [[buffer(1)]],
                           constant float2 *timing [[buffer(2)]], constant float4 *colorParams [[buffer(3)]],
                           uint3 id [[thread_position_in_grid]]) {
        float2 uv = (float2(id.xy) + 0.5) / float(size.x);
        float t = float(id.z) / float(size.y - 1);
        float progress = timing[id.z].x, alpha = timing[id.z].y;
        float x = uv.x; // 0 = start key tail, 1 = leading orb crest
        float y = (uv.y - 0.5) * 2.0;

        // Braided counter-scrolling plasma streams
        float n1 = fbm(float2(x * 4.2 - t * 8.5, y * 2.6 + 3.1));
        float n2 = fbm(float2(x * 7.5 - t * 12.0 + 5.4, y * 3.8 - n1 * 1.4));
        float undulation = (n1 - 0.5) * 0.34 * (1.0 - 0.72 * x);
        float width = 0.16 + 0.68 * pow(x, 1.25);
        float side = abs(y - undulation) / max(0.05, width);

        float ridge = pow(1.0 - abs(2.0 * n2 - 1.0), 2.5);
        float profile = saturate(1.0 - side + (n2 - 0.5) * 0.28);
        profile = profile * profile;

        float lengthwise = smoothstep(0.0, 0.16, x) * smoothstep(1.0, 0.86, x) * (0.25 + 0.75 * pow(x, 1.15));
        float edgeFeather = smoothstep(1.0, 0.78, abs(y));
        float intensity = colorParams[2].w;
        float alphaGain = abs(intensity - 1.0) < 1e-4 ? 1.0 : min(1.35, 0.35 + 0.65 * intensity);
        float baseA = saturate(profile * lengthwise * edgeFeather * alpha * 0.85);
        float a = saturate(baseA * alphaGain);

        float hue = progress * 0.75 + x * 0.65 + (n1 - 0.5) * 0.25;
        float3 col = chromaticFoil(hue, (0.08 + 0.08 * side) * max(0.25, colorParams[1].w), colorParams);
        col = mix(col, float3(0.92, 0.98, 1.0), saturate(pow(profile, 2.5) * 0.60 + ridge * 0.38));
        float3 rgb = clamp(gradeColor(col * baseA, colorParams), 0.0, a);
        pixels[(id.z * size.x + id.y) * size.x + id.x] = uchar4(float4(rgb, a) * 255.0 + 0.5);
    }
    """
}

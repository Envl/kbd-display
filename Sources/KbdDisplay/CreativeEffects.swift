import AppKit
import simd

/// Stateful 2D shallow-water ripple PDE simulation across the entire 1920x720 keyboard board.
/// Waves reflect off keyboard boundaries, interfere constructively/destructively, and render liquid caustics.
final class WaveTankEffect {
    private let width = 160
    private let height = 60
    private var curr: [Float]
    private var prev: [Float]
    private var next: [Float]
    private var pixels: [UInt8]
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private(set) var isActive = false

    init() {
        let count = width * height
        curr = Array(repeating: 0, count: count)
        prev = Array(repeating: 0, count: count)
        next = Array(repeating: 0, count: count)
        pixels = Array(repeating: 0, count: count * 4)
    }

    func reset() {
        for i in 0..<curr.count {
            curr[i] = 0; prev[i] = 0; next[i] = 0
        }
        isActive = false
    }

    /// Injects a smooth Gaussian pressure drop at the given board-space coordinate.
    func impulse(at boardPoint: CGPoint, strength: Double = 1.0) {
        let gx = Float(boardPoint.x / Action75.canvas.width) * Float(width - 1)
        let gy = Float(boardPoint.y / Action75.canvas.height) * Float(height - 1)
        let radius = 4
        let ix = Int(gx.rounded()), iy = Int(gy.rounded())
        let amp = Float(2.35 * strength)

        for dy in -radius...radius {
            let y = iy + dy
            guard y > 0, y < height - 1 else { continue }
            for dx in -radius...radius {
                let x = ix + dx
                guard x > 0, x < width - 1 else { continue }
                let d2 = Float(dx * dx + dy * dy)
                let drop = amp * exp(-d2 / 4.2)
                curr[y * width + x] += drop
            }
        }
        isActive = true
    }

    /// Advances the 2D wave equation by one fixed frame step.
    func step() {
        guard isActive else { return }
        let w = width, h = height
        let c2: Float = 0.23
        let damping: Float = 0.968
        var maxEnergy: Float = 0

        for y in 1..<(h - 1) {
            let row = y * w
            for x in 1..<(w - 1) {
                let i = row + x
                let laplacian = curr[i - 1] + curr[i + 1] + curr[i - w] + curr[i + w] - 4.0 * curr[i]
                let val = (2.0 * curr[i] - prev[i] + c2 * laplacian) * damping
                next[i] = max(-3.5, min(3.5, val))
                let absVal = abs(val)
                if absVal > maxEnergy { maxEnergy = absVal }
            }
        }
        // Reflective Neumann boundary conditions along the 4 edges of the keyboard
        for x in 0..<w {
            next[x] = next[w + x] * 0.92
            next[(h - 1) * w + x] = next[(h - 2) * w + x] * 0.92
        }
        for y in 0..<h {
            next[y * w] = next[y * w + 1] * 0.92
            next[y * w + w - 1] = next[y * w + w - 2] * 0.92
        }

        swap(&prev, &curr)
        swap(&curr, &next)

        if maxEnergy < 0.008 {
            reset()
        }
    }

    func draw(in context: CGContext, colors: EffectColorParams, strength: Double = 1.0) {
        guard isActive else { return }
        let w = width, h = height
        let palA = SIMD3<Float>(colors.palA.x, colors.palA.y, colors.palA.z)
        let palB = SIMD3<Float>(colors.palB.x, colors.palB.y, colors.palB.z)
        let palD = SIMD3<Float>(colors.palD.x, colors.palD.y, colors.palD.z)
        let intensity = colors.intensity * Float(strength)
        let alphaGain: Float = abs(intensity - 1.0) < 1e-4 ? 1.0 : min(1.45, 0.35 + 0.65 * intensity)

        for y in 0..<h {
            // Flip rows so CGContext.draw aligns row 0 with maxY (720) and row H-1 with minY (0).
            let srcY = h - 1 - y
            let yUp = max(0, srcY - 1)
            let yDown = min(h - 1, srcY + 1)
            for x in 0..<w {
                let xLeft = max(0, x - 1)
                let xRight = min(w - 1, x + 1)
                let i = srcY * w + x
                let val = curr[i]
                let gx = (curr[srcY * w + xRight] - curr[srcY * w + xLeft]) * 0.5
                let gy = (curr[yDown * w + x] - curr[yUp * w + x]) * 0.5
                let slope = hypot(gx, gy)
                let curvature = max(0, -(curr[srcY * w + xLeft] + curr[srcY * w + xRight]
                                         + curr[yUp * w + x] + curr[yDown * w + x] - 4.0 * val))

                let crest = min(1.0, abs(val) * 0.72 + slope * 1.35 + curvature * 0.85)
                let outIdx = (y * w + x) * 4
                if crest < 0.015 {
                    pixels[outIdx] = 0; pixels[outIdx + 1] = 0; pixels[outIdx + 2] = 0; pixels[outIdx + 3] = 0
                    continue
                }

                // Specular highlight from wave normal & caustic convergence
                let normal = simd_normalize(SIMD3<Float>(-gx * 2.2, -gy * 2.2, 1.0))
                let light = simd_normalize(SIMD3<Float>(0.32, -0.48, 0.82))
                let spec = pow(max(0, simd_dot(normal, light)), 22.0) * min(1.0, slope * 2.4)
                let t = 0.25 + val * 0.55 + slope * 0.65
                let angle = 2.0 * Float.pi * (0.5 * t + palD)
                let baseCol = palA + palB * SIMD3<Float>(cos(angle.x), cos(angle.y), cos(angle.z))
                let foam = min(1.0, spec * 1.15 + curvature * 0.45)
                let mixed = baseCol * (1.0 - foam * 0.55) + SIMD3<Float>(0.92, 0.98, 1.0) * foam
                let graded = colors.grade(simd_clamp(mixed, .zero, SIMD3<Float>(repeating: 1.0)))

                let a = min(1.0, crest * 0.88 * alphaGain)
                let r = min(a, graded.x * a)
                let g = min(a, graded.y * a)
                let b = min(a, graded.z * a)
                pixels[outIdx] = UInt8(r * 255.0 + 0.5)
                pixels[outIdx + 1] = UInt8(g * 255.0 + 0.5)
                pixels[outIdx + 2] = UInt8(b * 255.0 + 0.5)
                pixels[outIdx + 3] = UInt8(a * 255.0 + 0.5)
            }
        }

        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: w * 4, space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return }

        context.saveGState()
        context.setBlendMode(.plusLighter)
        context.draw(image, in: CGRect(origin: .zero, size: Action75.canvas))
        context.restoreGState()
    }
}

/// Persistent multi-key star constellation: recent keypresses form an evolving geometric graph
/// with glowing filaments, aurora triangle panes, diffraction stars, and synaptic pulses.
final class ConstellationEffect {
    struct Node {
        let keyCode: UInt16
        let origin: CGPoint
        let bornAt: TimeInterval
        let phase: Double
        var pulseBoost: Double
    }

    static let nodeLifetime: TimeInterval = 3.4
    private static let maxNodes = 16
    private static let maxEdgeDistance: CGFloat = 520

    private(set) var nodes: [Node] = []
    var isActive: Bool { !nodes.isEmpty }

    func reset() { nodes.removeAll() }

    func addNode(at point: CGPoint, keyCode: UInt16, at now: TimeInterval) {
        if let idx = nodes.firstIndex(where: { $0.keyCode == keyCode }) {
            let old = nodes[idx]
            nodes[idx] = Node(keyCode: keyCode, origin: point, bornAt: now, phase: old.phase,
                              pulseBoost: min(1.0, old.pulseBoost + 0.45))
        } else {
            nodes.append(Node(keyCode: keyCode, origin: point, bornAt: now,
                              phase: Double(keyCode) * 1.6180339887, pulseBoost: 0.4))
            if nodes.count > Self.maxNodes {
                nodes.removeFirst(nodes.count - Self.maxNodes)
            }
        }
    }

    func prune(now: TimeInterval) {
        nodes.removeAll { now - $0.bornAt >= Self.nodeLifetime }
    }

    func draw(in context: CGContext, now: TimeInterval, colors: EffectColorParams, strength: Double = 1.0) {
        prune(now: now)
        guard !nodes.isEmpty else { return }

        struct LiveNode {
            let pos: CGPoint
            let alpha: Double
            let age: Double
            let phase: Double
            let boost: Double
        }

        let gain = min(1.6, max(0.25, strength))
        let live: [LiveNode] = nodes.map { n in
            let age = max(0, now - n.bornAt)
            let t = age / Self.nodeLifetime
            let alpha = min(1.0, age * 14.0) * pow(max(0, 1.0 - t), 1.45) * min(1.3, gain)
            // Subtle floating orbital drift around the keycap center
            let driftX = cos(age * 1.8 + n.phase) * 9.0 * min(1, age * 2.0)
            let driftY = sin(age * 2.2 + n.phase * 1.3) * 7.0 * min(1, age * 2.0)
            return LiveNode(pos: CGPoint(x: n.origin.x + driftX, y: n.origin.y + driftY),
                            alpha: alpha, age: age, phase: n.phase, boost: n.pulseBoost)
        }

        // Build proximity edges
        var edges: [(Int, Int, Double)] = []
        for i in 0..<live.count {
            var neighbors: [(Int, CGFloat)] = []
            for j in (i + 1)..<live.count {
                let d = hypot(live[i].pos.x - live[j].pos.x, live[i].pos.y - live[j].pos.y)
                if d < Self.maxEdgeDistance {
                    neighbors.append((j, d))
                }
            }
            neighbors.sort { $0.1 < $1.1 }
            for (j, d) in neighbors.prefix(3) {
                let distFactor = Double(1.0 - d / Self.maxEdgeDistance)
                let strength = min(live[i].alpha, live[j].alpha) * (0.35 + 0.65 * distFactor)
                if strength > 0.02 {
                    edges.append((i, j, strength))
                }
            }
        }

        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.plusLighter)
        context.setLineCap(.round)

        // 1. Aurora triad panes where 3 active nodes form a connected triangle
        var adj: [Set<Int>] = Array(repeating: [], count: live.count)
        for (a, b, _) in edges { adj[a].insert(b); adj[b].insert(a) }
        for i in 0..<live.count {
            for j in adj[i] where j > i {
                for k in adj[j] where k > j && adj[i].contains(k) {
                    let triAlpha = min(live[i].alpha, min(live[j].alpha, live[k].alpha)) * 0.16
                    guard triAlpha > 0.008 else { continue }
                    let col = colors.samplePalette(at: Float(fmod((live[i].phase + live[j].phase) * 0.17, 1.0)))
                        .withAlphaComponent(triAlpha)
                    let path = CGMutablePath()
                    path.move(to: live[i].pos)
                    path.addLine(to: live[j].pos)
                    path.addLine(to: live[k].pos)
                    path.closeSubpath()
                    context.setFillColor(col.cgColor)
                    context.addPath(path)
                    context.fillPath()
                }
            }
        }

        // 2. Constellation filaments & traveling synaptic pulses
        for (idx, (a, b, strength)) in edges.enumerated() {
            let pa = live[a].pos, pb = live[b].pos
            let edgeColor = colors.samplePalette(at: Float(fmod(Double(idx) * 0.19 + now * 0.12, 1.0)))

            // Soft outer filament halo
            context.setStrokeColor(edgeColor.withAlphaComponent(strength * 0.28).cgColor)
            context.setLineWidth(5.5)
            context.move(to: pa); context.addLine(to: pb); context.strokePath()

            // Crisp luminous thread
            context.setStrokeColor(edgeColor.withAlphaComponent(strength * 0.78).cgColor)
            context.setLineWidth(1.5)
            context.move(to: pa); context.addLine(to: pb); context.strokePath()

            // Traveling synaptic light packet along the filament
            let u = fmod(now * (0.95 + Double(idx % 3) * 0.25) + Double(idx) * 0.37, 1.0)
            let px = pa.x + (pb.x - pa.x) * u
            let py = pa.y + (pb.y - pa.y) * u
            let pulseR: CGFloat = 3.2
            let pulseCol = colors.apply(to: NSColor.white.withAlphaComponent(strength * 0.92))
            context.setFillColor(pulseCol.cgColor)
            context.fillEllipse(in: CGRect(x: px - pulseR, y: py - pulseR, width: pulseR * 2, height: pulseR * 2))
        }

        // 3. Celestial diffraction star nodes on each active key
        for n in live {
            let starColor = colors.samplePalette(at: Float(fmod(n.phase * 0.31 + now * 0.08, 1.0)))
            let haloR = CGFloat(14 + 10 * n.boost) * CGFloat(0.75 + 0.25 * sin(now * 6.0 + n.phase))
            context.saveGState()
            context.setFillColor(starColor.withAlphaComponent(n.alpha * 0.42).cgColor)
            context.setShadow(offset: .zero, blur: 16, color: starColor.withAlphaComponent(n.alpha * 0.85).cgColor)
            context.fillEllipse(in: CGRect(x: n.pos.x - haloR * 0.55, y: n.pos.y - haloR * 0.55,
                                           width: haloR * 1.1, height: haloR * 1.1))
            context.restoreGState()

            // 4-point rotating diffraction spikes
            let spikeLen = CGFloat(16 + 14 * n.boost) * CGFloat(0.8 + 0.2 * sin(now * 5.0 + n.phase))
            let rot = now * 0.45 + n.phase
            let spikeColor = colors.apply(to: NSColor.white.withAlphaComponent(n.alpha * 0.92))
            context.setStrokeColor(spikeColor.cgColor)
            context.setLineWidth(1.4)
            for s in 0..<2 {
                let a = rot + Double(s) * (.pi * 0.5)
                let dx = cos(a) * spikeLen, dy = sin(a) * spikeLen
                context.move(to: CGPoint(x: n.pos.x - dx, y: n.pos.y - dy))
                context.addLine(to: CGPoint(x: n.pos.x + dx, y: n.pos.y + dy))
                context.strokePath()
            }
            let coreR: CGFloat = 3.5 + CGFloat(n.boost) * 2.0
            context.setFillColor(spikeColor.cgColor)
            context.fillEllipse(in: CGRect(x: n.pos.x - coreR, y: n.pos.y - coreR, width: coreR * 2, height: coreR * 2))
        }
    }
}

/// Cybernetic neon digital glyph rain streams cascading across keyboard columns from struck keys.
final class MatrixRainEffect {
    struct Stream {
        let x: CGFloat
        let startY: CGFloat
        let direction: CGFloat // +1 downward, -1 upward
        let speed: CGFloat
        let bornAt: TimeInterval
        let lifetime: TimeInterval
        let seed: Int
        let trailLength: Int
    }

    private static let glyphs = Array("01アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲン∆ΩλΨ")
    private(set) var streams: [Stream] = []
    var isActive: Bool { !streams.isEmpty }

    func reset() { streams.removeAll() }

    func spawn(at point: CGPoint, keyCode: UInt16, at now: TimeInterval, strength: Double = 1.0) {
        let baseSeed = Int(keyCode) * 97 + Int(now * 1000) % 997
        // Primary downward cascade + upward rebound + side column echo
        let configs: [(dx: CGFloat, dir: CGFloat, speed: CGFloat, life: TimeInterval, trail: Int)] = [
            (0, 1, 520, 1.55, 10),
            (0, -1, 440, 1.25, 8),
            (-52, 1, 410, 1.15, 7),
            (52, 1, 430, 1.15, 7),
        ]
        let count = strength > 0.7 ? configs.count : 2
        for i in 0..<count {
            let c = configs[i]
            let x = min(Action75.canvas.width - 16, max(16, point.x + c.dx))
            streams.append(Stream(x: x, startY: point.y, direction: c.dir, speed: c.speed,
                                  bornAt: now, lifetime: c.life, seed: baseSeed + i * 31, trailLength: c.trail))
        }
        if streams.count > 48 {
            streams.removeFirst(streams.count - 48)
        }
    }

    func prune(now: TimeInterval) {
        streams.removeAll { now - $0.bornAt >= $0.lifetime }
    }

    func draw(in context: CGContext, now: TimeInterval, colors: EffectColorParams, strength: Double = 1.0) {
        prune(now: now)
        guard !streams.isEmpty else { return }

        let font = NSFont.monospacedSystemFont(ofSize: 22, weight: .bold)
        let stepY: CGFloat = 28
        let gain = min(1.5, max(0.3, strength))

        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.plusLighter)

        let baseNeon = colors.apply(to: NSColor(srgbRed: 0.14, green: 0.98, blue: 0.42, alpha: 1))
        let headWhite = colors.apply(to: NSColor(srgbRed: 0.88, green: 1.0, blue: 0.94, alpha: 1))

        for stream in streams {
            let age = now - stream.bornAt
            guard age >= 0, age < stream.lifetime else { continue }
            let env = (1.0 - age / stream.lifetime) * gain
            let headY = stream.startY + stream.direction * CGFloat(age) * stream.speed
            let tick = Int(now * 16.0)

            for idx in 0..<stream.trailLength {
                let y = headY - stream.direction * CGFloat(idx) * stepY
                guard y > -30, y < Action75.canvas.height + 30 else { continue }
                let trailFade = pow(1.0 - Double(idx) / Double(stream.trailLength), 1.35)
                let alpha = min(1.0, env * trailFade * (idx == 0 ? 1.0 : 0.78))
                guard alpha > 0.02 else { continue }

                let glyphIndex = abs(stream.seed + idx * 17 + (idx == 0 ? tick * 3 : tick / 2)) % Self.glyphs.count
                let char = String(Self.glyphs[glyphIndex])
                let color = (idx == 0 ? headWhite : baseNeon).withAlphaComponent(alpha)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: color,
                ]
                let rect = CGRect(x: stream.x - 14, y: y - 14, width: 28, height: 28)
                char.draw(in: rect, withAttributes: attrs)
            }
        }
    }
}

/// Parabolic firework rockets launched from struck keys that burst into shimmering spherical starbursts.
final class FireworksEffect {
    struct Shell {
        let launch: CGPoint
        let apex: CGPoint
        let bornAt: TimeInterval
        let ascentDuration: TimeInterval
        let burstDuration: TimeInterval
        let seed: UInt64
        let colorPhase: Float
        let burstRadius: CGFloat
    }

    private(set) var shells: [Shell] = []
    var isActive: Bool { !shells.isEmpty }

    func reset() { shells.removeAll() }

    func launch(from point: CGPoint, keyCode: UInt16, at now: TimeInterval, strength: Double = 1.0) {
        let seed = UInt64(keyCode) &* 0x9E3779B97F4A7C15 ^ UInt64(now * 1000)
        var s = seed == 0 ? 1 : seed
        func nextUnit() -> Double {
            s &+= 0x9E3779B97F4A7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z = z ^ (z >> 31)
            return Double(z >> 11) / Double(1 << 53)
        }
        let rise = CGFloat(130 + nextUnit() * 190)
        let driftX = CGFloat((nextUnit() - 0.5) * 140)
        let apex = CGPoint(
            x: min(Action75.canvas.width - 90, max(90, point.x + driftX)),
            y: max(75, point.y - rise)
        )
        let radius = CGFloat((95 + nextUnit() * 65) * max(0.5, min(1.6, strength)))
        shells.append(Shell(
            launch: point,
            apex: apex,
            bornAt: now,
            ascentDuration: 0.28 + nextUnit() * 0.14,
            burstDuration: 0.95 + nextUnit() * 0.35,
            seed: s,
            colorPhase: Float(nextUnit()),
            burstRadius: radius
        ))
        if shells.count > 18 {
            shells.removeFirst(shells.count - 18)
        }
    }

    func prune(now: TimeInterval) {
        shells.removeAll { now - $0.bornAt >= $0.ascentDuration + $0.burstDuration }
    }

    func draw(in context: CGContext, now: TimeInterval, colors: EffectColorParams, strength: Double = 1.0) {
        prune(now: now)
        guard !shells.isEmpty else { return }

        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.plusLighter)
        context.setLineCap(.round)

        let gain = min(1.5, max(0.35, strength))

        for shell in shells {
            let age = now - shell.bornAt
            guard age >= 0 else { continue }

            if age < shell.ascentDuration {
                // Rising glowing rocket trail
                let u = age / shell.ascentDuration
                let ease = 1.0 - pow(1.0 - u, 1.8)
                let prevEase = 1.0 - pow(1.0 - max(0, u - 0.18), 1.8)
                let cur = CGPoint(x: shell.launch.x + (shell.apex.x - shell.launch.x) * ease,
                                  y: shell.launch.y + (shell.apex.y - shell.launch.y) * ease)
                let prev = CGPoint(x: shell.launch.x + (shell.apex.x - shell.launch.x) * prevEase,
                                   y: shell.launch.y + (shell.apex.y - shell.launch.y) * prevEase)
                let rocketCol = colors.samplePalette(at: shell.colorPhase)
                context.setStrokeColor(rocketCol.withAlphaComponent(0.75 * gain).cgColor)
                context.setLineWidth(3.2)
                context.move(to: prev); context.addLine(to: cur); context.strokePath()
                let headCol = colors.apply(to: NSColor.white.withAlphaComponent(0.95))
                context.setFillColor(headCol.cgColor)
                context.fillEllipse(in: CGRect(x: cur.x - 3.5, y: cur.y - 3.5, width: 7, height: 7))
            } else {
                // Spherical chrysanthemum firework starburst with trailing sparklers & gravity droop
                let bt = (age - shell.ascentDuration) / shell.burstDuration
                guard bt >= 0, bt < 1 else { continue }

                // Brief detonation core flash
                if bt < 0.16 {
                    let flash = (1.0 - bt / 0.16) * 0.72 * gain
                    let flashR = CGFloat(24 + bt * 120)
                    let flashCol = colors.samplePalette(at: shell.colorPhase).withAlphaComponent(flash)
                    context.setFillColor(flashCol.cgColor)
                    context.fillEllipse(in: CGRect(x: shell.apex.x - flashR, y: shell.apex.y - flashR,
                                                   width: flashR * 2, height: flashR * 2))
                }

                let rayCount = 24
                var s = shell.seed
                func nextUnit() -> Double {
                    s &+= 0x9E3779B97F4A7C15
                    var z = s
                    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
                    z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
                    z = z ^ (z >> 31)
                    return Double(z >> 11) / Double(1 << 53)
                }

                let ease = 1.0 - pow(1.0 - bt, 2.6)
                let prevEase = 1.0 - pow(1.0 - max(0, bt - 0.11), 2.6)
                let fade = pow(1.0 - bt, 1.45) * gain

                for r in 0..<rayCount {
                    let angle = (Double(r) / Double(rayCount)) * 2.0 * .pi + (nextUnit() - 0.5) * 0.18
                    let speedMul = 0.52 + nextUnit() * 0.62
                    let rad = Double(shell.burstRadius) * speedMul
                    let droop = 72.0 * bt * bt
                    let prevDroop = 72.0 * max(0, bt - 0.11) * max(0, bt - 0.11)

                    let p1 = CGPoint(x: shell.apex.x + cos(angle) * rad * ease,
                                     y: shell.apex.y + sin(angle) * rad * ease + droop)
                    let p0 = CGPoint(x: shell.apex.x + cos(angle) * rad * prevEase,
                                     y: shell.apex.y + sin(angle) * rad * prevEase + prevDroop)

                    let twinkle = bt > 0.45 ? (0.45 + 0.55 * abs(sin(now * 28.0 + Double(r) * 2.3))) : 1.0
                    let rayAlpha = min(1.0, fade * twinkle)
                    let rayColor = colors.samplePalette(at: fmod(shell.colorPhase + Float(r % 3) * 0.12 + Float(bt) * 0.2, 1.0))

                    context.setStrokeColor(rayColor.withAlphaComponent(rayAlpha * 0.85).cgColor)
                    context.setLineWidth(CGFloat(2.2 * (1.0 - 0.5 * bt)))
                    context.move(to: p0); context.addLine(to: p1); context.strokePath()

                    let tipR = CGFloat(2.1 * (1.0 - 0.45 * bt))
                    let tipColor = colors.apply(to: NSColor.white.withAlphaComponent(rayAlpha * 0.95))
                    context.setFillColor(tipColor.cgColor)
                    context.fillEllipse(in: CGRect(x: p1.x - tipR, y: p1.y - tipR, width: tipR * 2, height: tipR * 2))
                }
            }
        }
    }
}

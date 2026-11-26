import AppKit

/// The bitmap includes the whole choreography, so a frame still costs one image draw per cut.
enum BladeTrailRenderer {
    static let frames = 32
    private static let cache: NSCache<NSNumber, CGImage> = {
        let cache = NSCache<NSNumber, CGImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let bounds = CGRect(x: -32, y: -100, width: 544, height: 200)

    static func draw(
        _ style: BladeStyle, from start: CGPoint, to end: CGPoint,
        thickness: CGFloat, elapsed: TimeInterval, opacity: CGFloat, seed: UInt64,
        in context: CGContext
    ) {
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 0.5, thickness > 0, opacity > 0.008,
            elapsed >= 0, elapsed < style.trailLifetime
        else { return }
        let frame = Int(elapsed / style.trailLifetime * CGFloat(frames))
        let key = NSNumber(value: style.rawValue * frames + frame)
        let image: CGImage
        if let cached = cache.object(forKey: key) {
            image = cached
        } else {
            guard
                let bitmap = CGContext(
                    data: nil, width: Int(bounds.width), height: Int(bounds.height),
                    bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            bitmap.translateBy(x: -bounds.minX, y: -bounds.minY)
            let phase = (CGFloat(frame) + 0.5) / CGFloat(frames)
            BladeArtwork(cg: bitmap, style: style, t: phase).paint()
            guard let rendered = bitmap.makeImage() else { return }
            cache.setObject(rendered, forKey: key, cost: rendered.bytesPerRow * rendered.height)
            image = rendered
        }
        context.saveGState()
        context.translateBy(x: start.x, y: start.y)
        context.rotate(by: atan2(end.y - start.y, end.x - start.x))
        let breadth = min(thickness / 10, length / 225)
        context.scaleBy(x: length / 480, y: seed & 1 == 0 ? breadth : -breadth)
        context.setBlendMode(.normal)
        context.setAlpha(opacity)
        context.interpolationQuality = .medium
        context.draw(image, in: bounds)
        context.restoreGState()
    }
}

private func unit(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }
private func ease(_ x: CGFloat) -> CGFloat {
    let u = unit(x)
    return u * u * (3 - 2 * u)
}

private struct BladeArtwork {
    let cg: CGContext
    let style: BladeStyle
    let t: CGFloat
    private var attack: CGFloat { unit(t * style.trailLifetime / BladeStyle.attackDuration) }
    private var color: NSColor { style.primaryColor }
    private var accent: NSColor { style.secondaryColor }

    func paint() {
        cg.setLineJoin(.round)
        cg.setLineCap(.round)
        switch style {
        case .plasmaKatana: plasma()
        case .infernoDragon: inferno()
        case .frostbiteCrystal: frost()
        case .sakuraWind: sakura()
        case .thunderGod: thunder()
        case .voidSingularity: rift()
        case .rainbowPrism: prism()
        case .shadowInk: ink()
        case .foilGlow: foilGlow()
        case .plasmaBraid: plasmaBraid()
        }
    }

    private func noise(_ i: Int) -> CGFloat {
        let x = sin(CGFloat(i + 1) * 78.233) * 43758.5453
        return x - floor(x)
    }
    private func fade(after start: CGFloat) -> CGFloat { 1 - ease((t - start) / (1 - start)) }
    private func fill(_ tint: NSColor, _ alpha: CGFloat) {
        cg.setFillColor(tint.withAlphaComponent(unit(alpha)).cgColor)
    }
    private func line(_ points: [CGPoint], _ tint: NSColor, _ width: CGFloat, _ alpha: CGFloat) {
        guard points.count >= 2 else { return }
        cg.setStrokeColor(tint.withAlphaComponent(unit(alpha)).cgColor)
        cg.setLineWidth(width)
        cg.addLines(between: points)
        cg.strokePath()
    }
    private func points(
        from lo: CGFloat = 0, to hi: CGFloat, count: Int = 48,
        _ position: (CGFloat) -> CGPoint
    ) -> [CGPoint] {
        (0...count).map { position(lo + (hi - lo) * CGFloat($0) / CGFloat(count)) }
    }
    private func polygon(_ pts: [CGPoint], _ tint: NSColor, _ alpha: CGFloat) {
        fill(tint, alpha)
        cg.addLines(between: pts)
        cg.closePath()
        cg.fillPath()
    }
    private func dot(_ p: CGPoint, _ r: CGFloat, _ tint: NSColor, _ alpha: CGFloat) {
        fill(tint, alpha)
        cg.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }
    private func shine(_ p: CGPoint, _ r: CGFloat, _ alpha: CGFloat) {
        line([p.offset(-r, 0), p.offset(r, 0)], .white, 1.5, alpha)
        line([p.offset(0, -r * 1.4), p.offset(0, r * 1.4)], .white, 1.5, alpha)
        dot(p, 2.3, .white, alpha)
    }

    // A drawn katana describes one high crescent. Its cutting edge clears first,
    // leaving two progressively shorter afterimages on the inside of the arc.
    private func plasma() {
        let head = 0.09 + 0.91 * (1 - pow(1 - attack, 3))
        let tail = ease((t - 0.25) / 0.78)
        let light = fade(after: 0.42)
        func arc(_ u: CGFloat, _ lift: CGFloat) -> CGPoint {
            CGPoint(x: 480 * u, y: 4 * u * (1 - u) * lift)
        }
        let outer = points(from: tail, to: head) { arc($0, 78) }
        let inner = points(from: head, to: tail) { u in
            let taper = sin(.pi * (u - tail) / max(0.001, head - tail))
            return arc(u, 78 - 30 * taper)
        }
        polygon(outer + inner, color, 0.68 * light)
        line(outer, color, 9, 0.20 * light)
        line(outer, .white, 2.6, light)
        for n in 1...2 {
            let end = max(tail, head - CGFloat(n) * 0.08)
            line(
                points(from: tail, to: end) { arc($0, 46 - CGFloat(n) * 12) },
                accent, 2.8 - CGFloat(n) * 0.5, light * 0.8)
        }
        shine(arc(head, 78), 8 * light, light)
    }

    // A heavy moving fireball carries a short, serpentine wake. Detached embers
    // keep rising after the head bursts against the destination.
    private func inferno() {
        let head = 0.06 + 0.94 * sin(attack * .pi / 2)
        func coil(_ u: CGFloat) -> CGPoint {
            CGPoint(x: 480 * u, y: 49 * sin(2.5 * .pi * u) * sin(.pi * u))
        }
        let tail = max(0, head - 0.34 + 0.32 * ease((t - 0.27) / 0.60))
        let flame = fade(after: 0.68)
        for i in 0..<23 {
            let f = CGFloat(i) / 22
            let p = coil(tail + (head - tail) * f)
            let r = (2 + 13 * f) * (0.9 + 0.12 * sin(12 * t + 19 * f))
            dot(p, r * 1.65, .systemRed, 0.18 * flame)
            dot(p, r, color, flame)
            dot(p.offset(1, 1), r * 0.53, accent, flame)
            if i.isMultiple(of: 3) {
                let h = (9 + 19 * noise(i)) * f
                polygon([p.offset(-r, 0), p.offset(-r * 2.7, h), p.offset(r * 0.6, r * 0.5)], color, flame)
            }
        }
        let impact = ease((t - 0.26) / 0.52)
        for i in 0..<22 {
            let u = noise(i) * head
            let p = coil(u)
            let drift = unit((head - u) * 1.6 + impact * 0.7)
            dot(
                p.offset(-18 * drift, drift * (15 + 40 * noise(i + 9))), 1 + 2.3 * noise(i + 3), accent,
                (1 - drift) * flame)
        }
        let center = coil(head)
        dot(center, 12 * flame, style.coreColor, flame)
        if impact > 0 {
            for i in 0..<12 {
                let a = CGFloat(i) * 2.4
                let d = impact * (15 + 22 * noise(i))
                line(
                    [
                        center.offset(cos(a) * d * 0.6, sin(a) * d * 0.6),
                        center.offset(cos(a) * d, sin(a) * d),
                    ], accent, 2, 1 - impact)
            }
        }
    }

    // Separate ice spears grow in sequence, lock into place, then shear away.
    private func frost() {
        for i in 0..<8 {
            let u = CGFloat(i) / 8
            let grow = ease((attack - u * 0.71) / 0.36)
            guard grow > 0 else { continue }
            let split = ease((t - 0.58 - 0.12 * noise(i)) / 0.28)
            let side: CGFloat = i.isMultiple(of: 2) ? 1 : -1
            let base = CGPoint(
                x: 480 * u + split * (noise(i) - 0.5) * 20,
                y: side * (10 * sin(.pi * u) + split * (22 + 17 * noise(i))))
            let h = side * (24 + 28 * noise(i + 4)) * grow
            let tip = base.offset(62 * grow, -side * 9 * grow)
            let top = base.offset(22 * grow, h)
            let ridge = base.offset(35 * grow, h * 0.24)
            let alpha = fade(after: 0.73)
            polygon([base, top, ridge], color, 0.95 * alpha)
            polygon([top, tip, ridge], .white, 0.88 * alpha)
            polygon([base, ridge, tip, base.offset(12 * grow, -h * 0.4)], accent, alpha)
            line([base, top, tip], color, 1.5, alpha)
            line([top, ridge, base.offset(14 * grow, -h * 0.22)], .white, 1.0, 0.78 * alpha)
            let spur = ridge.offset(-14 * grow, h * 0.71)
            polygon([ridge.offset(-8 * grow, 0), spur, ridge.offset(4 * grow, 0)], accent, 0.92 * alpha)
            if grow < 1 || split > 0 { shine(top, 3.3 * grow, alpha) }
        }
    }

    private func sakura() {
        // The spline doubles back through a loop. Petals peel away from that same path.
        func wind(_ u: CGFloat) -> CGPoint {
            let angle = 2 * .pi * u
            let bell = sin(.pi * u)
            return CGPoint(
                x: 480 * u + 130 * sin(angle) * bell,
                y: bell * (19 + 62 * cos(angle)))
        }
        let head = 0.08 + 0.92 * (1 - pow(1 - attack, 1.55))
        let tail = ease((t - 0.40) / 0.66)
        let alpha = fade(after: 0.73)
        line(points(from: tail, to: head, wind), accent, 2.4, 0.82 * alpha)
        for i in 0..<17 {
            let u = CGFloat(i) / 17
            guard u <= head else { continue }
            let drift = unit((head - u) * 0.85 + max(0, t - 0.7))
            let p = wind(u).offset(-12 * drift, (noise(i) - 0.42) * 53 * drift)
            cg.saveGState()
            cg.translateBy(x: p.x, y: p.y)
            cg.rotate(by: CGFloat(i) * 2.2 + drift * 4)
            let size = 0.52 + 0.62 * noise(i + 11)
            cg.scaleBy(x: size, y: size * (0.52 + 0.48 * abs(cos(t * 6 + CGFloat(i)))))
            fill(i.isMultiple(of: 3) ? accent : color, alpha)
            cg.move(to: .zero)
            cg.addQuadCurve(to: CGPoint(x: 14, y: -4), control: CGPoint(x: 6, y: -13))
            cg.addLine(to: CGPoint(x: 11, y: 0))
            cg.addQuadCurve(to: .zero, control: CGPoint(x: 17, y: 11))
            cg.fillPath()
            cg.restoreGState()
        }
    }

    private func thunder() {
        // Two discrete strikes take different routes. A faint channel persists between them.
        let restrike = attack >= 1
        let pulse = restrike ? 1 - ease((t - 0.28) / 0.72) : 1 - ease(attack)
        let alpha = 0.14 * fade(after: 0.6) + 0.86 * pulse
        var bolt = [CGPoint.zero]
        for i in 1...14 {
            let u = CGFloat(i) / 14
            let sign: CGFloat = i.isMultiple(of: 2) ? 1 : -1
            let y = sign * sin(.pi * u) * (13 + 34 * noise(i + (restrike ? 71 : 3)))
            let p = CGPoint(x: 480 * u, y: y)
            bolt.append(p)
            if i % 3 == 1 {
                let fork = p.offset(-14, sign * 16)
                line(
                    [p, fork, fork.offset(-18, -sign * 3), fork.offset(-37, sign * 14)], color, 2.2, alpha)
            }
        }
        line(bolt, color, 12, alpha * 0.18)
        line(bolt, color, 4.8, alpha)
        line(bolt, .white, 1.9, alpha)
        shine(CGPoint(x: 480, y: 0), 9 * pulse, alpha)
    }

    private func rift() {
        // Two portals open independently. The tear connects them in a single snap,
        // then folds into its midpoint while the portals contract.
        let open = (0.16 + 0.84 * ease(attack / 0.62)) * fade(after: 0.63)
        let link = ease((attack - 0.42) / 0.55) * fade(after: 0.54)
        let fold = ease((t - 0.56) / 0.34)
        if link > 0.005 {
            let lo = 0.46 * fold
            let hi = 1 - lo
            func lip(_ u: CGFloat, _ side: CGFloat) -> CGPoint {
                CGPoint(x: 480 * u, y: side * (5 + 32 * sin(.pi * u)) * link + 7 * sin(2 * .pi * u))
            }
            let top = points(from: lo, to: hi) { lip($0, 1) }
            let bottom = points(from: hi, to: lo) { lip($0, -1) }
            polygon(top + bottom, style.coreColor, link)
            line(top, color, 5, link)
            line(bottom, accent, 2.4, link)
        }
        for x: CGFloat in [0, 480] {
            cg.saveGState()
            cg.translateBy(x: x, y: 0)
            cg.rotate(by: (x == 0 ? 1 : -1) * (0.25 + 0.22 * sin(t * 5)))
            let rect = CGRect(x: -11 * open, y: -38 * open, width: 22 * open, height: 76 * open)
            fill(style.coreColor, open)
            cg.fillEllipse(in: rect)
            cg.setStrokeColor(color.withAlphaComponent(open).cgColor)
            cg.setLineWidth(4 * open)
            cg.strokeEllipse(in: rect)
            cg.setStrokeColor(accent.withAlphaComponent(open).cgColor)
            cg.setLineWidth(1)
            cg.strokeEllipse(in: rect.insetBy(dx: -3 * open, dy: -7 * open))
            cg.restoreGState()
        }
    }

    private func prism() {
        // A single incident ray reaches the prism before the spectral fan opens.
        let pivot = CGPoint(x: 178, y: 12)
        let reach = unit(0.16 + attack / 0.36)
        let alpha = fade(after: 0.53)
        line([.zero, CGPoint(x: pivot.x * reach, y: pivot.y * reach)], .white, 3.5, alpha)
        let radius = 15 + 5 * sin(.pi * t)
        let a = pivot.offset(-radius, -radius)
        let b = pivot.offset(radius * 1.25, 0)
        let c = pivot.offset(-radius, radius)
        polygon([a, b, c], accent, 0.42 * alpha)
        line([a, b, c, a], .white, 1.6, alpha)
        for i in 0..<7 {
            let front = unit((attack - 0.18 - CGFloat(i) * 0.035) / 0.61)
            guard front > 0 else { continue }
            let bend = CGFloat(i - 3) * 19
            let path = points(to: front, count: 24) { u in
                let triangle = 1 - abs(2 * u - 1)
                return CGPoint(x: pivot.x + (480 - pivot.x) * u, y: pivot.y * (1 - u) + triangle * bend)
            }
            let tint = style.color(at: CGFloat(i) / 7, time: 0)
            line(path, tint, 7, 0.13 * alpha)
            line(path, tint, 2.5, alpha)
        }
    }

    private func foilGlow() {
        let head = 480 * (0.04 + 0.96 * (1 - pow(1 - attack, 2)))
        let alpha = fade(after: 0.32)
        let tail = head * ease((t - 0.21) / 0.72)
        let radius = 22 * (0.72 + 0.28 * alpha)
        let gradientSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let sheen = [NSColor.systemIndigo, .systemCyan, .white, .systemYellow, .systemPink]
        let wakeColors =
            [
                color.withAlphaComponent(0), color.withAlphaComponent(0.6),
                accent.withAlphaComponent(0.85),
            ].map(\.cgColor) as CFArray
        cg.saveGState()
        cg.setAlpha(alpha)
        cg.saveGState()
        cg.addEllipse(in: CGRect(x: tail, y: -4, width: max(1, head - tail), height: 8))
        cg.clip()
        if let wake = CGGradient(colorsSpace: gradientSpace, colors: wakeColors, locations: nil) {
            cg.drawLinearGradient(wake, start: CGPoint(x: tail, y: 0), end: CGPoint(x: head, y: 0), options: [])
        }
        cg.restoreGState()
        let center = CGPoint(x: head, y: 0)
        cg.addEllipse(in: CGRect(x: head - radius, y: -radius, width: 2 * radius, height: 2 * radius))
        cg.clip()
        if let foil = CGGradient(colorsSpace: gradientSpace, colors: sheen.map(\.cgColor) as CFArray, locations: nil) {
            let tilt = radius * (0.35 + 0.4 * sin(t * 7))
            cg.drawLinearGradient(
                foil, start: center.offset(-radius, -tilt), end: center.offset(radius, tilt),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        let shade = [NSColor.white.withAlphaComponent(0.85), .clear, NSColor.black.withAlphaComponent(0.65)]
        if let lighting = CGGradient(
            colorsSpace: gradientSpace, colors: shade.map(\.cgColor) as CFArray,
            locations: [0, 0.30, 1])
        {
            cg.drawRadialGradient(
                lighting, startCenter: center.offset(-radius * 0.32, radius * 0.38), startRadius: 0,
                endCenter: center, endRadius: radius, options: [])
        }
        cg.restoreGState()
    }

    private func plasmaBraid() {
        let head = 0.09 + 0.91 * (1 - pow(1 - attack, 2.5))
        let alpha = fade(after: 0.28)
        for side: CGFloat in [-1, 1] {
            let path = points(to: head) { u in
                CGPoint(x: 480 * u, y: side * sin(.pi * u) * (6 + 11 * sin(18 * u - 2 * .pi * t)))
            }
            let tint = side > 0 ? color : accent
            line(path, tint, 13, 0.17 * alpha)
            line(path, tint, 4.2, alpha)
        }
        line([.zero, CGPoint(x: head * 480, y: 0)], .white, 2.2, alpha)
        shine(CGPoint(x: 480 * head, y: 0), 5 * alpha, alpha)
    }

    private func ink() {
        // The brush stamps down, drags under pressure, then flicks a hooked, split nib.
        let head = 0.09 + 0.46 * sin(unit(attack / 0.48) * .pi / 2) + 0.45 * ease((attack - 0.52) / 0.48)
        func strokePoint(_ u: CGFloat) -> CGPoint {
            let hook = unit((u - 0.78) / 0.22)
            return CGPoint(x: 480 * u + 30 * sin(.pi * hook), y: -56 * sin(.pi * u) - 29 * sin(.pi * hook))
        }
        func pressure(_ u: CGFloat) -> CGFloat {
            (1 - pow(u, 2)) * (5 + 23 * pow(sin(.pi * u), 2)) + 2
        }
        let alpha = fade(after: 0.56)
        let upper = points(to: head) { strokePoint($0).offset(0, pressure($0)) }
        let lower = points(from: head, to: 0) { strokePoint($0).offset(0, -pressure($0)) }
        dot(strokePoint(head), pressure(head) * 0.96, style.coreColor, alpha)
        polygon(upper + lower, style.coreColor, alpha)
        line(upper, color, 1.8, alpha)
        line(lower, accent, 2, alpha)
        for i in 0..<6 {
            let lane = (CGFloat(i) / 5 - 0.5) * 1.7
            line(
                points(to: head) { u in
                    strokePoint(u).offset(0, lane * pressure(u) + sin(24 * u + CGFloat(i)))
                },
                i.isMultiple(of: 3) ? color : .lightGray, 1.1, alpha * 0.70)
        }
        for i in 0..<20 {
            let u = noise(i + 6)
            if u <= head {
                let p = strokePoint(u).offset(0, (noise(i + 40) - 0.5) * 94 * sin(.pi * u))
                dot(p, 1 + 4 * noise(i), i.isMultiple(of: 4) ? color : style.coreColor, alpha)
            }
        }
    }
}

extension CGPoint {
    fileprivate func offset(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: x + dx, y: y + dy) }
}

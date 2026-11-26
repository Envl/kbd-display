import AppKit

/// Keep the sampled color with the image so both boards can redraw without resampling.
final class KeyArtwork {
    let image: NSImage
    let colors: KeyColors

    init(_ image: NSImage) {
        self.image = image
        var rect = CGRect(x: 0, y: 0, width: 64, height: 64)
        colors = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            .flatMap(KeyColors.extract) ?? .fallback
    }
}

struct KeyColors {
    let background: NSColor
    let foreground: NSColor

    static let fallback = KeyColors(background: NSColor(srgbRed: 0.06, green: 0.29, blue: 0.36, alpha: 1),
                                    foreground: .white)

    private struct Bucket {
        var sum = SIMD3<Int32>.zero
        var count = 0
        var score = 0.0

        mutating func add(_ rgb: SIMD3<Int32>, weight: Double) {
            sum &+= rgb
            count += 1
            score += weight
        }
    }

    /// Neo Knots' CoverAccentColor main-color algorithm, including its neutral fallback.
    static func extract(_ image: CGImage) -> KeyColors? {
        let side = 36
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let format = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: format) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var dominant = [Bucket](repeating: Bucket(), count: 512)
        var prominent = dominant
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 127 {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            let bin = ((r / 32) << 6) | ((g / 32) << 3) | (b / 32)
            let rgb = SIMD3(Int32(r), Int32(g), Int32(b))
            dominant[bin].add(rgb, weight: 1)
            let brightest = Double(max(r, g, b)) / 255
            let chroma = brightest - Double(min(r, g, b)) / 255
            guard brightest > 0.06, !(chroma < 0.08 && (brightest < 0.16 || brightest > 0.94)) else { continue }
            prominent[bin].add(rgb, weight: 1 + 0.8 * (chroma / brightest))
        }

        let accents = prominent.max { $0.score < $1.score }
        let winner = accents.flatMap { $0.count > 0 ? $0 : nil } ?? dominant.max { $0.count < $1.count }
        guard let winner, winner.count > 0 else { return nil }
        let mean = SIMD3<Double>(winner.sum) / (Double(winner.count) * 255)
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(mean.x) + 0.7152 * linear(mean.y) + 0.0722 * linear(mean.z)
        let whiteContrast = 1.05 / (luminance + 0.05)
        let blackContrast = (luminance + 0.05) / 0.05
        return KeyColors(background: NSColor(srgbRed: mean.x, green: mean.y, blue: mean.z, alpha: 1),
                         foreground: whiteContrast >= blackContrast ? .white : .black)
    }
}

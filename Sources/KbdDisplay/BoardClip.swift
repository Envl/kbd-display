import Foundation

/// Lengths measured on the untrimmed Action75 keyboard, in layout pixels.
struct BoardClip: Equatable {
    let left: Int
    let right: Int
    let top: Int
    let bottom: Int

    static let standard = BoardClip(left: 32, right: 30, top: 14, bottom: 10)!
    static let none = BoardClip(left: 0, right: 0, top: 0, bottom: 0)!

    init?(left: Int, right: Int, top: Int, bottom: Int) {
        let width = Int(Action75.canvas.width), height = Int(Action75.canvas.height)
        guard (0..<width).contains(left), (0..<(width - left)).contains(right),
              (0..<height).contains(top), (0..<(height - top)).contains(bottom) else { return nil }
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
    }

    var visibleRect: CGRect {
        CGRect(x: CGFloat(left), y: CGFloat(top),
               width: Action75.canvas.width - CGFloat(left + right),
               height: Action75.canvas.height - CGFloat(top + bottom))
    }

    func save(to defaults: UserDefaults) {
        defaults.set(["left": left, "right": right, "top": top, "bottom": bottom], forKey: "boardClip")
    }

    static func load(from defaults: UserDefaults) -> Self {
        if let edges = defaults.dictionary(forKey: "boardClip") as? [String: Int],
           let left = edges["left"], let right = edges["right"],
           let top = edges["top"], let bottom = edges["bottom"],
           let clip = Self(left: left, right: right, top: top, bottom: bottom) { return clip }

        // Recover the portion of the keyboard visible in an older panel-space rectangle.
        guard let rect = defaults.array(forKey: "boardRect") as? [Double], rect.count == 4,
              rect.allSatisfy({ (-8192...8192).contains($0) }), rect[2] >= 1, rect[3] >= 1 else { return .standard }
        let width = Action75.canvas.width, height = Action75.canvas.height
        func clipped(_ overflow: Double, extent: Double, layout: CGFloat) -> Int {
            Int((max(0, overflow) / extent * layout).rounded())
        }
        return Self(left: clipped(-rect[0], extent: rect[2], layout: width),
                    right: clipped(rect[0] + rect[2] - width, extent: rect[2], layout: width),
                    top: clipped(-rect[1], extent: rect[3], layout: height),
                    bottom: clipped(rect[1] + rect[3] - height, extent: rect[3], layout: height)) ?? .standard
    }
}

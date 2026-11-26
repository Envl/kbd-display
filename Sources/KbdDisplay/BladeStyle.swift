import AppKit
import Foundation

enum BladeStyle: Int, CaseIterable {
    case plasmaKatana = 0
    case infernoDragon = 1
    case frostbiteCrystal = 2
    case sakuraWind = 3
    case thunderGod = 4
    case voidSingularity = 5
    case rainbowPrism = 6
    case shadowInk = 7
    case foilGlow = 8
    case plasmaBraid = 9

    var title: String {
        switch self {
        case .plasmaKatana: return "Plasma Katana"
        case .infernoDragon: return "Inferno Dragon"
        case .frostbiteCrystal: return "Frostbite"
        case .sakuraWind: return "Sakura Wind"
        case .thunderGod: return "Thunder God"
        case .voidSingularity: return "Void Rift"
        case .rainbowPrism: return "Rainbow Prism"
        case .shadowInk: return "Shadow Ink"
        case .foilGlow: return "Foil Glow"
        case .plasmaBraid: return "Plasma Braid"
        }
    }

    var primaryColor: NSColor {
        switch self {
        case .plasmaKatana, .plasmaBraid: return NSColor(srgbRed: 0.16, green: 0.88, blue: 1.0, alpha: 1)
        case .infernoDragon: return NSColor(srgbRed: 1.0, green: 0.42, blue: 0.08, alpha: 1)
        case .frostbiteCrystal: return NSColor(srgbRed: 0.48, green: 0.90, blue: 1.0, alpha: 1)
        case .sakuraWind: return NSColor(srgbRed: 1.0, green: 0.46, blue: 0.72, alpha: 1)
        case .thunderGod: return NSColor(srgbRed: 0.48, green: 0.78, blue: 1.0, alpha: 1)
        case .voidSingularity: return NSColor(srgbRed: 0.68, green: 0.24, blue: 1.0, alpha: 1)
        case .rainbowPrism: return NSColor(srgbRed: 1.0, green: 0.35, blue: 0.82, alpha: 1)
        case .foilGlow: return .systemTeal
        case .shadowInk: return NSColor(srgbRed: 0.94, green: 0.78, blue: 0.32, alpha: 1)
        }
    }

    var secondaryColor: NSColor {
        switch self {
        case .plasmaKatana, .plasmaBraid: return NSColor(srgbRed: 0.66, green: 0.32, blue: 1.0, alpha: 1)
        case .infernoDragon: return NSColor(srgbRed: 1.0, green: 0.84, blue: 0.18, alpha: 1)
        case .frostbiteCrystal: return NSColor(srgbRed: 0.22, green: 0.56, blue: 1.0, alpha: 1)
        case .sakuraWind: return NSColor(srgbRed: 1.0, green: 0.80, blue: 0.90, alpha: 1)
        case .thunderGod: return NSColor(srgbRed: 0.92, green: 0.96, blue: 1.0, alpha: 1)
        case .voidSingularity: return NSColor(srgbRed: 1.0, green: 0.16, blue: 0.62, alpha: 1)
        case .rainbowPrism: return NSColor(srgbRed: 0.25, green: 0.95, blue: 0.88, alpha: 1)
        case .foilGlow: return .systemYellow
        case .shadowInk: return NSColor(srgbRed: 0.14, green: 0.14, blue: 0.16, alpha: 1)
        }
    }

    var coreColor: NSColor {
        switch self {
        case .voidSingularity: return NSColor(srgbRed: 0.04, green: 0.01, blue: 0.07, alpha: 1)
        case .shadowInk: return NSColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1)
        case .infernoDragon: return NSColor(srgbRed: 1.0, green: 0.97, blue: 0.84, alpha: 1)
        case .sakuraWind: return NSColor(srgbRed: 1.0, green: 0.94, blue: 0.97, alpha: 1)
        default: return .white
        }
    }

    // Contact and the decorative afterglow run on separate clocks.
    static let attackDuration: TimeInterval = 0.085
    var trailLifetime: TimeInterval { 0.32 }

    func color(at progress: CGFloat, time: TimeInterval) -> NSColor {
        switch self {
        case .rainbowPrism:
            let hue = fmod(Double(progress) * 0.85 + time * 0.65, 1.0)
            return NSColor(calibratedHue: CGFloat(hue < 0 ? hue + 1 : hue), saturation: 0.92, brightness: 1.0, alpha: 1)
        default:
            guard let c1 = primaryColor.usingColorSpace(.sRGB),
                  let c2 = secondaryColor.usingColorSpace(.sRGB) else { return primaryColor }
            let t = min(1, max(0, progress))
            return NSColor(
                srgbRed: c1.redComponent + (c2.redComponent - c1.redComponent) * t,
                green: c1.greenComponent + (c2.greenComponent - c1.greenComponent) * t,
                blue: c1.blueComponent + (c2.blueComponent - c1.blueComponent) * t,
                alpha: 1
            )
        }
    }
}

import AppKit
import XCTest
@testable import KbdDisplay

final class KeyArtworkTests: XCTestCase {
    private func image(columns: [(Int, SIMD4<UInt8>)]) throws -> CGImage {
        XCTAssertEqual(columns.map(\.0).reduce(0, +), 36)
        let row = columns.flatMap { width, pixel in
            Array(repeating: [pixel.x, pixel.y, pixel.z, pixel.w], count: width).flatMap { $0 }
        }
        let pixels = Data(Array(repeating: row, count: 36).flatMap { $0 })
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let format = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        return try XCTUnwrap(CGImage(width: 36, height: 36, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 144, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: format),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    func testProminentColorWeightsSaturationAndAveragesInsideWinningBucket() throws {
        let icon = try image(columns: [(16, .init(128, 128, 128, 255)), (5, .init(192, 0, 0, 255)),
            (5, .init(212, 0, 0, 255)), (5, .init(255, 255, 255, 255)), (5, .zero)])
        let palette = try XCTUnwrap(KeyColors.extract(icon))
        XCTAssertEqual(palette.background.redComponent, 202.0 / 255, accuracy: 0.001)
        XCTAssertEqual(palette.background.greenComponent, 0, accuracy: 0.001)
        XCTAssertEqual(palette.foreground, .white)
    }

    func testMonochromeUsesDominantVisibleColorAndEmptyArtworkUsesFallback() throws {
        let mono = try image(columns: [(6, .init(0, 0, 0, 255)), (12, .init(255, 255, 255, 255)),
                                       (18, .init(0, 127, 0, 127))])
        let palette = try XCTUnwrap(KeyColors.extract(mono))
        XCTAssertEqual(palette.background.redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(palette.foreground, .black)
        let clear = try image(columns: [(36, .zero)])
        XCTAssertNil(KeyColors.extract(clear))
        XCTAssertEqual(KeyArtwork(NSImage(cgImage: clear, size: .zero)).colors.background,
                       KeyColors.fallback.background)
    }

    @MainActor
    func testKeyFillUpdatesWhenArtworkArrivesAndChanges() throws {
        let board = BoardView(frame: CGRect(origin: .zero, size: Action75.canvas))
        let window = NSWindow(contentRect: board.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = board
        board.hints = [KeyHint(keyCode: 3, label: "Finder", symbol: "app", iconID: "finder")]
        let tile = try XCTUnwrap(Action75.rects[3])
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1920, pixelsHigh: 720,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        func fill() throws -> NSColor {
            board.cacheDisplay(in: board.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.colorAt(x: Int(tile.minX + 18), y: Int(tile.minY + 18))?.usingColorSpace(.sRGB))
        }
        XCTAssertLessThan(try fill().redComponent, 0.2)
        for color: SIMD4<UInt8> in [.init(255, 0, 0, 255), .init(0, 255, 0, 255)] {
            let icon = try image(columns: [(36, color)])
            board.icons["finder"] = KeyArtwork(NSImage(cgImage: icon, size: NSSize(width: 36, height: 36)))
            let rendered = try fill()
            XCTAssertEqual(rendered.redComponent, CGFloat(color.x) / 255, accuracy: 0.02)
            XCTAssertEqual(rendered.greenComponent, CGFloat(color.y) / 255, accuracy: 0.02)
        }
    }
}

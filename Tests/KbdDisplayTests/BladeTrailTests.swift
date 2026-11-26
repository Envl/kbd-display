import AppKit
import XCTest
@testable import KbdDisplay

final class BladeTrailTests: XCTestCase {
    func testBladeSilhouettesAndTimingAtTheSameElapsedTime() throws {
        // Each probe measures alpha only, so a palette change cannot satisfy these checks.
        let width = 544, height = 200
        let cg = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bytes = try XCTUnwrap(cg.data).assumingMemoryBound(to: UInt8.self)
        func sample(_ style: BladeStyle, _ elapsed: TimeInterval) -> [Bool] {
            cg.clear(CGRect(x: 0, y: 0, width: width, height: height))
            BladeTrailRenderer.draw(style, from: CGPoint(x: 32, y: 100), to: CGPoint(x: 512, y: 100),
                thickness: 10, elapsed: elapsed, opacity: 1, seed: 0, in: cg)
            return [32, 272, 512].map { x in
                (0..<height).contains { y in bytes[y * cg.bytesPerRow + x * 4 + 3] > 8 }
            }
        }
        XCTAssertEqual(sample(.voidSingularity, 0.018), [true, false, true])
        XCTAssertEqual(sample(.thunderGod, 0.018), [true, true, true])
        for style in BladeStyle.allCases {
            XCTAssertTrue(sample(style, 0.09)[2], "\(style.title) must reach the destination in the opening attack")
            XCTAssertEqual(sample(style, 0.33), [false, false, false], style.title)
        }
    }
}

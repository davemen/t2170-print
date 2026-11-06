import CoreGraphics
import CoreImage
import Testing
@testable import T2170Print

/// Print modes through the same CIContext options the renderer uses. Values are sRGB-encoded 0-255.
@Suite struct ColorPipelineTests {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func context() -> CIContext {
        CIContext(options: [.workingColorSpace: sRGB, .outputColorSpace: sRGB])
    }

    static func swatch(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> CGImage {
        let c = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: sRGB,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        c.setFillColor(CGColor(colorSpace: sRGB, components: [CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, 1])!)
        c.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return c.makeImage()!
    }

    static func pixel(_ image: CGImage) -> [Int] {
        var out = [UInt8](repeating: 0, count: 4 * 4 * 4)
        let c = CGContext(data: &out, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: sRGB,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        c.draw(image, in: CGRect(x: 0, y: 0, width: 4, height: 4))
        return out[0..<3].map(Int.init)
    }

    static func run(_ mode: PrintMode, _ rgb: (UInt8, UInt8, UInt8)) -> [Int] {
        var s = PrintSettings()
        s.printMode = mode
        return pixel(ColorPipeline.apply(s, to: swatch(rgb.0, rgb.1, rgb.2), context: context()))
    }

    @Test(arguments: [
        (UInt8(255), UInt8(0), UInt8(0), 54), (0, 255, 0, 182), (0, 0, 255, 18),
        (255, 255, 255, 255), (0, 0, 0, 0), (128, 128, 128, 128),
    ])
    func blackModeGivesTrueLuma(r: UInt8, g: UInt8, b: UInt8, want: Int) {
        let got = Self.run(.black, (r, g, b))
        #expect(got.allSatisfy { abs($0 - want) <= 2 }, "\(got), want \(want)")
    }

    @Test(arguments: [
        (UInt8(255), UInt8(255), UInt8(255), 255), (0, 0, 0, 0), (255, 0, 0, 0), (0, 255, 0, 255),
        (0, 0, 255, 0), (100, 100, 100, 0), (160, 160, 160, 255),
    ])
    func biLevelIsPureBlackOrWhite(r: UInt8, g: UInt8, b: UInt8, want: Int) {
        let got = Self.run(.blackBiLevel, (r, g, b))
        #expect(got == [want, want, want], "\(got), want \(want)")
    }

    @Test func thinLinesLeaveFlatGreyAlone() {
        var s = PrintSettings()
        s.emphasizeThinLines = true
        let got = Self.pixel(ColorPipeline.apply(s, to: Self.swatch(128, 128, 128), context: Self.context()))
        #expect(got.allSatisfy { abs($0 - 128) <= 2 }, "\(got)")
    }
}

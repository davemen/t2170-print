import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import T2170Print

private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

@Suite("Media source matching")
struct MediaSourceTests {
    private func caps(_ sources: [String]) -> PrinterCapabilities {
        var c = PrinterCapabilities(attributes: [])
        c.mediaSourceSupported = sources
        return c
    }

    @Test("Exact keywords win, and an empty list keeps the default")
    func exact() {
        #expect(JobAttributesBuilder.mediaSourceKeyword(for: .rollPaper, capabilities: caps(["auto", "roll-1"])) == "roll-1")
        #expect(JobAttributesBuilder.mediaSourceKeyword(for: .rollPaper, capabilities: caps([])) == "roll-1")
        #expect(JobAttributesBuilder.mediaSourceKeyword(for: .rollPaper, capabilities: nil) == "roll-1")
    }

    @Test("Another name for the same source is found")
    func nearby() {
        let c = caps(["main-roll", "by-pass-tray"])
        #expect(JobAttributesBuilder.mediaSourceKeyword(for: .rollPaper, capabilities: c) == "main-roll")
        #expect(JobAttributesBuilder.mediaSourceKeyword(for: .sheet, capabilities: c) == "by-pass-tray")
    }

    @Test("A cut-sheet source never lands on a roll, and no match is left out")
    func noMatch() {
        #expect(JobAttributesBuilder.mediaSourceKeyword(for: .sheet, capabilities: caps(["main-roll"])) == nil)
        #expect(JobAttributesBuilder.mediaSourceKeyword(for: .autoSheetFeeder, capabilities: caps(["main-roll"])) == nil)
        #expect(JobAttributesBuilder.mediaSourceKeyword(for: .rollPaper, capabilities: caps(["manual", "tray-1"])) == nil)
    }

    @Test("A source only named in the media database counts as listed")
    func database() {
        var c = caps(["auto"])
        c.mediaColDatabase = [MediaColEntry(xDimension: 29700, yDimension: 100000, source: "roll-1", isRoll: true)]
        #expect(JobAttributesBuilder.mediaSourceKeyword(for: .rollPaper, capabilities: c) == "roll-1")
    }
}

@Suite("Print readiness")
struct PrintReadinessTests {
    private var roll: PrintSettings {
        var s = PrintSettings()
        s.paperSource = .rollPaper
        s.rollWidth = .a3
        return s
    }

    private func ready(_ x: Int, max: Int? = nil) -> PrinterCapabilities {
        var c = PrinterCapabilities(attributes: [])
        c.mediaColReady = [MediaColEntry(xDimension: x, xDimensionMax: max, yDimension: 10000, yDimensionMax: 1_800_000,
                                         source: "roll-1", isRoll: true)]
        return c
    }

    @Test("Nothing known means go ahead")
    func unknown() {
        #expect(PrintReadiness.refusal(settings: roll, capabilities: PrinterCapabilities(attributes: [])) == nil)
    }

    @Test("Not accepting jobs refuses; a missing answer does not")
    func accepting() {
        var c = PrinterCapabilities(attributes: [])
        c.isAcceptingJobs = false
        #expect(PrintReadiness.refusal(settings: roll, capabilities: c) == .notAccepting)
        c.isAcceptingJobs = true
        #expect(PrintReadiness.refusal(settings: roll, capabilities: c) == nil)
    }

    @Test("Only a stopped printer with an error reason refuses")
    func stopped() {
        var c = PrinterCapabilities(attributes: [])
        c.state = 5
        c.stateReasons = ["media-empty-error", "toner-low-report"]
        #expect(PrintReadiness.refusal(settings: roll, capabilities: c) == .stopped(reasons: ["media-empty-error"]))
        c.stateReasons = ["media-low-warning", "paused-report"]
        #expect(PrintReadiness.refusal(settings: roll, capabilities: c) == nil)
        c.state = 4
        c.stateReasons = ["media-empty-error"]
        #expect(PrintReadiness.refusal(settings: roll, capabilities: c) == nil)
    }

    @Test("A different roll on the printer refuses and names both")
    func wrongRoll() {
        let refusal = PrintReadiness.refusal(settings: roll, capabilities: ready(43180))
        #expect(refusal == .rollMismatch(setting: RollWidth.a3.label, loaded: RollWidth.w17in.label))
    }

    @Test("The set roll, a range, an unlisted roll and cut sheets all go ahead")
    func rollPasses() {
        #expect(PrintReadiness.refusal(settings: roll, capabilities: ready(29700)) == nil)
        #expect(PrintReadiness.refusal(settings: roll, capabilities: ready(29800)) == nil)
        #expect(PrintReadiness.refusal(settings: roll, capabilities: ready(25400, max: 61000)) == nil)
        #expect(PrintReadiness.refusal(settings: roll, capabilities: ready(35000)) == nil)
        var sheet = roll
        sheet.paperSource = .sheet
        #expect(PrintReadiness.refusal(settings: sheet, capabilities: ready(43180)) == nil)
    }

    @Test("A sheet wider than the roll both ways round is refused")
    func width() {
        var s = PrintSettings()
        s.paperSource = .rollPaper
        s.rollWidth = .w24in
        let fits = SheetPlan(sheetSizePt: CGSize(width: 1728, height: 3000), cells: [])
        let tooWide = SheetPlan(sheetSizePt: CGSize(width: 2000, height: 3000), cells: [])
        #expect(PrintReadiness.widthRefusal(plans: [fits], settings: s) == nil)
        #expect(PrintReadiness.widthRefusal(plans: [fits, tooWide], settings: s) == .sheetWiderThanRoll(setting: RollWidth.w24in.label))
    }

    @Test("Disk check counts the spool twice and skips when the answer is unknown")
    func disk() {
        #expect(PrintReadiness.diskRefusal(rasterBytes: 100, available: 200) == nil)
        #expect(PrintReadiness.diskRefusal(rasterBytes: 100, available: 199) == .notEnoughSpace(needed: 200, available: 199))
        #expect(PrintReadiness.diskRefusal(rasterBytes: 100, available: nil) == nil)
        #expect(PrintReadiness.diskRefusal(rasterBytes: 100, available: 0) == nil)
    }

    @Test("Raster size follows the sheet, the resolution and the colour depth")
    func rasterSize() {
        var s = PrintSettings()
        s.paperSource = .sheet
        s.paperSize = PaperSize.standard[0]
        let plans = Imposer.plan(settings: s, pageSizes: [CGSize(width: 595, height: 842)])
        let gray = PrintReadiness.rasterBytes(plans: plans, settings: s, dpi: 300, gray: true)
        #expect(PrintReadiness.rasterBytes(plans: plans, settings: s, dpi: 300, gray: false) == gray * 3)
        #expect(gray > 1_000_000)
    }
}

enum Corner: String, Sendable { case red, green, blue, white, other }

private func classify(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Corner {
    switch (r > 160, g > 160, b > 160) {
    case (true, false, false): .red
    case (false, true, false): .green
    case (false, false, true): .blue
    case (true, true, true): .white
    default: .other
    }
}

private func pixels(_ image: CGImage) throws -> (data: [UInt8], width: Int, height: Int) {
    let width = image.width, height = image.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    try data.withUnsafeMutableBytes { raw in
        let ctx = try #require(CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                         bytesPerRow: width * 4, space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return (data, width, height)
}

@Suite("Photo orientation")
struct OrientationTests {
    /// 80x40, stored with red, green / blue, white quadrants.
    private func jpeg(orientation: Int) throws -> URL {
        let ctx = try #require(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // CG's origin is bottom left, so the stored top row is y >= 20.
        let fills: [(CGRect, CGColor)] = [
            (CGRect(x: 0, y: 20, width: 40, height: 20), CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)),
            (CGRect(x: 40, y: 20, width: 40, height: 20), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)),
            (CGRect(x: 0, y: 0, width: 40, height: 20), CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)),
            (CGRect(x: 40, y: 0, width: 40, height: 20), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)),
        ]
        for (rect, color) in fills {
            ctx.setFillColor(color)
            ctx.fill(rect)
        }
        let image = try #require(ctx.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 1.0,
        ] as CFDictionary)
        try #require(CGImageDestinationFinalize(dest))
        return url
    }

    // Top left, top right, bottom left, bottom right as seen on screen, from the EXIF definitions.
    private static let shown: [Int: [Corner]] = [
        1: [.red, .green, .blue, .white],
        2: [.green, .red, .white, .blue],
        3: [.white, .blue, .green, .red],
        4: [.blue, .white, .red, .green],
        5: [.red, .blue, .green, .white],
        6: [.blue, .red, .white, .green],
        7: [.white, .green, .blue, .red],
        8: [.green, .white, .red, .blue],
    ]

    @Test("Every EXIF orientation comes out the way it displays", arguments: 1...8)
    func orientation(value: Int) throws {
        let expected = try #require(Self.shown[value])
        let url = try jpeg(orientation: value)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try PageSource.load(url: url)
        guard case .images(let images) = source, let image = images.first else {
            Issue.record("expected an image source")
            return
        }
        let (data, width, height) = try pixels(image)
        #expect(width == (value >= 5 ? 40 : 80))
        #expect(height == (value >= 5 ? 80 : 40))
        let size = source.pageSizePt(0)
        #expect((size.width > size.height) == (value < 5))
        let found = [(1, 1), (3, 1), (1, 3), (3, 3)].map { qx, qy -> Corner in
            let at = ((height * qy / 4) * width + width * qx / 4) * 4
            return classify(data[at], data[at + 1], data[at + 2])
        }
        #expect(found == expected)
    }
}

@Suite("Band slices of a PDF page")
struct BandSliceTests {
    private func pdf(size: CGSize, draw: @escaping (CGContext) -> Void) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size))
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            draw(context.cgContext)
        }
        return url
    }

    /// Non-neutral colour, so PDF pages take the rasterised path that slices rather than drawing vectors.
    private func sheetSettings() -> PrintSettings {
        var s = PrintSettings()
        s.paperSource = .sheet
        s.paperSize = PaperSize.standard[0]
        s.colorMode = .businessGraphics
        return s
    }

    /// The same steps as `SheetComposer.composeRaster`, for rows firstRow..<firstRow+rows of the media.
    private func band(plan: SheetPlan, source: PageSource, settings: PrintSettings, dpi: Int,
                      firstRow: Int, rows: Int) throws -> (data: [UInt8], width: Int, height: Int) {
        let geometry = MediaGeometry(plan: plan, settings: settings)
        let mediaPt = geometry.mediaPt
        let width = max(1, Int((mediaPt.width / 72.0 * CGFloat(dpi)).rounded()))
        let height = max(1, Int((mediaPt.height / 72.0 * CGFloat(dpi)).rounded()))
        var data = [UInt8](repeating: 255, count: width * rows * 4)
        let ci = CIContext(options: [.workingColorSpace: sRGB, .outputColorSpace: sRGB])
        try data.withUnsafeMutableBytes { raw in
            let ctx = try #require(CGContext(data: raw.baseAddress, width: width, height: rows, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            ctx.translateBy(x: 0, y: CGFloat(rows))
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: 0, y: -CGFloat(firstRow))
            ctx.scaleBy(x: CGFloat(width) / mediaPt.width, y: CGFloat(height) / mediaPt.height)
            ctx.concatenate(geometry.sheetToMedia)
            try SheetComposer.drawSheet(plan: plan, source: source, settings: settings, in: ctx,
                                        scale: CGFloat(dpi) / 72.0, ciContext: ci)
        }
        return (data, width, height)
    }

    private func compareStitched(rotation: Int) throws {
        let url = try pdf(size: CGSize(width: 595, height: 842)) { cg in
            cg.setStrokeColor(UIColor.black.cgColor)
            cg.setLineWidth(1)
            for x in stride(from: -842, to: 595, by: 23) {
                cg.move(to: CGPoint(x: x, y: 0)); cg.addLine(to: CGPoint(x: x + 842, y: 842))
            }
            cg.strokePath()
            cg.setFillColor(UIColor.red.cgColor)
            cg.fill(CGRect(x: 100, y: 100, width: 200, height: 300))
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try PageSource.load(url: url)
        let settings = sheetSettings()
        var plan = try #require(Imposer.plan(settings: settings, pageSizes: [CGSize(width: 595, height: 842)]).first)
        plan.cells[0].rotation = rotation
        let dpi = 150
        let probe = try band(plan: plan, source: source, settings: settings, dpi: dpi, firstRow: 0, rows: 1)
        let whole = try band(plan: plan, source: source, settings: settings, dpi: dpi, firstRow: 0, rows: probe.height)

        var stitched: [UInt8] = []
        var row = 0
        while row < whole.height {
            let rows = min(97, whole.height - row)
            stitched += try band(plan: plan, source: source, settings: settings, dpi: dpi, firstRow: row, rows: rows).data
            row += rows
        }
        #expect(stitched.count == whole.data.count)
        var far = 0
        for i in stride(from: 0, to: stitched.count, by: 4) where abs(Int(stitched[i]) - Int(whole.data[i])) > 96 {
            far += 1
        }
        let share = Double(far) / Double(whole.width * whole.height)
        print("BAND rotation \(rotation): \(far) far pixels, share \(share)")
        // Slices land on page pixels, so a thin line may shift by under a pixel. A dropped or doubled row
        // along 1 pt diagonals would show as far more than this.
        #expect(share < 0.002)
    }

    @Test("Stitched bands match one whole render", arguments: [0, 90])
    func stitched(rotation: Int) throws {
        try compareStitched(rotation: rotation)
    }

    @Test("A one-pixel line pattern stays sharp on a page far over the render cap")
    func longPageStaysSharp() throws {
        // 24 x 200 in at 300 dpi is 432 MP, over ten times maxRasterPixels: a whole-page render would
        // smear these lines to flat grey.
        let page = CGSize(width: 1728, height: 14400)
        let url = try pdf(size: page) { cg in
            cg.setFillColor(UIColor.black.cgColor)
            for i in 0..<100 {
                cg.fill(CGRect(x: 0, y: 7200 + CGFloat(i) * 0.48, width: 1728, height: 0.24))
            }
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try PageSource.load(url: url)
        var settings = PrintSettings()
        settings.paperSource = .rollPaper
        settings.rollWidth = .w24in
        settings.outputSize = .fitToRollPaperWidth
        settings.colorMode = .businessGraphics
        let plan = try #require(Imposer.plan(settings: settings, pageSizes: [page]).first)
        let cell = try #require(plan.cells.first)
        let dpi = 300
        let scale = cell.frame.width / page.width
        let firstRow = Int((cell.frame.minY + 7200 * scale) / 72 * CGFloat(dpi)) + 20
        let rows = 120
        let out = try band(plan: plan, source: source, settings: settings, dpi: dpi, firstRow: firstRow, rows: rows)
        #expect(out.width > 7000)
        let x = out.width / 2
        let lumas = (0..<rows).map { Int(out.data[($0 * out.width + x) * 4 + 1]) }
        let contrast = (lumas.max() ?? 0) - (lumas.min() ?? 0)
        print("BAND long page contrast \(contrast), darkest \(lumas.min() ?? -1)")
        #expect(contrast > 120)
    }

    @Test("A page that can't be drawn stops the job instead of printing a blank")
    func missingPageThrows() throws {
        let ctx = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let source = PageSource.images([try #require(ctx.makeImage())])
        let settings = sheetSettings()
        var plan = try #require(Imposer.plan(settings: settings, pageSizes: [CGSize(width: 8, height: 8)]).first)
        plan.cells[0].sourcePage = 5
        do {
            _ = try band(plan: plan, source: source, settings: settings, dpi: 72, firstRow: 0, rows: 10)
            Issue.record("drawing a missing page should throw")
        } catch SheetComposerError.pageRenderFailed(let page) {
            #expect(page == 6)
        }
    }
}

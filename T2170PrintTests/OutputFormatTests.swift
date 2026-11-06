import CoreGraphics
import Foundation
import Testing
@testable import T2170Print

private func caps(formats: [String], urf: [String] = [], pwgTypes: [String] = [], pwgRes: [(Int32, Int32, Int8)] = []) -> PrinterCapabilities {
    var c = PrinterCapabilities(attributes: [])
    c.documentFormatSupported = formats
    c.urfSupported = urf
    c.pwgRasterTypesSupported = pwgTypes
    c.pwgRasterResolutions = pwgRes.map { PrinterResolution(x: Int($0.0), y: Int($0.1), units: Int($0.2)) }
    return c
}

@Suite("Output format selection")
struct OutputFormatTests {
    private let all = caps(
        formats: ["application/pdf", "image/pwg-raster", "image/urf", "image/jpeg"],
        urf: ["V1.4", "CP1", "RS300-600", "W8", "SRGB24"],
        pwgTypes: ["sgray_8", "srgb_8"],
        pwgRes: [(300, 300, 3), (600, 600, 3)]
    )

    @Test("Automatic order is URF, PWG, then PDF")
    func order() {
        let list = OutputFormatSelector.candidates(capabilities: all, choice: .automatic, printQuality: 4, colorMode: "color")
        #expect(list.map(\.mimeType) == ["image/urf", "image/pwg-raster", "application/pdf"])
    }

    @Test("A named choice gives only that format")
    func named() {
        let list = OutputFormatSelector.candidates(capabilities: all, choice: .pwgRaster, printQuality: 4, colorMode: "color")
        #expect(list.map(\.mimeType) == ["image/pwg-raster"])
    }

    @Test("A printer listing PDF only gets PDF")
    func pdfOnly() {
        let list = OutputFormatSelector.candidates(capabilities: caps(formats: ["application/pdf"]), choice: .automatic, printQuality: 4, colorMode: "color")
        #expect(list.map(\.kind) == [.pdf])
    }

    @Test("Listing a raster format without its details does not offer it")
    func rasterNeedsDetails() {
        let c = caps(formats: ["image/urf", "image/pwg-raster"])
        let list = OutputFormatSelector.candidates(capabilities: c, choice: .automatic, printQuality: 4, colorMode: "color")
        #expect(list.isEmpty)
    }

    @Test("Format names match regardless of case")
    func caseInsensitive() {
        let c = caps(formats: ["IMAGE/URF"], urf: ["RS300", "SRGB24"])
        #expect(OutputFormatSelector.candidates(capabilities: c, choice: .automatic, printQuality: 4, colorMode: "color").count == 1)
    }

    @Test("URF resolution tokens: list, range style and junk", arguments: [
        (["RS300"], [300]),
        (["RS300-600"], [300, 600]),
        (["RS300-600-1200"], [300, 600, 1200]),
        (["V1.4", "W8"], [Int]()),
        (["RSx"], [Int]())
    ])
    func urfTokens(tokens: [String], want: [Int]) {
        #expect(OutputFormatSelector.urfResolutions(tokens).sorted() == want)
    }

    @Test("PWG resolutions: dpi kept, dpcm converted, unequal ignored")
    func pwgUnits() {
        let list = OutputFormatSelector.pwgResolutions([
            PrinterResolution(x: 300, y: 300, units: 3),
            PrinterResolution(x: 236, y: 236, units: 4),
            PrinterResolution(x: 600, y: 300, units: 3)
        ])
        #expect(list.sorted() == [300, 599])
    }

    @Test("DPI choice", arguments: [
        ([300, 600], false, 300), ([300, 600], true, 600),
        ([150, 200], false, 200), ([150], true, 150),
        ([300, 600, 1200], true, 600), ([1200], true, 1200), ([1200], false, 1200)
    ])
    func dpi(available: [Int], high: Bool, want: Int) {
        #expect(OutputFormatSelector.chooseDPI(available: available, highQuality: high) == want)
    }

    @Test("High quality asks for the higher resolution")
    func highQualityDPI() {
        #expect(OutputFormatSelector.candidates(capabilities: all, choice: .urf, printQuality: 5, colorMode: "color").first?.dpi == 600)
        #expect(OutputFormatSelector.candidates(capabilities: all, choice: .urf, printQuality: 4, colorMode: "color").first?.dpi == 300)
    }

    @Test("Colour mode decides grey output")
    func grey() {
        #expect(OutputFormatSelector.candidates(capabilities: all, choice: .urf, printQuality: 4, colorMode: "color").first?.gray == false)
        #expect(OutputFormatSelector.candidates(capabilities: all, choice: .urf, printQuality: 4, colorMode: "monochrome").first?.gray == true)
    }

    @Test("A colour job is never sent to a grey-only raster")
    func colourNeedsColour() {
        let c = caps(formats: ["image/urf"], urf: ["RS300", "W8"])
        #expect(OutputFormatSelector.candidates(capabilities: c, choice: .automatic, printQuality: 4, colorMode: "color").isEmpty)
    }

    @Test("Send as picker lists what the printer can take")
    func picker() {
        #expect(OutputFormatSelector.availableChoices(capabilities: all) == [.automatic, .urf, .pwgRaster, .pdf])
        #expect(OutputFormatSelector.availableChoices(capabilities: caps(formats: ["application/pdf"])) == [.automatic, .pdf])
    }

    @Test("Attributes parse from a real IPP group")
    func parse() {
        let c = PrinterCapabilities(attributes: [
            IPPAttribute(name: "urf-supported", values: [.keyword("RS300"), .keyword("SRGB24")]),
            IPPAttribute(name: "pwg-raster-document-type-supported", values: [.keyword("srgb_8")]),
        ])
        #expect(c.urfSupported == ["RS300", "SRGB24"])
        #expect(c.pwgRasterTypesSupported == ["srgb_8"])
        #expect(!c.vendor.keys.contains("urf-supported"))
    }
}

@Suite("Media geometry and batches")
struct MediaGeometryTests {
    @Test("A sheet wider than the 24-inch roll turns so its short side runs across")
    func rollRotates() {
        let g = MediaGeometry(sheetPt: CGSize(width: 2000, height: 1000), paperSource: .rollPaper, rollWidthMM: 610)
        #expect(g.rotated)
        #expect(g.mediaPt == CGSize(width: 1000, height: 2000))
    }

    @Test("A sheet that fits the roll stays put even when landscape")
    func rollKeeps() {
        let g = MediaGeometry(sheetPt: CGSize(width: 1500, height: 1000), paperSource: .rollPaper, rollWidthMM: 610)
        #expect(!g.rotated)
    }

    @Test("A sheet too big for the roll either way is not rotated")
    func rollTooBig() {
        let g = MediaGeometry(sheetPt: CGSize(width: 3000, height: 2000), paperSource: .rollPaper, rollWidthMM: 610)
        #expect(!g.rotated)
    }

    @Test("Landscape cut sheets rotate to portrait media", arguments: [PaperSource.sheet, PaperSource.autoSheetFeeder])
    func cutSheet(source: PaperSource) {
        let g = MediaGeometry(sheetPt: CGSize(width: 842, height: 595), paperSource: source, rollWidthMM: 610)
        #expect(g.rotated)
        #expect(g.mediaPt == CGSize(width: 595, height: 842))
    }

    @Test("Rotation maps every corner on to the media, no flip")
    func corners() {
        let g = MediaGeometry(sheetPt: CGSize(width: 800, height: 500), paperSource: .sheet, rollWidthMM: 610)
        let t = g.sheetToMedia
        #expect(CGPoint(x: 0, y: 0).applying(t) == CGPoint(x: 0, y: 800))
        #expect(CGPoint(x: 800, y: 0).applying(t) == CGPoint(x: 0, y: 0))
        #expect(CGPoint(x: 800, y: 500).applying(t) == CGPoint(x: 500, y: 0))
        #expect(CGPoint(x: 0, y: 500).applying(t) == CGPoint(x: 500, y: 800))
        #expect(t.a * t.d - t.b * t.c > 0, "determinant must be positive or the page is mirrored")
    }

    @Test("Consecutive plans group by media size; a return to an earlier size starts a new batch")
    func batches() {
        var s = PrintSettings()
        s.paperSource = .sheet
        func plan(_ w: CGFloat, _ h: CGFloat) -> SheetPlan {
            SheetPlan(sheetSizePt: CGSize(width: w, height: h), cells: [])
        }
        let batches = PrintBatch.make(plans: [plan(595, 842), plan(842, 595), plan(1190, 842), plan(595, 842)], settings: s)
        #expect(batches.map(\.plans.count) == [2, 1, 1])
    }
}

@Suite("Job attributes after the copies and media fixes")
struct JobAttributeFixTests {
    @Test("Copies are drawn into the document, so IPP copies stays 1")
    func copiesNotSquared() {
        var s = PrintSettings()
        s.copies = 3
        let (attributes, _) = JobAttributesBuilder.attributes(for: s)
        #expect(attributes.first { $0.name == "copies" }?.intValue == 1)
    }

    @Test("Media size snaps to a database entry within half a millimetre")
    func snaps() {
        let db = [MediaColEntry(xDimension: 21000, yDimension: 29700), MediaColEntry(xDimension: 21590, yDimension: 27940)]
        let hit = JobAttributesBuilder.snappedMediaSize(x: 21002, y: 29690, database: db)
        #expect(hit.x == 21000 && hit.y == 29700)
        let miss = JobAttributesBuilder.snappedMediaSize(x: 21100, y: 29700, database: db)
        #expect(miss.x == 21100 && miss.y == 29700)
    }

    @Test("Roll width snaps to the roll entry and keeps the requested length")
    func snapsRoll() {
        let db = [MediaColEntry(xDimension: 60960, yDimension: 10000, yDimensionMax: 1_800_000, isRoll: true)]
        let hit = JobAttributesBuilder.snappedMediaSize(x: 60950, y: 250_000, database: db)
        #expect(hit.x == 60960 && hit.y == 250_000)
        let tooLong = JobAttributesBuilder.snappedMediaSize(x: 60950, y: 2_000_000, database: db)
        #expect(tooLong.x == 60950)
    }
}

@Suite("Raster rendering")
struct RasterRenderTests {
    private func image(width: Int, height: Int) throws -> CGImage {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Diagonal stripes cross every band edge, so a seam shows up as a byte difference.
        ctx.setStrokeColor(CGColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1))
        ctx.setLineWidth(7)
        for x in stride(from: -height, to: width, by: 41) {
            ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x + height, y: height))
        }
        ctx.strokePath()
        return try #require(ctx.makeImage())
    }

    private func render(budget: Int, format: RasterFormat, gray: Bool) async throws -> Data {
        var settings = PrintSettings()
        settings.paperSource = .sheet
        settings.paperSize = PaperSize.standard[0]
        let source = PageSource.images([try image(width: 620, height: 877)])
        let plans = Imposer.plan(settings: settings, pageSizes: source.pageSizes)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("band-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try await SheetComposer.composeRaster(plans: plans, source: source, settings: settings, format: format,
                                              dpi: 100, gray: gray, quality: 4, to: url, bandPixelBudget: budget)
        return try Data(contentsOf: url)
    }

    /// Comparing band sizes cannot see a shift that moves every band alike, so this measures the page itself:
    /// a block filling the printable area must leave the same margin on opposite sides, and that margin is 3 mm.
    @Test("Content lands on the right pixels, whatever the band size", arguments: [1 << 40, 2480 * 13, 2480 * 101])
    func contentPosition(budget: Int) async throws {
        let dpi = 300, blockW = 2040, blockH = 2910  // 204 x 291 mm: A4 less 3 mm a side
        let ctx = try #require(CGContext(data: nil, width: blockW, height: blockH, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: blockW, height: blockH))
        var settings = PrintSettings()
        settings.paperSource = .sheet
        settings.paperSize = PaperSize.standard[0]
        let source = PageSource.images([try #require(ctx.makeImage())])
        let plans = Imposer.plan(settings: settings, pageSizes: source.pageSizes)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try await SheetComposer.composeRaster(plans: plans, source: source, settings: settings, format: .pwg,
                                              dpi: dpi, gray: true, quality: 4, to: url, bandPixelBudget: budget)
        let bytes = [UInt8](try Data(contentsOf: url))

        let width = 2480, height = 3508
        var at = 4 + 1796, top = -1, bottom = -1, left = width, right = -1, row = 0
        while row < height {
            let repeats = Int(bytes[at]) + 1
            at += 1
            let line = try decodeLine(bytes, from: &at, width: width, bpp: 1)
            if let first = line.firstIndex(where: { $0 < 128 }), let last = line.lastIndex(where: { $0 < 128 }) {
                if top < 0 { top = row }
                bottom = row + repeats - 1
                left = min(left, first)
                right = max(right, last)
            }
            row += repeats
        }
        #expect(row == height)
        #expect(top == height - 1 - bottom, "top \(top), bottom \(height - 1 - bottom)")
        #expect(left == width - 1 - right, "left \(left), right \(width - 1 - right)")
        #expect(abs(top - 35) <= 1 && abs(left - 35) <= 1, "margins \(top), \(left): 3 mm is 35.4 px")
    }

    @Test("Grey conversion keeps black and white exact and equal channels unchanged")
    func luma() {
        for v in UInt8.min...UInt8.max {
            #expect(SheetComposer.rasterLuma(red: v, green: v, blue: v) == v)
        }
        #expect(SheetComposer.rasterLuma(red: 255, green: 0, blue: 0) == 54)
    }

    @Test("Band size changes nothing in the output", arguments: [RasterFormat.urf, .pwg], [false, true])
    func bandsAreInvisible(format: RasterFormat, gray: Bool) async throws {
        let whole = try await render(budget: SheetComposer.defaultBandPixelBudget, format: format, gray: gray)
        #expect(whole.count > 100)
        for budget in [827 * 13, 827 * 64, 827 * 101] {
            let banded = try await render(budget: budget, format: format, gray: gray)
            #expect(banded == whole, "budget \(budget) changed the output")
        }
    }
}

import CoreGraphics
import Foundation
import Testing
@testable import T2170Print

/// Decoder written from the format, separate from the encoder under test.
func decodeLine(_ bytes: [UInt8], from start: inout Int, width: Int, bpp: Int) throws -> [UInt8] {
    var line: [UInt8] = []
    while line.count < width * bpp {
        let op = Int(bytes[start]); start += 1
        try #require(op != 128, "compression byte 128 must never be emitted")
        if op < 128 {
            let px = Array(bytes[start..<start + bpp]); start += bpp
            for _ in 0...op { line += px }
        } else {
            let n = 257 - op
            line += bytes[start..<start + n * bpp]; start += n * bpp
        }
    }
    try #require(line.count == width * bpp, "run passed the end of the line")
    return line
}

private func encoded(_ line: [UInt8], bpp: Int) -> [UInt8] {
    var out: [UInt8] = []
    line.withUnsafeBufferPointer { RasterWriter.encodeLine($0, bytesPerPixel: bpp, into: &out) }
    return out
}

private func write(_ format: RasterFormat, pages: [(RasterPageSpec, [[UInt8]])]) throws -> [UInt8] {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("enc-\(UUID().uuidString).raster")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: url) }
    let handle = try FileHandle(forWritingTo: url)
    let writer = try RasterWriter(format: format, pageCount: pages.count, output: handle)
    for (spec, lines) in pages {
        try writer.beginPage(spec)
        for line in lines { try writer.append(line: line) }
        try writer.endPage()
    }
    try writer.finish()
    try handle.close()
    return [UInt8](try Data(contentsOf: url))
}

private func be32(_ bytes: [UInt8], _ offset: Int) -> Int {
    bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
}

@Suite("Raster line compression")
struct RasterLineTests {
    @Test("Hand-computed lines, one byte per pixel")
    func handComputedGray() {
        #expect(encoded([5], bpp: 1) == [0, 5])
        #expect(encoded([5, 5], bpp: 1) == [1, 5])
        #expect(encoded([5, 5, 5], bpp: 1) == [2, 5])
        #expect(encoded([1, 2], bpp: 1) == [0xFF, 1, 2])
        #expect(encoded([1, 2, 3], bpp: 1) == [0xFE, 1, 2, 3])
        #expect(encoded([1, 2, 2], bpp: 1) == [0, 1, 1, 2])
        #expect(encoded([1, 1, 2], bpp: 1) == [1, 1, 0, 2])
        #expect(encoded([1, 2, 2, 3], bpp: 1) == [0, 1, 1, 2, 0, 3])
    }

    @Test("Hand-computed line, three bytes per pixel")
    func handComputedRGB() {
        #expect(encoded([1, 2, 3, 1, 2, 3, 9, 9, 9], bpp: 3) == [1, 1, 2, 3, 0, 9, 9, 9])
        // Pixels that differ only in the last channel are different pixels.
        #expect(encoded([1, 2, 3, 1, 2, 4], bpp: 3) == [0xFF, 1, 2, 3, 1, 2, 4])
    }

    @Test("Run limit: 128, 129 and 130 identical pixels")
    func runLimits() {
        #expect(encoded([UInt8](repeating: 7, count: 128), bpp: 1) == [127, 7])
        #expect(encoded([UInt8](repeating: 7, count: 129), bpp: 1) == [127, 7, 0, 7])
        #expect(encoded([UInt8](repeating: 7, count: 130), bpp: 1) == [127, 7, 1, 7])
    }

    @Test("Literal limit: 128 distinct pixels is 0x81, and 129 never produces 128")
    func literalLimits() throws {
        let distinct128 = (0..<128).map { UInt8($0) }
        #expect(encoded(distinct128, bpp: 1) == [0x81] + distinct128)
        let distinct129 = (0..<129).map { UInt8($0) }
        let out = encoded(distinct129, bpp: 1)
        #expect(out == [0x81] + distinct128 + [0, 128])
    }

    @Test("Every width from 1 to 300 round-trips on patterned data", arguments: [1, 3])
    func allWidths(bpp: Int) throws {
        var rng = SystemRandomNumberGenerator()
        for width in 1...300 {
            for palette in [2, 3, 256] {
                var line: [UInt8] = []
                for _ in 0..<width {
                    let v = UInt8(Int.random(in: 0..<palette, using: &rng))
                    line += [UInt8](repeating: v, count: bpp)
                }
                let out = encoded(line, bpp: bpp)
                var pos = 0
                #expect(try decodeLine(out, from: &pos, width: width, bpp: bpp) == line)
                #expect(pos == out.count)
            }
        }
    }

    @Test("Wide random lines round-trip, including a 44-inch line at 720 dpi")
    func wideLines() throws {
        var rng = SystemRandomNumberGenerator()
        let width = 44 * 720
        var line = [UInt8](repeating: 255, count: width * 3)
        for i in stride(from: 0, to: line.count, by: 3) where (i / 3 / 97) % 2 == 0 {
            line[i] = UInt8.random(in: 0...255, using: &rng)
        }
        let out = encoded(line, bpp: 3)
        var pos = 0
        #expect(try decodeLine(out, from: &pos, width: width, bpp: 3) == line)
        #expect(pos == out.count)
    }
}

@Suite("Raster file structure")
struct RasterFileTests {
    private let spec = RasterPageSpec(widthPx: 4, heightPx: 600, dpi: 300, gray: true, quality: 5, totalPages: 1, pageSizeName: "custom_a")

    @Test("Identical lines split at the 256-line repeat limit")
    func lineRepeatLimit() throws {
        let lines = [[UInt8]](repeating: [9, 9, 9, 9], count: 600)
        let bytes = try write(.urf, pages: [(spec, lines)])
        // 8 magic + 4 count + 32 header, then groups of 256, 256, 88.
        #expect(Array(bytes[44...]) == [255, 3, 9, 255, 3, 9, 87, 3, 9])
    }

    @Test("Repeat groups end when a line changes and at exactly 256")
    func repeatBoundary() throws {
        var lines = [[UInt8]](repeating: [1, 1, 1, 1], count: 256)
        lines.append([2, 2, 2, 2])
        let page = RasterPageSpec(widthPx: 4, heightPx: 257, dpi: 300, gray: true)
        let bytes = try write(.urf, pages: [(page, lines)])
        #expect(Array(bytes[44...]) == [255, 3, 1, 0, 3, 2])
    }

    @Test("URF file and page headers")
    func urfHeader() throws {
        let page = RasterPageSpec(widthPx: 2, heightPx: 1, dpi: 600, gray: false, quality: 5)
        let bytes = try write(.urf, pages: [(page, [[1, 2, 3, 4, 5, 6]]), (page, [[1, 2, 3, 4, 5, 6]])])
        #expect(Array(bytes[0..<8]) == Array("UNIRAST\0".utf8))
        #expect(be32(bytes, 8) == 2)
        let h = Array(bytes[12..<44])
        #expect(Array(h[0..<4]) == [0x18, 0x01, 0x01, 5])
        #expect(h[4..<12].allSatisfy { $0 == 0 })
        #expect(be32(h, 12) == 2 && be32(h, 16) == 1 && be32(h, 20) == 600)
        #expect(h[24..<32].allSatisfy { $0 == 0 })
    }

    @Test("PWG page header fields sit where PWG 5102.4 puts them")
    func pwgHeader() throws {
        let page = RasterPageSpec(widthPx: 2550, heightPx: 3300, dpi: 300, gray: false, quality: 4, totalPages: 3, pageSizeName: "custom_x")
        let line = [UInt8](repeating: 0, count: 2550 * 3)
        let bytes = try write(.pwg, pages: [(page, [[UInt8]](repeating: line, count: 3300))])
        #expect(Array(bytes[0..<4]) == Array("RaS2".utf8))
        let h = Array(bytes[4..<1800])
        #expect(Array(h[0..<10]) == Array("PwgRaster\0".utf8))
        #expect(be32(h, 276) == 300 && be32(h, 280) == 300)
        #expect(be32(h, 284) == 0 && be32(h, 288) == 0 && be32(h, 292) == 0 && be32(h, 296) == 0)
        #expect(be32(h, 352) == 612 && be32(h, 356) == 792)
        #expect(be32(h, 372) == 2550 && be32(h, 376) == 3300)
        #expect(be32(h, 384) == 8 && be32(h, 388) == 24 && be32(h, 392) == 7650)
        #expect(be32(h, 396) == 0 && be32(h, 400) == 19 && be32(h, 420) == 3)
        #expect(be32(h, 452) == 3 && be32(h, 456) == 1 && be32(h, 460) == 1)
        #expect(be32(h, 480) == 0x00FF_FFFF && be32(h, 484) == 4)
        #expect(String(decoding: h[1732..<1740], as: UTF8.self) == "custom_x")
    }

    @Test("Misuse throws rather than writing a bad file")
    func misuse() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("misuse-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        let writer = try RasterWriter(format: .pwg, pageCount: 1, output: handle)
        #expect(throws: RasterEncoderError.pageNotOpen) { try writer.append(line: [1]) }
        let page = RasterPageSpec(widthPx: 1, heightPx: 2, dpi: 300, gray: true)
        try writer.beginPage(page)
        #expect(throws: RasterEncoderError.wrongLineLength) { try writer.append(line: [1, 2]) }
        try writer.append(line: [1])
        #expect(throws: RasterEncoderError.tooFewLines) { try writer.endPage() }
        try writer.append(line: [1])
        #expect(throws: RasterEncoderError.tooManyLines) { try writer.append(line: [1]) }
        try writer.endPage()
        try writer.finish()
    }
}

/// Runs only when `T2170_RASTERREF` names a folder holding CUPS's own output (see test-sim.sh).
@Suite("Raster encoder against CUPS rastertopwg and rastertourf")
struct RasterReferenceTests {
    static let folder = ProcessInfo.processInfo.environment["T2170_RASTERREF"]
    private let width = 300, height = 150

    private func pages(_ file: String, bpp: Int, count: Int) throws -> [[[UInt8]]] {
        let ras = [UInt8](try Data(contentsOf: URL(fileURLWithPath: "\(Self.folder!)/\(file)")))
        var pos = 4
        return (0..<count).map { _ in
            pos += 1796
            let lines = (0..<height).map { row in
                Array(ras[pos + row * width * bpp ..< pos + (row + 1) * width * bpp])
            }
            pos += width * height * bpp
            return lines
        }
    }

    @Test("URF is byte-identical to rastertourf", .enabled(if: folder != nil), arguments: [("rgb", 3, 2), ("gray", 1, 1)])
    func urfMatches(name: String, bpp: Int, count: Int) throws {
        let spec = RasterPageSpec(widthPx: width, heightPx: height, dpi: 300, gray: bpp == 1, quality: 0, totalPages: count)
        let mine = try write(.urf, pages: try pages("\(name).ras", bpp: bpp, count: count).map { (spec, $0) })
        let theirs = [UInt8](try Data(contentsOf: URL(fileURLWithPath: "\(Self.folder!)/\(name).urf")))
        #expect(mine == theirs)
    }

    @Test("PWG compressed page data is byte-identical to rastertopwg", .enabled(if: folder != nil), arguments: [("rgb", 3, 2), ("gray", 1, 1)])
    func pwgMatches(name: String, bpp: Int, count: Int) throws {
        let spec = RasterPageSpec(widthPx: width, heightPx: height, dpi: 300, gray: bpp == 1, quality: 0, totalPages: count, pageSizeName: "custom_1x0.5in_1x0.5in")
        let mine = try write(.pwg, pages: try pages("\(name).ras", bpp: bpp, count: count).map { (spec, $0) })
        let theirs = [UInt8](try Data(contentsOf: URL(fileURLWithPath: "\(Self.folder!)/\(name).pwg")))
        #expect(mine.count == theirs.count)
        // Headers differ only where the reference filled ImagingBoundingBox, which PWG reserves.
        var diffs: [Int] = []
        for i in 0..<min(mine.count, theirs.count) where mine[i] != theirs[i] { diffs.append(i) }
        let pageBytes = (mine.count - 4) / count
        let outside = diffs.filter { offset in
            let inPage = (offset - 4) % pageBytes
            return !(276...299).contains(inPage) && !(452...455).contains(inPage)
        }
        #expect(outside.isEmpty, "unexpected differences at \(outside.prefix(20))")
    }
}

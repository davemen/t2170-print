import Foundation

/// Raster stream container format accepted by IPP Everywhere and AirPrint printers.
enum RasterFormat: String, Sendable, CaseIterable, Codable {
    case pwg = "image/pwg-raster"
    case urf = "image/urf"

    var mimeType: String { rawValue }
}

/// Per-page geometry and colour parameters written into a PWG Raster or Apple URF page header.
struct RasterPageSpec: Sendable, Equatable {
    var widthPx: Int
    var heightPx: Int
    var dpi: Int
    var gray: Bool
    var quality: Int
    var totalPages: Int
    var pageSizeName: String

    var bytesPerPixel: Int { gray ? 1 : 3 }
    var bytesPerLine: Int { widthPx * bytesPerPixel }

    init(
        widthPx: Int,
        heightPx: Int,
        dpi: Int,
        gray: Bool = false,
        quality: Int = 4,
        totalPages: Int = 1,
        pageSizeName: String = ""
    ) {
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.dpi = dpi
        self.gray = gray
        self.quality = quality
        self.totalPages = totalPages
        self.pageSizeName = pageSizeName
    }
}

/// Errors thrown by `RasterWriter` during PWG Raster or URF encoding.
enum RasterEncoderError: Error, LocalizedError, Sendable, Equatable {
    case invalidPageCount
    case invalidPageSpec
    case invalidBytesPerPixel
    case pageAlreadyOpen
    case pageNotOpen
    case wrongLineLength
    case tooManyLines
    case tooFewLines
    case alreadyFinished

    var errorDescription: String? {
        switch self {
        case .invalidPageCount:
            "Page count must be non-negative and fit in an unsigned 32-bit integer."
        case .invalidPageSpec:
            "Raster page specification has invalid dimensions, resolution, or quality."
        case .invalidBytesPerPixel:
            "Bytes per pixel must be positive."
        case .pageAlreadyOpen:
            "A raster page is already open; call endPage() before beginning a new page or finishing."
        case .pageNotOpen:
            "No raster page is currently open; call beginPage(_:) first."
        case .wrongLineLength:
            "Scanline byte count does not match widthPx * bytesPerPixel."
        case .tooManyLines:
            "Appended more scanlines than heightPx for the current page."
        case .tooFewLines:
            "Page ended before heightPx scanlines were appended."
        case .alreadyFinished:
            "RasterWriter has already finished writing."
        }
    }
}

/// Streaming encoder that writes PWG Raster (`image/pwg-raster`) or Apple URF (`image/urf`)
/// documents to a `FileHandle` using an internal ~1 MB write buffer.
final class RasterWriter {
    static let bufferCapacity = 1_048_576
    static let pwgPageHeaderSize = 1796
    static let urfPageHeaderSize = 32

    private static let pwgFileMagic: [UInt8] = [0x52, 0x61, 0x53, 0x32] // "RaS2"
    private static let urfFileMagic: [UInt8] = [0x55, 0x4E, 0x49, 0x52, 0x41, 0x53, 0x54, 0x00] // "UNIRAST\0"
    private static let pwgHeaderMagic: [UInt8] = [0x50, 0x77, 0x67, 0x52, 0x61, 0x73, 0x74, 0x65, 0x72] // "PwgRaster"

    let format: RasterFormat
    let pageCount: Int
    private let output: FileHandle

    private var buffer: [UInt8] = []
    private var currentSpec: RasterPageSpec?
    private var linesAppended: Int = 0
    private var pendingLine: [UInt8] = []
    private var pendingRepeatCount: Int = 0
    private var isFinished: Bool = false

    /// Creates a streaming raster writer and emits the container file header.
    init(format: RasterFormat, pageCount: Int, output: FileHandle) throws {
        guard pageCount >= 0, pageCount <= Int(UInt32.max) else {
            throw RasterEncoderError.invalidPageCount
        }
        self.format = format
        self.pageCount = pageCount
        self.output = output
        self.buffer.reserveCapacity(Self.bufferCapacity + 65_536)

        switch format {
        case .pwg:
            buffer.append(contentsOf: Self.pwgFileMagic)
        case .urf:
            buffer.append(contentsOf: Self.urfFileMagic)
            var countBytes = [UInt8](repeating: 0, count: 4)
            Self.writeUInt32BE(UInt32(pageCount), into: &countBytes, at: 0)
            buffer.append(contentsOf: countBytes)
        }
        try flushBuffer()
    }

    /// Opens a new page and writes its PWG Raster (1796-byte) or URF (32-byte) page header.
    func beginPage(_ spec: RasterPageSpec) throws {
        guard !isFinished else {
            throw RasterEncoderError.alreadyFinished
        }
        guard currentSpec == nil else {
            throw RasterEncoderError.pageAlreadyOpen
        }
        guard spec.widthPx > 0,
              spec.heightPx > 0,
              spec.dpi > 0,
              spec.totalPages >= 0,
              (0...255).contains(spec.quality) else {
            throw RasterEncoderError.invalidPageSpec
        }

        switch format {
        case .pwg:
            buffer.append(contentsOf: Self.makePWGPageHeader(spec))
        case .urf:
            buffer.append(contentsOf: Self.makeURFPageHeader(spec))
        }

        currentSpec = spec
        linesAppended = 0
        pendingRepeatCount = 0
        let lineBytes = spec.bytesPerLine
        if pendingLine.count != lineBytes {
            pendingLine = [UInt8](repeating: 0, count: lineBytes)
        }

        if buffer.count >= Self.bufferCapacity {
            try flushBuffer()
        }
    }

    /// Appends a single uncompressed scanline (`widthPx * bytesPerPixel` bytes) to the open page.
    func append(line: UnsafeBufferPointer<UInt8>) throws {
        guard !isFinished else {
            throw RasterEncoderError.alreadyFinished
        }
        guard let spec = currentSpec else {
            throw RasterEncoderError.pageNotOpen
        }
        let expectedBytes = spec.bytesPerLine
        guard line.count == expectedBytes, let lineBase = line.baseAddress else {
            throw RasterEncoderError.wrongLineLength
        }
        guard linesAppended < spec.heightPx else {
            throw RasterEncoderError.tooManyLines
        }

        linesAppended += 1
        let bpp = spec.bytesPerPixel

        if pendingRepeatCount > 0 {
            let isIdentical = pendingLine.withUnsafeBufferPointer { pendingPtr -> Bool in
                guard let pendingBase = pendingPtr.baseAddress else { return false }
                return memcmp(pendingBase, lineBase, expectedBytes) == 0
            }
            if isIdentical {
                pendingRepeatCount += 1
                if pendingRepeatCount == 256 {
                    try flushPendingLine(bytesPerPixel: bpp)
                }
                return
            }
            try flushPendingLine(bytesPerPixel: bpp)
        }

        pendingLine.withUnsafeMutableBufferPointer { destPtr in
            if let destBase = destPtr.baseAddress {
                memcpy(destBase, lineBase, expectedBytes)
            }
        }
        pendingRepeatCount = 1
    }

    /// Convenience overload for appending a scanline from a `[UInt8]` array.
    func append(line: [UInt8]) throws {
        try line.withUnsafeBufferPointer { try append(line: $0) }
    }

    /// Flushes any pending line-repeat group and closes the current page, verifying `heightPx` lines were written.
    func endPage() throws {
        guard !isFinished else {
            throw RasterEncoderError.alreadyFinished
        }
        guard let spec = currentSpec else {
            throw RasterEncoderError.pageNotOpen
        }
        guard linesAppended == spec.heightPx else {
            throw RasterEncoderError.tooFewLines
        }

        try flushPendingLine(bytesPerPixel: spec.bytesPerPixel)
        currentSpec = nil
        linesAppended = 0
        try flushBuffer()
    }

    /// Flushes any buffered output to the underlying `FileHandle` and marks the writer finished.
    func finish() throws {
        guard !isFinished else { return }
        guard currentSpec == nil else {
            throw RasterEncoderError.pageAlreadyOpen
        }
        try flushBuffer()
        isFinished = true
    }

    // MARK: - Line Encoding

    /// PackBits-style pixel run-length encoder shared by PWG Raster and Apple URF.
    ///
    /// Walks pixels of `bytesPerPixel` bytes each:
    /// - Last lone pixel: emits byte `0` followed by the pixel.
    /// - Identical next pixel: counts up to 128 identical pixels, emits `count - 1`, then the pixel once.
    /// - Otherwise literal run: starts with `count = 1` and extends while `count < 128`, `ptr < pend - bpp`,
    ///   and the pixel at `ptr` differs from the pixel at `ptr + bpp` (including the final pixel if `ptr`
    ///   reaches `pend - bpp` with `count < 128`), then emits `(257 - count) & 0xff` followed by the
    ///   `count` pixels verbatim. Never emits byte `128` (`0x80`).
    static func encodeLine(
        _ line: UnsafeBufferPointer<UInt8>,
        bytesPerPixel bpp: Int,
        into output: inout [UInt8]
    ) {
        guard bpp > 0, let base = line.baseAddress, line.count >= bpp else { return }
        let validByteCount = (line.count / bpp) * bpp
        guard validByteCount > 0 else { return }

        let pend = base + validByteCount
        let lastPixelPtr = pend - bpp
        var ptr = base

        while ptr < pend {
            if ptr == lastPixelPtr {
                output.append(0)
                appendPixel(at: ptr, bpp: bpp, into: &output)
                ptr += bpp
            } else if pixelsEqual(ptr, ptr + bpp, bpp: bpp) {
                let runStart = ptr
                var count = 2
                ptr += 2 * bpp
                while count < 128, ptr < pend, pixelsEqual(runStart, ptr, bpp: bpp) {
                    count += 1
                    ptr += bpp
                }
                output.append(UInt8(count - 1))
                appendPixel(at: runStart, bpp: bpp, into: &output)
            } else {
                let runStart = ptr
                var count = 1
                ptr += bpp
                while count < 128, ptr < lastPixelPtr, !pixelsEqual(ptr, ptr + bpp, bpp: bpp) {
                    count += 1
                    ptr += bpp
                }
                if ptr == lastPixelPtr, count < 128 {
                    count += 1
                    ptr += bpp
                }
                output.append(UInt8((257 - count) & 0xff))
                output.append(contentsOf: UnsafeBufferPointer(start: runStart, count: count * bpp))
            }
        }
    }

    @inline(__always)
    private static func pixelsEqual(
        _ lhs: UnsafePointer<UInt8>,
        _ rhs: UnsafePointer<UInt8>,
        bpp: Int
    ) -> Bool {
        switch bpp {
        case 1:
            return lhs[0] == rhs[0]
        case 3:
            return lhs[0] == rhs[0] && lhs[1] == rhs[1] && lhs[2] == rhs[2]
        default:
            return memcmp(lhs, rhs, bpp) == 0
        }
    }

    @inline(__always)
    private static func appendPixel(
        at ptr: UnsafePointer<UInt8>,
        bpp: Int,
        into output: inout [UInt8]
    ) {
        switch bpp {
        case 1:
            output.append(ptr[0])
        case 3:
            output.append(ptr[0])
            output.append(ptr[1])
            output.append(ptr[2])
        default:
            output.append(contentsOf: UnsafeBufferPointer(start: ptr, count: bpp))
        }
    }

    // MARK: - Headers & Buffering

    private func flushPendingLine(bytesPerPixel bpp: Int) throws {
        guard pendingRepeatCount > 0 else { return }
        buffer.append(UInt8(pendingRepeatCount - 1))
        pendingLine.withUnsafeBufferPointer { ptr in
            Self.encodeLine(ptr, bytesPerPixel: bpp, into: &buffer)
        }
        pendingRepeatCount = 0
        if buffer.count >= Self.bufferCapacity {
            try flushBuffer()
        }
    }

    private func flushBuffer() throws {
        guard !buffer.isEmpty else { return }
        try output.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    private static func makePWGPageHeader(_ spec: RasterPageSpec) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: pwgPageHeaderSize)

        for (index, byte) in pwgHeaderMagic.enumerated() {
            header[index] = byte
        }

        let dpi = UInt32(spec.dpi)
        let widthPt = UInt32((Double(spec.widthPx) * 72.0 / Double(spec.dpi)).rounded())
        let heightPt = UInt32((Double(spec.heightPx) * 72.0 / Double(spec.dpi)).rounded())
        let widthPx = UInt32(spec.widthPx)
        let heightPx = UInt32(spec.heightPx)
        let bitsPerPixel: UInt32 = spec.gray ? 8 : 24
        let bytesPerLine = UInt32(spec.widthPx * spec.bytesPerPixel)
        let colorSpace: UInt32 = spec.gray ? 18 : 19
        let numColors: UInt32 = spec.gray ? 1 : 3
        let totalPages = UInt32(spec.totalPages)
        let quality = UInt32(spec.quality)

        writeUInt32BE(dpi, into: &header, at: 276)
        writeUInt32BE(dpi, into: &header, at: 280)
        writeUInt32BE(widthPt, into: &header, at: 352)
        writeUInt32BE(heightPt, into: &header, at: 356)
        writeUInt32BE(widthPx, into: &header, at: 372)
        writeUInt32BE(heightPx, into: &header, at: 376)
        writeUInt32BE(8, into: &header, at: 384)
        writeUInt32BE(bitsPerPixel, into: &header, at: 388)
        writeUInt32BE(bytesPerLine, into: &header, at: 392)
        writeUInt32BE(0, into: &header, at: 396)
        writeUInt32BE(colorSpace, into: &header, at: 400)
        writeUInt32BE(numColors, into: &header, at: 420)
        writeUInt32BE(totalPages, into: &header, at: 452)
        writeUInt32BE(1, into: &header, at: 456)
        writeUInt32BE(1, into: &header, at: 460)
        writeUInt32BE(0x00ff_ffff, into: &header, at: 480)
        writeUInt32BE(quality, into: &header, at: 484)

        let nameBytes = spec.pageSizeName.utf8.prefix(63)
        for (index, byte) in nameBytes.enumerated() {
            header[1732 + index] = byte
        }

        return header
    }

    private static func makeURFPageHeader(_ spec: RasterPageSpec) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: urfPageHeaderSize)
        header[0] = spec.gray ? 0x08 : 0x18
        header[1] = spec.gray ? 0x00 : 0x01
        header[2] = 0x01
        header[3] = UInt8(truncatingIfNeeded: spec.quality)

        writeUInt32BE(UInt32(spec.widthPx), into: &header, at: 12)
        writeUInt32BE(UInt32(spec.heightPx), into: &header, at: 16)
        writeUInt32BE(UInt32(spec.dpi), into: &header, at: 20)

        return header
    }

    @inline(__always)
    private static func writeUInt32BE(_ value: UInt32, into buffer: inout [UInt8], at offset: Int) {
        buffer[offset] = UInt8((value >> 24) & 0xff)
        buffer[offset + 1] = UInt8((value >> 16) & 0xff)
        buffer[offset + 2] = UInt8((value >> 8) & 0xff)
        buffer[offset + 3] = UInt8(value & 0xff)
    }
}

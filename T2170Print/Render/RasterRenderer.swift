import CoreGraphics
import CoreImage
import Foundation

extension SheetComposer {
    /// Pixels held in memory at once. A 24 in roll at 300 dpi is 7200 pixels wide, so this is about
    /// 4400 rows, or 128 MB of RGBX, however long the print is.
    static let defaultBandPixelBudget = 32_000_000

    /// sRGB-encoded grey from sRGB-encoded colour, Rec. 709 weights in 8.8 fixed point. Keeps 0 and 255 exact.
    @inline(__always)
    static func rasterLuma(red: UInt8, green: UInt8, blue: UInt8) -> UInt8 {
        UInt8((54 * Int(red) + 183 * Int(green) + 19 * Int(blue) + 128) >> 8)
    }

    /// Renders `plans` to a PWG Raster or URF file, one horizontal band at a time.
    static func composeRaster(
        plans: [SheetPlan],
        source: PageSource,
        settings: PrintSettings,
        format: RasterFormat,
        dpi: Int,
        gray: Bool,
        quality: Int,
        to url: URL,
        bandPixelBudget: Int = defaultBandPixelBudget
    ) async throws {
        let task = Task.detached(priority: .userInitiated) { () throws -> Void in
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw SheetComposerError.outputFileFailed
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            let writer = try RasterWriter(format: format, pageCount: plans.count, output: handle)

            let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let ciContext = CIContext(options: [
                .workingColorSpace: sRGB,
                .outputColorSpace: sRGB
            ])
            // Grey pages also render in sRGB and convert per pixel below. Drawing straight into a grey
            // context gave pixels up to 4 levels different depending on where band edges fell.
            let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
            let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            var context: CGContext?
            var contextSize = (width: 0, rows: 0)

            for plan in plans {
                try Task.checkCancellation()
                guard plan.sheetSizePt.width > 0, plan.sheetSizePt.height > 0 else {
                    throw SheetComposerError.invalidSheetSize(plan.sheetSizePt)
                }
                let geometry = MediaGeometry(plan: plan, settings: settings)
                let mediaPt = geometry.mediaPt
                let width = max(1, Int((mediaPt.width / 72.0 * CGFloat(dpi)).rounded()))
                let height = max(1, Int((mediaPt.height / 72.0 * CGFloat(dpi)).rounded()))
                let bandRows = max(1, min(height, bandPixelBudget / width))

                if context == nil || contextSize != (width, bandRows) {
                    context = CGContext(
                        data: nil, width: width, height: bandRows, bitsPerComponent: 8,
                        bytesPerRow: 0, space: sRGB, bitmapInfo: bitmapInfo)
                    contextSize = (width, bandRows)
                }
                guard let ctx = context, let rawData = ctx.data else {
                    throw SheetComposerError.rasterContextCreationFailed
                }
                let base = rawData.assumingMemoryBound(to: UInt8.self)
                let stride = ctx.bytesPerRow

                let mm = geometry.mediaMM
                let sizeText = String(format: "%.2fx%.2fmm", mm.width, mm.height)
                try writer.beginPage(RasterPageSpec(
                    widthPx: width, heightPx: height, dpi: dpi, gray: gray, quality: quality,
                    totalPages: plans.count, pageSizeName: "custom_\(sizeText)_\(sizeText)"))

                let packed = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: width * 3)
                defer { packed.deallocate() }

                var firstRow = 0
                while firstRow < height {
                    try Task.checkCancellation()
                    try autoreleasepool {
                        ctx.saveGState()
                        defer { ctx.restoreGState() }
                        ctx.setFillColor(white)
                        ctx.fill(CGRect(x: 0, y: 0, width: width, height: bandRows))

                        // Top-left page coordinates, shifted so this band's first row is bitmap row 0.
                        ctx.translateBy(x: 0, y: CGFloat(bandRows))
                        ctx.scaleBy(x: 1, y: -1)
                        ctx.translateBy(x: 0, y: -CGFloat(firstRow))
                        ctx.scaleBy(x: CGFloat(width) / mediaPt.width, y: CGFloat(height) / mediaPt.height)
                        ctx.concatenate(geometry.sheetToMedia)

                        try drawSheet(
                            plan: plan, source: source, settings: settings, in: ctx,
                            scale: CGFloat(dpi) / 72.0, ciContext: ciContext)
                    }

                    let rows = min(bandRows, height - firstRow)
                    for row in 0..<rows {
                        let line = base + row * stride
                        let out = packed.baseAddress!
                        if gray {
                            for x in 0..<width {
                                out[x] = rasterLuma(red: line[x * 4], green: line[x * 4 + 1], blue: line[x * 4 + 2])
                            }
                            try writer.append(line: UnsafeBufferPointer(start: out, count: width))
                        } else {
                            for x in 0..<width {
                                out[x * 3] = line[x * 4]
                                out[x * 3 + 1] = line[x * 4 + 1]
                                out[x * 3 + 2] = line[x * 4 + 2]
                            }
                            try writer.append(line: UnsafeBufferPointer(start: out, count: width * 3))
                        }
                    }
                    firstRow += rows
                }
                try writer.endPage()
            }
            try writer.finish()
        }
        // `Task.detached` does not inherit cancellation, so forward it explicitly.
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

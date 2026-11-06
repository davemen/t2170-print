import CoreGraphics
import CoreImage
import Foundation
import UIKit

/// Errors thrown by `SheetComposer` during PDF composition.
enum SheetComposerError: Error, LocalizedError, Sendable, Equatable {
    case invalidSheetSize(CGSize)
    case pdfContextCreationFailed
    case rasterContextCreationFailed
    case outputFileFailed
    case pageRenderFailed(Int)

    var errorDescription: String? {
        switch self {
        case .invalidSheetSize(let size):
            "Invalid sheet dimensions (\(size.width)×\(size.height) pt)."
        case .pdfContextCreationFailed:
            "Failed to create CoreGraphics PDF context."
        case .rasterContextCreationFailed:
            "Not enough memory to render this page at the chosen resolution."
        case .outputFileFailed:
            "Could not create the temporary print file."
        case .pageRenderFailed(let page):
            "Page \(page) could not be drawn, so nothing was sent. The file may be damaged, or the iPad may be short of memory."
        }
    }
}

/// Composes imposed `SheetPlan`s into a print-ready PDF or low-resolution preview images off the main actor.
struct SheetComposer: Sendable {
    /// Renders `plans` into a multi-page PDF file at `url` on a background task. Each page is the media
    /// the printer loads, so a landscape sheet is turned onto portrait media (see `MediaGeometry`).
    static func composePDF(
        plans: [SheetPlan],
        source: PageSource,
        settings: PrintSettings,
        dpi: CGFloat = 300,
        to url: URL
    ) async throws {
        let task = Task.detached(priority: .userInitiated) { () throws -> Void in
            guard let pdfContext = CGContext(url as CFURL, mediaBox: nil, nil) else {
                throw SheetComposerError.pdfContextCreationFailed
            }

            let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let ciContext = CIContext(options: [
                .workingColorSpace: sRGB,
                .outputColorSpace: sRGB
            ])
            let rasterScale = max(1.0, dpi) / 72.0

            for plan in plans {
                try Task.checkCancellation()
                guard plan.sheetSizePt.width > 0, plan.sheetSizePt.height > 0 else {
                    throw SheetComposerError.invalidSheetSize(plan.sheetSizePt)
                }
                let geometry = MediaGeometry(plan: plan, settings: settings)
                var mediaBox = CGRect(origin: .zero, size: geometry.mediaPt)
                let pageInfo: [CFString: Any] = [
                    kCGPDFContextMediaBox: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)
                ]
                pdfContext.beginPDFPage(pageInfo as CFDictionary)
                pdfContext.saveGState()
                pdfContext.translateBy(x: 0, y: geometry.mediaPt.height)
                pdfContext.scaleBy(x: 1, y: -1)
                pdfContext.concatenate(geometry.sheetToMedia)

                try drawSheet(
                    plan: plan,
                    source: source,
                    settings: settings,
                    in: pdfContext,
                    scale: rasterScale,
                    ciContext: ciContext
                )

                pdfContext.restoreGState()
                pdfContext.endPDFPage()
            }

            pdfContext.closePDF()
        }
        // `Task.detached` does not inherit cancellation, so forward it explicitly.
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Renders `plans` into on-screen preview `CGImage`s bounded by `maxPixels` along the longest sheet edge.
    static func previewImages(
        plans: [SheetPlan],
        source: PageSource,
        settings: PrintSettings,
        maxPixels: CGFloat = 1600
    ) async -> [CGImage] {
        let task = Task.detached(priority: .userInitiated) { () -> [CGImage] in
            let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let ciContext = CIContext(options: [
                .workingColorSpace: sRGB,
                .outputColorSpace: sRGB
            ])
            let clampedMaxPixels = max(16.0, maxPixels)
            var results: [CGImage] = []
            results.reserveCapacity(plans.count)

            for plan in plans {
                if Task.isCancelled { break }
                let maxDimension = max(plan.sheetSizePt.width, plan.sheetSizePt.height)
                guard maxDimension > 0, plan.sheetSizePt.width > 0, plan.sheetSizePt.height > 0 else {
                    results.append(whitePlaceholder(width: 1, height: 1, colorSpace: sRGB))
                    continue
                }
                let scale = clampedMaxPixels / maxDimension
                let pixelWidth = max(1, Int((plan.sheetSizePt.width * scale).rounded()))
                let pixelHeight = max(1, Int((plan.sheetSizePt.height * scale).rounded()))

                guard let bitmap = CGContext(
                    data: nil,
                    width: pixelWidth,
                    height: pixelHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: sRGB,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else {
                    results.append(whitePlaceholder(width: pixelWidth, height: pixelHeight, colorSpace: sRGB))
                    continue
                }

                bitmap.saveGState()
                bitmap.translateBy(x: 0, y: CGFloat(pixelHeight))
                bitmap.scaleBy(
                    x: CGFloat(pixelWidth) / plan.sheetSizePt.width,
                    y: -CGFloat(pixelHeight) / plan.sheetSizePt.height
                )

                try? drawSheet(
                    plan: plan,
                    source: source,
                    settings: settings,
                    in: bitmap,
                    scale: scale,
                    ciContext: ciContext
                )

                bitmap.restoreGState()
                // Keep one image per plan so indices stay aligned with `plans`.
                results.append(
                    bitmap.makeImage()
                        ?? whitePlaceholder(width: pixelWidth, height: pixelHeight, colorSpace: sRGB)
                )
            }

            return results
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// A white image of the given pixel size (falls back to 1x1) used when a preview sheet fails to render.
    private static func whitePlaceholder(width: Int, height: Int, colorSpace: CGColorSpace) -> CGImage {
        for (w, h) in [(max(1, width), max(1, height)), (1, 1)] {
            if let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                if let image = ctx.makeImage() { return image }
            }
        }
        preconditionFailure("Unable to allocate a 1x1 bitmap")
    }

    /// Convenience overload accepting an `Int` pixel limit.
    static func previewImages(
        plans: [SheetPlan],
        source: PageSource,
        settings: PrintSettings,
        maxPixels: Int
    ) async -> [CGImage] {
        await previewImages(
            plans: plans,
            source: source,
            settings: settings,
            maxPixels: CGFloat(maxPixels)
        )
    }

    // MARK: - Shared Sheet Drawing

    /// Shared drawing routine operating in top-left point coordinates `(0...sheetSizePt.width, 0...sheetSizePt.height)`.
    static func drawSheet(
        plan: SheetPlan,
        source: PageSource,
        settings: PrintSettings,
        in context: CGContext,
        scale: CGFloat,
        ciContext: CIContext
    ) throws {
        let sheetRect = CGRect(origin: .zero, size: plan.sheetSizePt)
        context.interpolationQuality = .high
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(sheetRect)

        for cell in plan.cells {
            try drawCell(
                cell,
                source: source,
                settings: settings,
                in: context,
                scale: scale,
                ciContext: ciContext
            )
            drawBorder(for: cell, in: context)
        }

        if plan.cutMarks {
            for cell in plan.cells {
                drawCropMarks(around: cell.frame, in: context)
            }
        }

        if plan.pageLine {
            drawPageLine(sheetSize: plan.sheetSizePt, in: context)
        }
    }

    private static func drawCell(
        _ cell: Cell,
        source: PageSource,
        settings: PrintSettings,
        in context: CGContext,
        scale: CGFloat,
        ciContext: CIContext
    ) throws {
        guard cell.frame.width > 0, cell.frame.height > 0 else { return }
        let srcPageSize = source.pageSizePt(cell.sourcePage)
        guard srcPageSize.width > 0, srcPageSize.height > 0 else {
            throw SheetComposerError.pageRenderFailed(cell.sourcePage + 1)
        }

        let normalizedRotation = ((cell.rotation % 360) + 360) % 360
        let isQuarterTurn = normalizedRotation == 90 || normalizedRotation == 270

        context.saveGState()
        context.clip(to: cell.frame)
        context.translateBy(x: cell.frame.midX, y: cell.frame.midY)
        if cell.flipH {
            context.scaleBy(x: -1, y: 1)
        }
        if normalizedRotation != 0 {
            context.rotate(by: CGFloat(normalizedRotation) * .pi / 180.0)
        }

        let drawWidth = isQuarterTurn ? cell.frame.height : cell.frame.width
        let drawHeight = isQuarterTurn ? cell.frame.width : cell.frame.height
        context.scaleBy(x: 1, y: -1)
        let imageRect = CGRect(
            x: -drawWidth / 2.0,
            y: -drawHeight / 2.0,
            width: drawWidth,
            height: drawHeight
        )

        // Neutral colour pipeline + PDF source: draw the page as vectors, no rasterisation.
        if ColorPipeline.isNeutral(settings),
           source.drawVector(page: cell.sourcePage, sourceRect: cell.sourceRect, in: imageRect, context: context) {
            context.restoreGState()
            return
        }

        // Pixels per point of the full page. `imageRect` is already in the page's own orientation.
        let crop = cell.sourceRect
        var renderScale = max(
            0.05,
            max(
                drawWidth / max(1.0, srcPageSize.width * crop.width),
                drawHeight / max(1.0, srcPageSize.height * crop.height)
            ) * scale
        )

        // A long PDF page is drawn band by band. Rendering only what this band shows keeps full
        // resolution on a page far larger than maxRasterPixels; rendering the whole cell each time
        // would be capped and print soft.
        var slice = crop
        if source.isPDF {
            let visible = context.boundingBoxOfClipPath.intersection(imageRect)
            guard !visible.isNull, !visible.isEmpty else {
                context.restoreGState()
                return
            }
            slice = CGRect(
                x: crop.minX + crop.width * (visible.minX - imageRect.minX) / drawWidth,
                y: crop.minY + crop.height * (imageRect.maxY - visible.maxY) / drawHeight,
                width: crop.width * visible.width / drawWidth,
                height: crop.height * visible.height / drawHeight
            )
        }

        // Cap the raster (the cropped region only) at maxRasterPixels.
        let pixelsWide = srcPageSize.width * slice.width * renderScale
        let pixelsHigh = srcPageSize.height * slice.height * renderScale
        if pixelsWide * pixelsHigh > maxRasterPixels {
            renderScale *= (maxRasterPixels / (pixelsWide * pixelsHigh)).squareRoot()
        }

        var target = imageRect
        if source.isPDF {
            slice = snappedToPagePixels(
                slice,
                pagePixels: CGSize(width: srcPageSize.width * renderScale, height: srcPageSize.height * renderScale)
            )
            let height = slice.height / crop.height * drawHeight
            let top = imageRect.maxY - (slice.minY - crop.minY) / crop.height * drawHeight
            target = CGRect(
                x: imageRect.minX + (slice.minX - crop.minX) / crop.width * drawWidth,
                y: top - height,
                width: slice.width / crop.width * drawWidth,
                height: height
            )
        }

        guard let rawImage = source.render(page: cell.sourcePage, scale: renderScale, sourceRect: slice) else {
            context.restoreGState()
            throw SheetComposerError.pageRenderFailed(cell.sourcePage + 1)
        }

        let processedImage = ColorPipeline.apply(settings, to: rawImage, context: ciContext)
        context.draw(processedImage, in: target)
        context.restoreGState()
    }

    /// Grows a normalised page rect outward onto whole page pixels, plus a few pixels of overlap, so every
    /// band samples one shared pixel grid and no seam shows. The overlap can pass the crop; the cell's clip
    /// trims it. It can't pass the page, so the rect stays inside the unit square.
    private static func snappedToPagePixels(_ slice: CGRect, pagePixels: CGSize) -> CGRect {
        let overlap: CGFloat = 4
        let minX = max(0, ((slice.minX * pagePixels.width) - overlap).rounded(.down) / pagePixels.width)
        let maxX = min(1, ((slice.maxX * pagePixels.width) + overlap).rounded(.up) / pagePixels.width)
        let minY = max(0, ((slice.minY * pagePixels.height) - overlap).rounded(.down) / pagePixels.height)
        let maxY = min(1, ((slice.maxY * pagePixels.height) + overlap).rounded(.up) / pagePixels.height)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Upper bound on the pixel count of any single rasterised cell.
    private static let maxRasterPixels: CGFloat = 40_000_000

    private static func drawBorder(for cell: Cell, in context: CGContext) {
        guard cell.border != .none else { return }
        let lineWidth: CGFloat
        let isDouble: Bool
        switch cell.border {
        case .none:
            return
        case .singleHairline:
            lineWidth = 0.25
            isDouble = false
        case .singleThin:
            lineWidth = 1.0
            isDouble = false
        case .doubleHairline:
            lineWidth = 0.25
            isDouble = true
        case .doubleThin:
            lineWidth = 1.0
            isDouble = true
        }

        context.saveGState()
        context.setStrokeColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.setLineWidth(lineWidth)
        context.stroke(cell.frame)
        if isDouble {
            let innerFrame = cell.frame.insetBy(dx: 2.0, dy: 2.0)
            if innerFrame.width > 0, innerFrame.height > 0 {
                context.stroke(innerFrame)
            }
        }
        context.restoreGState()
    }

    private static func drawCropMarks(around rect: CGRect, in context: CGContext) {
        let markLength: CGFloat = 6.0
        context.saveGState()
        context.setStrokeColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.setLineWidth(0.5)

        let corners: [(point: CGPoint, dx: CGFloat, dy: CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), -1, -1),
            (CGPoint(x: rect.maxX, y: rect.minY), 1, -1),
            (CGPoint(x: rect.minX, y: rect.maxY), -1, 1),
            (CGPoint(x: rect.maxX, y: rect.maxY), 1, 1),
        ]

        for corner in corners {
            context.move(to: CGPoint(x: corner.point.x + corner.dx * markLength, y: corner.point.y))
            context.addLine(to: corner.point)
            context.addLine(to: CGPoint(x: corner.point.x, y: corner.point.y + corner.dy * markLength))
        }
        context.strokePath()
        context.restoreGState()
    }

    private static func drawPageLine(sheetSize: CGSize, in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.setLineWidth(0.5)
        let y = max(0, sheetSize.height - 0.25)
        context.move(to: CGPoint(x: 0, y: y))
        context.addLine(to: CGPoint(x: sheetSize.width, y: y))
        context.strokePath()
        context.restoreGState()
    }
}

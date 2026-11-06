import CoreGraphics
import Foundation

/// A single placed source page (or poster tile) on an imposed sheet.
struct Cell: Sendable, Equatable, Hashable {
    /// Zero-based index into the source document's pages.
    var sourcePage: Int
    /// Destination frame on the sheet, in points (top-left origin).
    var frame: CGRect
    /// Clockwise rotation in degrees (`0`, `90`, `180`, or `270`).
    var rotation: Int
    /// Whether the cell content is flipped horizontally.
    var flipH: Bool
    /// Border style drawn around the cell.
    var border: PageBorder
    /// Normalised sub-rect (`0...1` in both axes) of the source page to draw (used by poster tiling).
    var sourceRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
}

/// Geometry plan for a single output sheet produced by `Imposer`.
struct SheetPlan: Sendable, Equatable, Hashable {
    /// Output sheet dimensions in points (72 pt/in).
    var sheetSizePt: CGSize
    /// Placed page cells on this sheet.
    var cells: [Cell]
    /// Whether to draw a 0.5 pt cut line across the roll at the sheet's trailing edge.
    var pageLine: Bool
    /// Whether to draw corner crop/cut marks (e.g. for poster tiles).
    var cutMarks: Bool

    init(
        sheetSizePt: CGSize,
        cells: [Cell],
        pageLine: Bool = false,
        cutMarks: Bool = false
    ) {
        self.sheetSizePt = sheetSizePt
        self.cells = cells
        self.pageLine = pageLine
        self.cutMarks = cutMarks
    }
}

/// Pure-geometry page imposition engine that converts `PrintSettings` and source page sizes into `SheetPlan`s.
struct Imposer: Sendable {
    /// Standard 3 mm unprintable sheet margin in points.
    static let sheetMarginPt: CGFloat = mmToPt(3.0)

    /// Converts millimetres to typographical points (72 pt/in).
    static func mmToPt(_ mm: Double) -> CGFloat {
        CGFloat(mm / 25.4 * 72.0)
    }

    /// Computes the imposed `[SheetPlan]` sequence for `settings` and `pageSizes`.
    static func plan(settings: PrintSettings, pageSizes: [CGSize]) -> [SheetPlan] {
        guard !pageSizes.isEmpty, settings.copies > 0 else { return [] }

        let selectedPages = resolvePages(settings: settings, totalPages: pageSizes.count)
        guard !selectedPages.isEmpty else { return [] }

        let baseRotation = settings.layout.reversePageOrientation ? 180 : 0
        let flipH = settings.layout.flipHorizontally
        let border = settings.layout.border
        let pageLine = settings.advanced.printPageLine

        let singleCopyPlans: [SheetPlan]
        if settings.layout.poster != .off {
            singleCopyPlans = planPoster(
                settings: settings,
                pageIndices: selectedPages,
                pageSizes: pageSizes,
                baseRotation: baseRotation,
                flipH: flipH,
                border: border,
                pageLine: pageLine
            )
        } else {
            switch settings.outputSize {
            case .banner:
                singleCopyPlans = planBanner(
                    settings: settings,
                    pageIndices: selectedPages,
                    pageSizes: pageSizes,
                    baseRotation: baseRotation,
                    flipH: flipH,
                    border: border,
                    pageLine: pageLine
                )
            case .fitToRollPaperWidth:
                singleCopyPlans = planFitToRoll(
                    settings: settings,
                    pageIndices: selectedPages,
                    pageSizes: pageSizes,
                    baseRotation: baseRotation,
                    flipH: flipH,
                    border: border,
                    pageLine: pageLine
                )
            case .sameAsPaperSize, .outputSize, .specifySize, .retainScale:
                singleCopyPlans = planFixedSheets(
                    settings: settings,
                    pageIndices: selectedPages,
                    pageSizes: pageSizes,
                    baseRotation: baseRotation,
                    flipH: flipH,
                    border: border,
                    pageLine: pageLine
                )
            }
        }

        return applyCopies(
            plans: singleCopyPlans,
            copies: settings.copies,
            collate: settings.paperHandling.collate
        )
    }

    // MARK: - Page Filtering & Ordering

    private static func resolvePages(settings: PrintSettings, totalPages: Int) -> [Int] {
        var indices: [Int]
        switch settings.pageRange {
        case .all:
            indices = Array(0..<totalPages)
        case .range(let from, let to):
            let low = max(1, min(from, to))
            let high = min(totalPages, max(from, to))
            guard low <= high else { return [] }
            indices = Array((low - 1)...(high - 1))
        case .selection(let selected):
            if selected.contains(0) {
                indices = selected.filter { $0 >= 0 && $0 < totalPages }
            } else {
                indices = selected.map { $0 - 1 }.filter { $0 >= 0 && $0 < totalPages }
            }
        }

        switch settings.paperHandling.pagesToPrint {
        case .all:
            break
        case .oddOnly:
            indices = indices.filter { ($0 + 1) % 2 == 1 }
        case .evenOnly:
            indices = indices.filter { ($0 + 1) % 2 == 0 }
        }

        if settings.paperHandling.pageOrder == .reverse {
            indices.reverse()
        }

        return indices
    }

    private static func applyCopies(plans: [SheetPlan], copies: Int, collate: Bool) -> [SheetPlan] {
        guard copies > 1, !plans.isEmpty else { return plans }
        var result: [SheetPlan] = []
        result.reserveCapacity(plans.count * copies)
        if collate {
            for _ in 0..<copies {
                result.append(contentsOf: plans)
            }
        } else {
            for plan in plans {
                for _ in 0..<copies {
                    result.append(plan)
                }
            }
        }
        return result
    }

    // MARK: - Sheet Size & Grid Helpers

    private static func targetSheetSize(for settings: PrintSettings) -> CGSize {
        let basePaper: PaperSize
        if settings.paperHandling.scaleToFitPaperSize,
           let destination = settings.paperHandling.destinationPaperSize {
            basePaper = destination
        } else {
            switch settings.outputSize {
            case .outputSize, .specifySize:
                basePaper = settings.specifiedOutputSize ?? settings.effectivePaperSize
            case .sameAsPaperSize, .retainScale, .fitToRollPaperWidth, .banner:
                basePaper = settings.effectivePaperSize
            }
        }

        let widthPt = CGFloat(basePaper.widthPt)
        let heightPt = CGFloat(basePaper.heightPt)
        switch settings.orientation {
        case .portrait:
            return CGSize(width: widthPt, height: heightPt)
        case .landscape:
            return CGSize(width: heightPt, height: widthPt)
        }
    }

    /// N-up grid dimensions `(cols, rows)` for a given `PagesPerSheet` and sheet size.
    static func gridDimensions(for pagesPerSheet: PagesPerSheet, sheetSize: CGSize) -> (cols: Int, rows: Int) {
        switch pagesPerSheet {
        case .one:
            return (1, 1)
        case .two:
            return sheetSize.height > sheetSize.width ? (1, 2) : (2, 1)
        case .four:
            return (2, 2)
        case .six:
            return (3, 2)
        case .nine:
            return (3, 3)
        case .sixteen:
            return (4, 4)
        }
    }

    /// Maps a 0-based cell ordinal `slotIndex` within a `(cols, rows)` grid according to `direction`.
    static func gridPosition(
        slotIndex: Int,
        cols: Int,
        rows: Int,
        direction: LayoutDirection
    ) -> (col: Int, row: Int) {
        switch direction {
        case .leftRightTopBottom:
            return (col: slotIndex % cols, row: slotIndex / cols)
        case .rightLeftTopBottom:
            return (col: (cols - 1) - (slotIndex % cols), row: slotIndex / cols)
        case .topBottomLeftRight:
            return (col: slotIndex / rows, row: slotIndex % rows)
        case .topBottomRightLeft:
            return (col: (cols - 1) - (slotIndex / rows), row: slotIndex % rows)
        }
    }

    private static func aspectFitRect(
        sourceSize: CGSize,
        in bounds: CGRect,
        scaleDownOnly: Bool
    ) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        var scale = min(bounds.width / sourceSize.width, bounds.height / sourceSize.height)
        if scaleDownOnly {
            scale = min(scale, 1.0)
        }
        let fittedWidth = sourceSize.width * scale
        let fittedHeight = sourceSize.height * scale
        let originX = bounds.midX - fittedWidth / 2.0
        let originY = bounds.midY - fittedHeight / 2.0
        return CGRect(x: originX, y: originY, width: fittedWidth, height: fittedHeight)
    }

    // MARK: - Layout Modes

    private static func planFixedSheets(
        settings: PrintSettings,
        pageIndices: [Int],
        pageSizes: [CGSize],
        baseRotation: Int,
        flipH: Bool,
        border: PageBorder,
        pageLine: Bool
    ) -> [SheetPlan] {
        let sheetSize = targetSheetSize(for: settings)
        let printableRect = CGRect(origin: .zero, size: sheetSize)
            .insetBy(dx: sheetMarginPt, dy: sheetMarginPt)
        let nUp = settings.layout.pagesPerSheet.rawValue
        let (cols, rows) = gridDimensions(for: settings.layout.pagesPerSheet, sheetSize: sheetSize)
        let slotWidth = printableRect.width / CGFloat(cols)
        let slotHeight = printableRect.height / CGFloat(rows)
        let scaleDownOnly = settings.paperHandling.scaleToFitPaperSize && settings.paperHandling.scaleDownOnly

        var plans: [SheetPlan] = []
        var offset = 0
        while offset < pageIndices.count {
            let chunkEnd = min(offset + nUp, pageIndices.count)
            let chunk = pageIndices[offset..<chunkEnd]
            var cells: [Cell] = []
            cells.reserveCapacity(chunk.count)

            for (slotIndex, pageIndex) in chunk.enumerated() {
                let (col, row) = gridPosition(
                    slotIndex: slotIndex,
                    cols: cols,
                    rows: rows,
                    direction: settings.layout.layoutDirection
                )
                let slotRect = CGRect(
                    x: printableRect.minX + CGFloat(col) * slotWidth,
                    y: printableRect.minY + CGFloat(row) * slotHeight,
                    width: slotWidth,
                    height: slotHeight
                )
                let srcSize = pageSizes[pageIndex]
                let cellFrame: CGRect
                if settings.outputSize == .retainScale && settings.layout.pagesPerSheet == .one {
                    let scale = CGFloat(max(0, settings.retainScalePercent) / 100.0)
                    var width = srcSize.width * scale
                    var height = srcSize.height * scale
                    // Never overflow the printable area.
                    if width > printableRect.width || height > printableRect.height,
                       width > 0, height > 0 {
                        let shrink = min(printableRect.width / width, printableRect.height / height)
                        width *= shrink
                        height *= shrink
                    }
                    cellFrame = CGRect(
                        x: sheetSize.width / 2.0 - width / 2.0,
                        y: sheetSize.height / 2.0 - height / 2.0,
                        width: width,
                        height: height
                    )
                } else {
                    cellFrame = aspectFitRect(
                        sourceSize: srcSize,
                        in: slotRect,
                        scaleDownOnly: scaleDownOnly
                    )
                }

                cells.append(
                    Cell(
                        sourcePage: pageIndex,
                        frame: cellFrame,
                        rotation: baseRotation,
                        flipH: flipH,
                        border: border
                    )
                )
            }

            plans.append(
                SheetPlan(
                    sheetSizePt: sheetSize,
                    cells: cells,
                    pageLine: pageLine,
                    cutMarks: false
                )
            )
            offset = chunkEnd
        }

        return plans
    }

    private static func planFitToRoll(
        settings: PrintSettings,
        pageIndices: [Int],
        pageSizes: [CGSize],
        baseRotation: Int,
        flipH: Bool,
        border: PageBorder,
        pageLine: Bool
    ) -> [SheetPlan] {
        let rollWidthPt = mmToPt(settings.rollWidth.widthMM)
        // The printer can't reach the edge of the roll, so full-width content would lose its sides.
        let printableWidthPt = rollWidthPt - 2.0 * sheetMarginPt
        let nUp = settings.layout.pagesPerSheet.rawValue
        let scaleDownOnly = settings.paperHandling.scaleToFitPaperSize && settings.paperHandling.scaleDownOnly
        let trimRoll = settings.paperSource == .rollPaper && settings.advanced.saveRollPaper
        let edgeMargin = trimRoll ? 0 : sheetMarginPt

        var plans: [SheetPlan] = []

        if nUp == 1 {
            for pageIndex in pageIndices {
                let rawSize = pageSizes[pageIndex]
                let isLandscape = rawSize.width > rawSize.height
                let wantLandscape = settings.orientation == .landscape
                let autoRotated = !wantLandscape
                    && settings.advanced.autoRotate
                    && isLandscape
                    && abs(rawSize.height - rollWidthPt) < abs(rawSize.width - rollWidthPt)
                // Landscape orientation keeps the sheet at roll width and turns the content 90 degrees instead.
                let forcedLandscape = wantLandscape && !isLandscape

                let quarterTurn = autoRotated || forcedLandscape
                let effectivePageSize = quarterTurn
                    ? CGSize(width: rawSize.height, height: rawSize.width)
                    : rawSize
                let cellRotation = ((baseRotation + (quarterTurn ? 90 : 0)) % 360 + 360) % 360

                var scale = effectivePageSize.width > 0 ? (printableWidthPt / effectivePageSize.width) : 1.0
                if scaleDownOnly {
                    scale = min(scale, 1.0)
                }

                let scaledWidth = effectivePageSize.width * scale
                let scaledHeight = effectivePageSize.height * scale
                let originX = (rollWidthPt - scaledWidth) / 2.0
                let originY = edgeMargin
                let sheetWidth = rollWidthPt
                let finalSheetHeight = scaledHeight + 2.0 * edgeMargin
                let cellFrame = CGRect(x: originX, y: originY, width: scaledWidth, height: scaledHeight)

                plans.append(
                    SheetPlan(
                        sheetSizePt: CGSize(width: sheetWidth, height: finalSheetHeight),
                        cells: [
                            Cell(
                                sourcePage: pageIndex,
                                frame: cellFrame,
                                rotation: cellRotation,
                                flipH: flipH,
                                border: border
                            )
                        ],
                        pageLine: pageLine,
                        cutMarks: false
                    )
                )
            }
            return plans
        }

        // Multi-page N-up on roll paper
        let refSize = pageSizes[pageIndices[0]]
        let refAspect = refSize.width > 0 ? (refSize.height / refSize.width) : sqrt(2.0)
        let nominalSheetSize = CGSize(width: rollWidthPt, height: rollWidthPt * refAspect)
        let (cols, rows) = gridDimensions(for: settings.layout.pagesPerSheet, sheetSize: nominalSheetSize)
        let slotWidth = printableWidthPt / CGFloat(cols)
        let slotHeight = slotWidth * refAspect
        let fullGridHeight = slotHeight * CGFloat(rows)

        var offset = 0
        while offset < pageIndices.count {
            let chunkEnd = min(offset + nUp, pageIndices.count)
            let chunk = pageIndices[offset..<chunkEnd]
            var cells: [Cell] = []
            cells.reserveCapacity(chunk.count)

            for (slotIndex, pageIndex) in chunk.enumerated() {
                let (col, row) = gridPosition(
                    slotIndex: slotIndex,
                    cols: cols,
                    rows: rows,
                    direction: settings.layout.layoutDirection
                )
                let slotRect = CGRect(
                    x: sheetMarginPt + CGFloat(col) * slotWidth,
                    y: edgeMargin + CGFloat(row) * slotHeight,
                    width: slotWidth,
                    height: slotHeight
                )
                let fitted = aspectFitRect(
                    sourceSize: pageSizes[pageIndex],
                    in: slotRect,
                    scaleDownOnly: scaleDownOnly
                )
                cells.append(
                    Cell(
                        sourcePage: pageIndex,
                        frame: fitted,
                        rotation: baseRotation,
                        flipH: flipH,
                        border: border
                    )
                )
            }

            let sheetHeight: CGFloat
            if trimRoll, let first = cells.first {
                let bbox = cells.dropFirst().reduce(first.frame) { $0.union($1.frame) }
                cells = cells.map { cell in
                    var adjusted = cell
                    adjusted.frame.origin.y -= bbox.minY
                    return adjusted
                }
                sheetHeight = bbox.height
            } else {
                sheetHeight = fullGridHeight + 2.0 * edgeMargin
            }

            plans.append(
                SheetPlan(
                    sheetSizePt: CGSize(width: rollWidthPt, height: sheetHeight),
                    cells: cells,
                    pageLine: pageLine,
                    cutMarks: false
                )
            )
            offset = chunkEnd
        }

        return plans
    }

    private static func planBanner(
        settings: PrintSettings,
        pageIndices: [Int],
        pageSizes: [CGSize],
        baseRotation: Int,
        flipH: Bool,
        border: PageBorder,
        pageLine: Bool
    ) -> [SheetPlan] {
        let rollWidthPt = mmToPt(settings.rollWidth.widthMM)
        let printableWidthPt = rollWidthPt - 2.0 * sheetMarginPt
        let bannerHeightPt = max(sheetMarginPt * 2.0 + 1.0, mmToPt(settings.bannerLengthMM))
        let usableMaxY = bannerHeightPt - sheetMarginPt

        var plans: [SheetPlan] = []
        var currentCells: [Cell] = []
        var cursorY = sheetMarginPt

        for pageIndex in pageIndices {
            let srcSize = pageSizes[pageIndex]
            let scale = srcSize.width > 0 ? (printableWidthPt / srcSize.width) : 1.0
            let scaledHeight = srcSize.height * scale

            if !currentCells.isEmpty && (cursorY + scaledHeight > usableMaxY) {
                plans.append(
                    SheetPlan(
                        sheetSizePt: CGSize(width: rollWidthPt, height: cursorY + sheetMarginPt),
                        cells: currentCells,
                        pageLine: pageLine,
                        cutMarks: false
                    )
                )
                currentCells = []
                cursorY = sheetMarginPt
            }

            let frame = CGRect(x: sheetMarginPt, y: cursorY, width: printableWidthPt, height: scaledHeight)
            currentCells.append(
                Cell(
                    sourcePage: pageIndex,
                    frame: frame,
                    rotation: baseRotation,
                    flipH: flipH,
                    border: border
                )
            )
            cursorY += scaledHeight
        }

        // Each sheet ends where its content does, so a short last sheet doesn't waste paper and a
        // page taller than the banner length runs on rather than being cut off.
        if !currentCells.isEmpty {
            plans.append(
                SheetPlan(
                    sheetSizePt: CGSize(width: rollWidthPt, height: cursorY + sheetMarginPt),
                    cells: currentCells,
                    pageLine: pageLine,
                    cutMarks: false
                )
            )
        }

        return plans
    }

    private static func planPoster(
        settings: PrintSettings,
        pageIndices: [Int],
        pageSizes: [CGSize],
        baseRotation: Int,
        flipH: Bool,
        border: PageBorder,
        pageLine: Bool
    ) -> [SheetPlan] {
        let gridCount = max(2, settings.layout.poster.rawValue)
        let sheetSize = targetSheetSize(for: settings)
        let printableRect = CGRect(origin: .zero, size: sheetSize)
            .insetBy(dx: sheetMarginPt, dy: sheetMarginPt)
        let overlapPt = mmToPt(max(0, settings.layout.posterOverlapMM))

        let totalPosterWidth = max(1, CGFloat(gridCount) * printableRect.width - CGFloat(gridCount - 1) * overlapPt)
        let totalPosterHeight = max(1, CGFloat(gridCount) * printableRect.height - CGFloat(gridCount - 1) * overlapPt)
        let overlapNormX = min(0.25, overlapPt / totalPosterWidth)
        let overlapNormY = min(0.25, overlapPt / totalPosterHeight)
        let tileNormW = (1.0 + CGFloat(gridCount - 1) * overlapNormX) / CGFloat(gridCount)
        let tileNormH = (1.0 + CGFloat(gridCount - 1) * overlapNormY) / CGFloat(gridCount)
        let stepNormX = tileNormW - overlapNormX
        let stepNormY = tileNormH - overlapNormY

        var plans: [SheetPlan] = []
        plans.reserveCapacity(pageIndices.count * gridCount * gridCount)

        for pageIndex in pageIndices {
            let srcSize = pageSizes[pageIndex]
            let tileAspectSize = CGSize(
                width: max(1, srcSize.width * tileNormW),
                height: max(1, srcSize.height * tileNormH)
            )
            let tileFrame = aspectFitRect(
                sourceSize: tileAspectSize,
                in: printableRect,
                scaleDownOnly: false
            )

            for row in 0..<gridCount {
                for col in 0..<gridCount {
                    // Sheet (row, col) is a position in the output poster; the transformed poster
                    // (rotated 180 and/or mirrored) pulls its content from the mirrored source tile.
                    let reversed = baseRotation == 180
                    let srcRow = reversed ? gridCount - 1 - row : row
                    let mirrorCols = reversed != flipH
                    let srcCol = mirrorCols ? gridCount - 1 - col : col
                    let sourceRect = CGRect(
                        x: CGFloat(srcCol) * stepNormX,
                        y: CGFloat(srcRow) * stepNormY,
                        width: tileNormW,
                        height: tileNormH
                    )
                    plans.append(
                        SheetPlan(
                            sheetSizePt: sheetSize,
                            cells: [
                                Cell(
                                    sourcePage: pageIndex,
                                    frame: tileFrame,
                                    rotation: baseRotation,
                                    flipH: flipH,
                                    border: border,
                                    sourceRect: sourceRect
                                )
                            ],
                            pageLine: pageLine,
                            cutMarks: true
                        )
                    )
                }
            }
        }

        return plans
    }
}

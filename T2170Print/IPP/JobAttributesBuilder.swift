import Foundation
import CoreGraphics

/// Builds IPP job-template attributes from `PrintSettings` and validates them against `PrinterCapabilities`.
struct JobAttributesBuilder: Sendable {
    /// Maps `PrintSettings` to IPP job attributes, filtering out unsupported values when `capabilities` is provided.
    ///
    /// - Parameters:
    ///   - settings: User print settings matching the Epson SC-T2170 driver contract.
    ///   - capabilities: Optional printer capabilities used to filter unsupported keywords/enums.
    ///   - documentFormat: MIME media type of the print payload (defaults to `"application/pdf"`).
    ///   - sheetSizeMM: Final media size in millimetres; when non-nil it overrides the media-col dimensions.
    /// - Returns: A tuple of the emitted `attributes` and the names of any `unsupported` attributes that were dropped.
    static func attributes(
        for settings: PrintSettings,
        capabilities: PrinterCapabilities? = nil,
        documentFormat: String = "application/pdf",
        sheetSizeMM: CGSize? = nil
    ) -> (attributes: [IPPAttribute], unsupported: [String]) {
        var attributes: [IPPAttribute] = []
        var unsupported: [String] = []

        // 1. copies: always 1. Imposer.applyCopies already repeats the sheets (and gets the collation
        // right), so asking the printer for N copies as well would print N x N.
        attributes.append(.integer("copies", 1))

        // 2. page-ranges is never sent: Imposer.resolvePages already applies the range to the composed document, so sending it again selects the wrong pages.

        // 3. orientation-requested is intentionally never sent: pages arrive already oriented.

        // 4. print-quality
        let printQuality = Self.printQuality(for: settings)
        if let capabilities,
           !capabilities.printQualitySupported.isEmpty,
           !capabilities.printQualitySupported.contains(printQuality) {
            unsupported.append("print-quality")
        } else {
            attributes.append(.enumValue("print-quality", printQuality))
        }

        // 5. print-color-mode
        let colorMode = settings.printMode.ippPrintColorMode
        if let capabilities,
           !capabilities.printColorModeSupported.isEmpty,
           !capabilities.printColorModeSupported.contains(colorMode) {
            unsupported.append("print-color-mode")
        } else {
            attributes.append(.keyword("print-color-mode", colorMode))
        }

        // 6. media-col (media-size, media-source, media-type)
        var (xDim, yDim) = mediaDimensionsHundredthsMM(for: settings)
        if let sheetSizeMM {
            xDim = Int32(clamping: Int((Double(sheetSizeMM.width) * 100.0).rounded()))
            yDim = Int32(clamping: Int((Double(sheetSizeMM.height) * 100.0).rounded()))
        }
        if let capabilities {
            (xDim, yDim) = snappedMediaSize(x: xDim, y: yDim, database: capabilities.mediaColDatabase)
        }
        let mediaSizeCollection = IPPCollection([
            (name: "x-dimension", values: [.integer(xDim)]),
            (name: "y-dimension", values: [.integer(yDim)])
        ])

        var mediaColMembers: [IPPCollection.Member] = [
            IPPCollection.Member(name: "media-size", value: .collection(mediaSizeCollection))
        ]

        if let mediaSource = mediaSourceKeyword(for: settings.paperSource, capabilities: capabilities) {
            mediaColMembers.append(IPPCollection.Member(name: "media-source", value: .keyword(mediaSource)))
        } else {
            unsupported.append("media-source")
        }

        if let mediaType = settings.mediaType.ippMediaType {
            if let capabilities,
               (!capabilities.mediaTypeSupported.isEmpty || !capabilities.mediaColDatabase.isEmpty),
               !capabilities.supports(mediaType: mediaType) {
                unsupported.append("media-type")
            } else {
                mediaColMembers.append(IPPCollection.Member(name: "media-type", value: .keyword(mediaType)))
            }
        }

        attributes.append(.collection("media-col", IPPCollection(members: mediaColMembers)))

        // 7. finishings (only when paper source is roll)
        if settings.paperSource == .rollPaper {
            let candidates = settings.advanced.autoCut.ippFinishings
            if let finishing = candidates.first(where: { capabilities?.supports(finishing: $0) ?? true }) {
                attributes.append(IPPAttribute(name: "finishings", values: [.enumValue(Int32(finishing))]))
            } else {
                unsupported.append("finishings")
            }
        }

        // 8-10. Pages arrive imposed, pre-scaled and one-sided. These three only restate that, so they
        // go out when the printer lists the value and are left off quietly when it doesn't: nothing is
        // lost, and a strict printer has one less attribute to reject. number-up-layout,
        // orientation-requested and sheet-collate are never sent.
        if capabilities.map({ $0.numberUpSupported.contains(1) }) ?? true {
            attributes.append(.integer("number-up", 1))
        }
        if capabilities.map({ $0.printScalingSupported.contains("none") }) ?? true {
            attributes.append(.keyword("print-scaling", "none"))
        }
        if capabilities.map({ $0.sidesSupported.contains("one-sided") }) ?? true {
            attributes.append(.keyword("sides", "one-sided"))
        }

        // 11. job-name
        let jobName = settings.effectivePaperSize.name.isEmpty
            ? "T2170 Print (\(documentFormat))"
            : "T2170 \(settings.effectivePaperSize.name)"
        attributes.append(.name("job-name", jobName))

        return (attributes: attributes, unsupported: unsupported)
    }

    /// The IPP `print-quality` enum for these settings (3 draft, 4 normal, 5 high).
    static func printQuality(for settings: PrintSettings) -> Int {
        if settings.simpleSettings {
            return settings.printWithHighQuality ? 5 : 4
        }
        return settings.level.ippPrintQuality
    }

    /// Largest difference, in hundredths of a millimetre, still treated as the same media size.
    /// The Epson PPD lists sizes like 209.97 x 297.01 mm, so a nominal A4 misses an exact match by a hair.
    static let mediaSnapTolerance = 50

    /// Snaps a size onto the printer's own `media-col-database` numbers when it is within tolerance.
    /// An exact match stays as it is. Otherwise the nearest fixed size wins; failing that, a roll entry
    /// whose length range covers `y` and whose width is close takes over the width only.
    static func snappedMediaSize(x: Int32, y: Int32, database: [MediaColEntry]) -> (x: Int32, y: Int32) {
        let wantX = Int(x), wantY = Int(y)
        let fixed = database.filter { $0.yDimensionMax == nil && $0.xDimension > 0 && $0.yDimension > 0 }
        if fixed.contains(where: { $0.xDimension == wantX && $0.yDimension == wantY }) {
            return (x, y)
        }
        let nearest = fixed
            .filter { abs($0.xDimension - wantX) <= mediaSnapTolerance && abs($0.yDimension - wantY) <= mediaSnapTolerance }
            .min { abs($0.xDimension - wantX) + abs($0.yDimension - wantY) < abs($1.xDimension - wantX) + abs($1.yDimension - wantY) }
        if let nearest {
            return (Int32(clamping: nearest.xDimension), Int32(clamping: nearest.yDimension))
        }
        let roll = database
            .filter { entry in
                guard let maxY = entry.yDimensionMax else { return false }
                return wantY >= entry.yDimension && wantY <= maxY && abs(entry.xDimension - wantX) <= mediaSnapTolerance
            }
            .min { abs($0.xDimension - wantX) < abs($1.xDimension - wantX) }
        if let roll {
            return (Int32(clamping: roll.xDimension), y)
        }
        return (x, y)
    }

    /// Picks the `media-source` keyword for a paper source from the ones this printer lists.
    ///
    /// PWG leaves room for different names for the same tray (`roll-1`, `main-roll`, `by-pass-tray`), so
    /// an exact match comes first and then a name that plainly means the same thing. Returns nil when the
    /// printer lists sources and none of them fits, so the printer's own default is used.
    static func mediaSourceKeyword(for source: PaperSource, capabilities: PrinterCapabilities?) -> String? {
        let wanted = source.ippMediaSource
        guard let capabilities else { return wanted }
        var listed = capabilities.mediaSourceSupported
        for entry in capabilities.mediaColDatabase {
            if let name = entry.source, !listed.contains(name) { listed.append(name) }
        }
        if listed.isEmpty || listed.contains(wanted) { return wanted }

        let hints: [String]
        switch source {
        case .rollPaper:
            hints = ["roll"]
        case .autoSheetFeeder:
            hints = ["auto", "main", "tray", "feeder"]
        case .sheet:
            hints = ["manual", "by-pass", "bypass", "sheet", "rear", "tray", "main"]
        }
        // `main-roll` must not satisfy the "main" hint of a cut-sheet source.
        let eligible = source == .rollPaper ? listed : listed.filter { !$0.lowercased().contains("roll") }
        for hint in hints {
            if let match = eligible.first(where: { $0.lowercased().contains(hint) }) { return match }
        }
        return nil
    }

    private static func mediaDimensionsHundredthsMM(for settings: PrintSettings) -> (x: Int32, y: Int32) {
        let docSize = settings.effectivePaperSize
        let widthMM: Double
        let heightMM: Double

        switch settings.outputSize {
        case .fitToRollPaperWidth, .banner:
            widthMM = settings.rollWidth.widthMM
            heightMM = docSize.heightMM
        case .specifySize, .outputSize:
            let target = settings.specifiedOutputSize ?? docSize
            widthMM = target.widthMM
            heightMM = target.heightMM
        case .sameAsPaperSize, .retainScale:
            widthMM = docSize.widthMM
            heightMM = docSize.heightMM
        }

        let x = Int32((widthMM * 100.0).rounded())
        let y = Int32((heightMM * 100.0).rounded())
        return (x, y)
    }
}

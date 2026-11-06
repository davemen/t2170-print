import CoreGraphics
import Foundation

/// A job the app turned down itself, before anything went to the printer.
enum PrintRefusal: LocalizedError, Equatable {
    case notAccepting
    case stopped(reasons: [String])
    case rollMismatch(setting: String, loaded: String)
    case sheetWiderThanRoll(setting: String)
    case notEnoughSpace(needed: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .notAccepting:
            return "The printer is not accepting jobs right now. Check its screen for a paused queue or an error. "
                + "Nothing was sent."
        case .stopped(let reasons):
            return "The printer is stopped and reports: \(reasons.joined(separator: ", ")). "
                + "Nothing was sent. Sort it out on the printer and print again."
        case .rollMismatch(let setting, let loaded):
            return "Roll Width is set to \(setting), but the printer has a \(loaded) roll loaded. "
                + "Nothing was sent. Change Roll Width to match the roll and print again."
        case .sheetWiderThanRoll(let setting):
            return "This page is wider than the \(setting) roll and can't be turned to fit. Nothing was sent. "
                + "Change Roll Width, or use Fit to Roll Paper Width."
        case .notEnoughSpace(let needed, let available):
            let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            return "This job can need up to \(format(needed)) of free space on this iPad, and \(format(available)) "
                + "is free. Free up some space, or choose PDF under \"Send as\" if the printer offers it, and print again."
        }
    }
}

/// The checks made before a job is sent. They are pure, so each can be tested without a printer.
enum PrintReadiness {
    /// Roll widths closer together than this are the same roll.
    private static let rollToleranceMM = 2.0

    /// What a fresh look at the printer rules out. Anything unclear goes ahead: the printer has the last word.
    static func refusal(settings: PrintSettings, capabilities: PrinterCapabilities) -> PrintRefusal? {
        if capabilities.isAcceptingJobs == false {
            return .notAccepting
        }
        // Stopped alone is not enough: a printer can report it while paused or asleep and still take a
        // job. An `-error` reason is the printer saying it can't go on; `-report` and `-warning` are notes.
        let errors = capabilities.stateReasons.filter { $0.hasSuffix("-error") }
        if capabilities.state == 5, !errors.isEmpty {
            return .stopped(reasons: errors)
        }
        guard settings.paperSource == .rollPaper else { return nil }

        // A range is a size the printer could take, not a measured roll.
        let loaded = (capabilities.mediaColReady ?? [])
            .filter { $0.isRoll && $0.xDimension > 0 && $0.xDimensionMax == nil }
            .map { Double($0.xDimension) / 100.0 }
        guard !loaded.isEmpty,
              !loaded.contains(where: { abs($0 - settings.rollWidth.widthMM) <= rollToleranceMM })
        else { return nil }
        // A roll with no matching choice can't be fixed from here, so let the printer decide.
        for width in loaded {
            if let match = RollWidth.allCases.first(where: { abs($0.widthMM - width) <= rollToleranceMM }) {
                return .rollMismatch(setting: settings.rollWidth.label, loaded: match.label)
            }
        }
        return nil
    }

    /// A sheet that is wider than the roll both ways round would print clipped or not at all.
    static func widthRefusal(plans: [SheetPlan], settings: PrintSettings) -> PrintRefusal? {
        guard settings.paperSource == .rollPaper else { return nil }
        let rollPt = settings.rollWidth.widthMM * 72.0 / 25.4
        let tooWide = plans.contains { MediaGeometry(plan: $0, settings: settings).mediaPt.width > rollPt + 0.5 }
        return tooWide ? .sheetWiderThanRoll(setting: settings.rollWidth.label) : nil
    }

    /// Uncompressed size of these sheets: the most a raster spool can come to, before its small headers.
    static func rasterBytes(plans: [SheetPlan], settings: PrintSettings, dpi: Int, gray: Bool) -> Int64 {
        let bytesPerPixel: Int64 = gray ? 1 : 3
        return plans.reduce(into: Int64(0)) { total, plan in
            let mediaPt = MediaGeometry(plan: plan, settings: settings).mediaPt
            let width = Int64(max(1, (mediaPt.width / 72.0 * CGFloat(dpi)).rounded()))
            let height = Int64(max(1, (mediaPt.height / 72.0 * CGFloat(dpi)).rounded()))
            total += width * height * bytesPerPixel
        }
    }

    /// The spool and the request body IPPClient builds from it exist at the same time, hence the doubling.
    static func diskRefusal(rasterBytes: Int64, available: Int64?) -> PrintRefusal? {
        guard let available, available > 0 else { return nil }
        let needed = rasterBytes * 2
        return needed > available ? .notEnoughSpace(needed: needed, available: available) : nil
    }

    static func availableDiskBytes() -> Int64? {
        let values = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

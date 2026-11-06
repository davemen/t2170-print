import CoreGraphics
import Foundation

/// How an imposed sheet sits on the media the printer loads.
///
/// IPP media is described by its feed-direction orientation (`x-dimension` is the shorter edge for cut
/// sheets, and the roll width for roll paper), so a landscape sheet has to be turned a quarter turn onto
/// portrait media. Sending it unturned would ask for media the printer does not have.
struct MediaGeometry: Sendable, Equatable {
    var sheetPt: CGSize
    var mediaPt: CGSize
    var rotated: Bool

    var mediaMM: CGSize {
        CGSize(width: mediaPt.width * 25.4 / 72.0, height: mediaPt.height * 25.4 / 72.0)
    }

    init(sheetPt: CGSize, paperSource: PaperSource, rollWidthMM: Double) {
        self.sheetPt = sheetPt
        let shouldRotate: Bool
        if paperSource == .rollPaper {
            let rollPt = rollWidthMM * 72.0 / 25.4
            // Half a point of slack absorbs mm-to-point rounding on a sheet exactly as wide as the roll.
            shouldRotate = sheetPt.width > rollPt + 0.5 && sheetPt.height <= rollPt + 0.5
        } else {
            shouldRotate = sheetPt.width > sheetPt.height
        }
        rotated = shouldRotate
        mediaPt = shouldRotate ? CGSize(width: sheetPt.height, height: sheetPt.width) : sheetPt
    }

    init(plan: SheetPlan, settings: PrintSettings) {
        self.init(
            sheetPt: plan.sheetSizePt,
            paperSource: settings.paperSource,
            rollWidthMM: settings.rollWidth.widthMM
        )
    }

    /// Maps top-left sheet coordinates onto top-left media coordinates: `(x, y) -> (y, sheetWidth - x)`.
    /// That is a 90 degree anticlockwise turn with no mirroring, the same turn as IPP `landscape`.
    var sheetToMedia: CGAffineTransform {
        guard rotated else { return .identity }
        return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: sheetPt.width)
    }
}

/// Consecutive sheets that share one media size and so go out as one Print-Job.
/// `media-col` applies to a whole job, so a change of size needs a new job.
struct PrintBatch: Sendable, Equatable {
    var plans: [SheetPlan]
    var mediaMM: CGSize

    static func make(plans: [SheetPlan], settings: PrintSettings) -> [PrintBatch] {
        var batches: [PrintBatch] = []
        var lastKey: [Int] = []
        for plan in plans {
            let mm = MediaGeometry(plan: plan, settings: settings).mediaMM
            let key = [Int((mm.width * 100).rounded()), Int((mm.height * 100).rounded())]
            if key == lastKey, !batches.isEmpty {
                batches[batches.count - 1].plans.append(plan)
            } else {
                batches.append(PrintBatch(plans: [plan], mediaMM: mm))
                lastKey = key
            }
        }
        return batches
    }
}

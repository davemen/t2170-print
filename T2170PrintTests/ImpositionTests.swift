import CoreGraphics
import Testing
@testable import T2170Print

@Suite("Imposition Tests")
struct ImpositionTests {
    private let a4Page = CGSize(width: 595.28, height: 841.89)

    @Test("A4 portrait source page with default settings produces one 595x842 pt sheet with one cell inside 3 mm margins")
    func defaultA4Portrait() {
        let settings = PrintSettings()
        let plans = Imposer.plan(settings: settings, pageSizes: [a4Page])

        #expect(plans.count == 1)
        let sheet = plans[0]
        #expect(Int(sheet.sheetSizePt.width.rounded()) == 595)
        #expect(Int(sheet.sheetSizePt.height.rounded()) == 842)
        #expect(sheet.cells.count == 1)

        let marginPt = Imposer.mmToPt(3.0)
        let cell = sheet.cells[0]
        #expect(cell.sourcePage == 0)
        #expect(cell.frame.minX >= marginPt - 0.01)
        #expect(cell.frame.minY >= marginPt - 0.01)
        #expect(cell.frame.maxX <= sheet.sheetSizePt.width - marginPt + 0.01)
        #expect(cell.frame.maxY <= sheet.sheetSizePt.height - marginPt + 0.01)
    }

    @Test("Fit to 24-inch roll width with 1000x500 landscape page and autoRotate")
    func fitToRollPaperWidth24Inch() {
        var settings = PrintSettings()
        settings.outputSize = .fitToRollPaperWidth
        settings.rollWidth = .w24in
        settings.advanced.autoRotate = true

        let plans = Imposer.plan(
            settings: settings,
            pageSizes: [CGSize(width: 1000, height: 500)]
        )

        #expect(plans.count == 1)
        let sheet = plans[0]
        #expect(abs(sheet.sheetSizePt.width - 1728.0) < 0.01)
        #expect(sheet.cells.count == 1)

        let cell = sheet.cells[0]
        // Sheet stays the roll's width; the page stays inside the printer's side margins.
        let printable = 1728.0 - 2.0 * Imposer.mmToPt(3.0)
        #expect(abs(cell.frame.minX - Imposer.mmToPt(3.0)) < 0.01)
        #expect(abs(cell.frame.width - printable) < 0.01)
        #expect(abs(cell.frame.height - printable / 2.0) < 0.01)
    }

    @Test("Pages per sheet 4 with 5 pages produces 2 sheets with first 4 cells in lrtb order")
    func pagesPerSheetFourWithFivePages() {
        var settings = PrintSettings()
        settings.layout.pagesPerSheet = .four
        settings.layout.layoutDirection = .leftRightTopBottom

        let pages = Array(repeating: a4Page, count: 5)
        let plans = Imposer.plan(settings: settings, pageSizes: pages)

        #expect(plans.count == 2)
        #expect(plans[0].cells.count == 4)
        #expect(plans[1].cells.count == 1)

        let cells = plans[0].cells
        #expect(cells.map(\.sourcePage) == [0, 1, 2, 3])
        // Top row: left (0) then right (1)
        #expect(cells[0].frame.minX < cells[1].frame.minX)
        #expect(abs(cells[0].frame.minY - cells[1].frame.minY) < 0.01)
        // Bottom row: below top row, left (2) then right (3)
        #expect(cells[0].frame.minY < cells[2].frame.minY)
        #expect(abs(cells[0].frame.minX - cells[2].frame.minX) < 0.01)
        #expect(cells[2].frame.minX < cells[3].frame.minX)
        #expect(abs(cells[2].frame.minY - cells[3].frame.minY) < 0.01)
    }

    @Test("Poster 2x2 produces 4 sheets per page with crop marks")
    func posterTwoByTwo() {
        var settings = PrintSettings()
        settings.layout.poster = .twoByTwo
        settings.layout.posterOverlapMM = 10

        let plans = Imposer.plan(settings: settings, pageSizes: [a4Page, a4Page])

        #expect(plans.count == 8)
        #expect(plans.allSatisfy { $0.cutMarks && $0.cells.count == 1 })
        #expect(plans.prefix(4).allSatisfy { $0.cells[0].sourcePage == 0 })
        #expect(plans.suffix(4).allSatisfy { $0.cells[0].sourcePage == 1 })
    }

    @Test("Copies 2 collated vs uncollated ordering")
    func copiesCollatedVsUncollated() {
        let pages = [a4Page, a4Page]

        var collatedSettings = PrintSettings()
        collatedSettings.copies = 2
        collatedSettings.paperHandling.collate = true
        let collatedPlans = Imposer.plan(settings: collatedSettings, pageSizes: pages)
        #expect(collatedPlans.count == 4)
        #expect(collatedPlans.map { $0.cells[0].sourcePage } == [0, 1, 0, 1])

        var uncollatedSettings = PrintSettings()
        uncollatedSettings.copies = 2
        uncollatedSettings.paperHandling.collate = false
        let uncollatedPlans = Imposer.plan(settings: uncollatedSettings, pageSizes: pages)
        #expect(uncollatedPlans.count == 4)
        #expect(uncollatedPlans.map { $0.cells[0].sourcePage } == [0, 0, 1, 1])
    }

    @Test("Pages to print oddOnly with 4 pages produces 2 sheets")
    func pagesToPrintOddOnly() {
        var settings = PrintSettings()
        settings.paperHandling.pagesToPrint = .oddOnly

        let pages = Array(repeating: a4Page, count: 4)
        let plans = Imposer.plan(settings: settings, pageSizes: pages)

        #expect(plans.count == 2)
        #expect(plans.map { $0.cells[0].sourcePage } == [0, 2])
    }

    @Test("Page order reverse")
    func pageOrderReverse() {
        var settings = PrintSettings()
        settings.paperHandling.pageOrder = .reverse

        let pages = Array(repeating: a4Page, count: 4)
        let plans = Imposer.plan(settings: settings, pageSizes: pages)

        #expect(plans.count == 4)
        #expect(plans.map { $0.cells[0].sourcePage } == [3, 2, 1, 0])
    }

    @Test("Page range 2...3 selects only pages 2 and 3")
    func pageRangeTwoToThree() {
        var settings = PrintSettings()
        settings.pageRange = .range(from: 2, to: 3)

        let pages = Array(repeating: a4Page, count: 5)
        let plans = Imposer.plan(settings: settings, pageSizes: pages)

        #expect(plans.count == 2)
        #expect(plans.map { $0.cells[0].sourcePage } == [1, 2])
    }

    @Test("Fit to roll with landscape orientation keeps every sheet at roll width")
    func fitToRollLandscapeKeepsRollWidth() {
        var settings = PrintSettings()
        settings.outputSize = .fitToRollPaperWidth
        settings.rollWidth = .w24in
        settings.orientation = .landscape

        let letterPortrait = CGSize(width: 612, height: 792)
        let plans = Imposer.plan(settings: settings, pageSizes: [letterPortrait, letterPortrait])

        #expect(plans.count == 2)
        for plan in plans {
            #expect(abs(plan.sheetSizePt.width - 24.0 * 72.0) < 0.5)
            #expect(plan.cells.count == 1)
            #expect(plan.cells[0].rotation == 90)
        }
    }

    @Test("Poster with flipHorizontally mirrors the tile order")
    func posterFlipRemapsTiles() {
        var settings = PrintSettings()
        settings.layout.poster = .twoByTwo
        settings.layout.flipHorizontally = false
        let plain = Imposer.plan(settings: settings, pageSizes: [a4Page])
        settings.layout.flipHorizontally = true
        let flipped = Imposer.plan(settings: settings, pageSizes: [a4Page])

        #expect(plain.count == 4)
        #expect(flipped.count == 4)
        // Sheet 0 (top-left) of the flipped poster shows the source's top-right tile.
        #expect(abs(flipped[0].cells[0].sourceRect.minX - plain[1].cells[0].sourceRect.minX) < 1e-9)
        #expect(abs(flipped[0].cells[0].sourceRect.minY - plain[1].cells[0].sourceRect.minY) < 1e-9)
    }
}

@Suite("Roll and banner stay inside the side margins")
struct RollMarginTests {
    private let margin = Imposer.mmToPt(3.0)

    private func banner(lengthMM: Double = 1000) -> PrintSettings {
        var s = PrintSettings()
        s.paperSource = .rollPaper
        s.rollWidth = .a3
        s.outputSize = .banner
        s.bannerLengthMM = lengthMM
        return s
    }

    private func checkInset(_ plans: [SheetPlan]) {
        for plan in plans {
            for cell in plan.cells {
                #expect(cell.frame.minX >= margin - 0.01)
                #expect(cell.frame.maxX <= plan.sheetSizePt.width - margin + 0.01)
                #expect(cell.frame.minY >= margin - 0.01)
                #expect(cell.frame.maxY <= plan.sheetSizePt.height - margin + 0.01)
            }
        }
    }

    @Test("A short banner ends where its content does")
    func shortBanner() throws {
        let plans = Imposer.plan(settings: banner(), pageSizes: [CGSize(width: 600, height: 300)])
        let plan = try #require(plans.first)
        #expect(plans.count == 1)
        let cell = try #require(plan.cells.first)
        #expect(abs(plan.sheetSizePt.height - (cell.frame.maxY + margin)) < 0.01)
        #expect(plan.sheetSizePt.height < Imposer.mmToPt(1000))
        checkInset(plans)
    }

    @Test("Pages past the banner length start a new sheet, and none overruns its sheet")
    func overflow() {
        let plans = Imposer.plan(settings: banner(), pageSizes: Array(repeating: CGSize(width: 825, height: 1000), count: 5))
        #expect(plans.map(\.cells.count).reduce(0, +) == 5)
        #expect(plans.count > 1)
        checkInset(plans)
        for plan in plans {
            #expect(plan.sheetSizePt.height <= Imposer.mmToPt(1000) + 0.01)
        }
    }

    @Test("A page taller than the banner length runs on rather than being cut off")
    func oversized() throws {
        let plans = Imposer.plan(settings: banner(), pageSizes: [CGSize(width: 825, height: 5000)])
        let plan = try #require(plans.first)
        #expect(plans.count == 1)
        #expect(plan.sheetSizePt.height > Imposer.mmToPt(1000))
        checkInset(plans)
    }

    @Test("Two up on a roll keeps both pages off the edges")
    func grid() {
        var s = PrintSettings()
        s.paperSource = .rollPaper
        s.rollWidth = .a3
        s.outputSize = .fitToRollPaperWidth
        s.layout.pagesPerSheet = .two
        let plans = Imposer.plan(settings: s, pageSizes: Array(repeating: CGSize(width: 600, height: 800), count: 2))
        #expect(plans.map(\.cells.count).reduce(0, +) == 2)
        for plan in plans {
            for cell in plan.cells {
                #expect(cell.frame.minX >= margin - 0.01)
                #expect(cell.frame.maxX <= plan.sheetSizePt.width - margin + 0.01)
            }
        }
    }
}

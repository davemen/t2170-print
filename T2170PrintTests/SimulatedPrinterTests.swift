import Foundation
import Testing
import UIKit
@testable import T2170Print

// Drives the real PrintSession against real IPP servers. test-sim.sh starts them, runs this suite and
// then checks what each printer received with tools/check_spool.py. Skipped when T2170_SIM is unset,
// so the plain unit run needs no daemon.

private func printers() -> [String: String] {
    let raw = ProcessInfo.processInfo.environment["T2170_SIM"] ?? ""
    var result: [String: String] = [:]
    for pair in raw.split(separator: ",") {
        let parts = pair.split(separator: "=", maxSplits: 1)
        if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
    }
    return result
}

/// One page per entry. Quadrants are red, green / blue, grey so any flip or turn shows up, and the
/// grey level is 60 x the page index so page order shows up.
func writeQuadrantPDF(named name: String, pages: [CGSize]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    let first = pages.first ?? CGSize(width: 595, height: 842)
    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first))
    try renderer.writePDF(to: url) { context in
        for (index, size) in pages.enumerated() {
            context.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
            let cg = context.cgContext
            let w = size.width / 2, h = size.height / 2
            let grey = CGFloat(index * 60) / 255
            let fills: [(CGRect, UIColor)] = [
                (CGRect(x: 0, y: 0, width: w, height: h), UIColor(red: 1, green: 0, blue: 0, alpha: 1)),
                (CGRect(x: w, y: 0, width: w, height: h), UIColor(red: 0, green: 1, blue: 0, alpha: 1)),
                (CGRect(x: 0, y: h, width: w, height: h), UIColor(red: 0, green: 0, blue: 1, alpha: 1)),
                (CGRect(x: w, y: h, width: w, height: h), UIColor(red: grey, green: grey, blue: grey, alpha: 1)),
            ]
            for (rect, color) in fills {
                cg.setFillColor(color.cgColor)
                cg.fill(rect)
            }
        }
    }
    return url
}

@MainActor
func connectedSession(uri: String, document: URL) async throws -> PrintSession {
    let defaults = try #require(UserDefaults(suiteName: "t2170.sim.\(UUID().uuidString)"))
    let session = PrintSession(defaults: defaults)
    await session.connect(host: uri)
    #expect(session.lastError == nil, "connect: \(session.lastError ?? "")")
    try #require(session.capabilities != nil)
    session.loadDocument(url: document)
    for _ in 0..<500 where session.pageCount == 0 && session.lastError == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(session.pageCount > 0)
    return session
}

struct SimScenario: Sendable, CustomTestStringConvertible {
    var name: String
    var printer: String
    var pages: [CGSize] = [a4]
    var send: SendFormatChoice = .automatic
    var sentFormat: String?
    var expectedError: String?
    var keepsSource = false
    var change: @Sendable (inout PrintSettings) -> Void = { _ in }
    var testDescription: String { name }

    static let a4 = CGSize(width: 595.28, height: 841.89)
    static let a4Wide = CGSize(width: 841.89, height: 595.28)
    static let a2 = CGSize(width: 1190.55, height: 1683.78)
}

private func sheetA4(_ s: inout PrintSettings) {
    s.paperSource = .sheet
    s.paperSize = PaperSize.standard[0]
}

private let scenarios: [SimScenario] = [
    SimScenario(name: "s01-auto", printer: "ppd", sentFormat: "URF, 300 dpi, colour") { sheetA4(&$0) },
    SimScenario(name: "s02-pwg", printer: "ppd", send: .pwgRaster, sentFormat: "PWG Raster, 300 dpi, colour") { sheetA4(&$0) },
    SimScenario(name: "s03-pdf", printer: "ppd", send: .pdf, sentFormat: "PDF") { sheetA4(&$0) },
    SimScenario(name: "s04-grey", printer: "ppd", sentFormat: "URF, 300 dpi, grey") { sheetA4(&$0); $0.printMode = .black },
    SimScenario(name: "s05-pwggrey", printer: "ppd", send: .pwgRaster, sentFormat: "PWG Raster, 300 dpi, grey") {
        sheetA4(&$0); $0.printMode = .black
    },
    SimScenario(name: "s06-landscape", printer: "ppd", pages: [SimScenario.a4Wide], sentFormat: "URF, 300 dpi, colour") {
        sheetA4(&$0); $0.orientation = .landscape
    },
    SimScenario(name: "s07-pwglandscape", printer: "ppd", pages: [SimScenario.a4Wide], send: .pwgRaster,
                sentFormat: "PWG Raster, 300 dpi, colour") { sheetA4(&$0); $0.orientation = .landscape },
    SimScenario(name: "s08-copies", printer: "ppd", pages: [SimScenario.a4, SimScenario.a4, SimScenario.a4],
                sentFormat: "URF, 300 dpi, colour") { sheetA4(&$0); $0.copies = 2 },
    SimScenario(name: "s09-mixed", printer: "ppd", pages: [SimScenario.a4, SimScenario.a4Wide],
                sentFormat: "URF, 300 dpi, colour") {
        $0.paperSource = .rollPaper; $0.rollWidth = .a3; $0.outputSize = .fitToRollPaperWidth
    },
    SimScenario(name: "s10-roll24", printer: "ppd", pages: [SimScenario.a2], sentFormat: "URF, 300 dpi, colour") {
        $0.paperSource = .rollPaper; $0.rollWidth = .w24in; $0.outputSize = .fitToRollPaperWidth
    },
    SimScenario(name: "s11-urfonly", printer: "urf", sentFormat: "URF, 600 dpi, grey") { sheetA4(&$0); $0.printMode = .black },
    SimScenario(name: "s12-pwgonly", printer: "pwg", sentFormat: "PWG Raster, 300 dpi, grey") { sheetA4(&$0); $0.printMode = .black },
    SimScenario(name: "s13-pdfonly", printer: "pdf", sentFormat: "PDF") { sheetA4(&$0) },
    SimScenario(name: "s14-greyonlycolour", printer: "pwg", expectedError: "cannot make any format") { sheetA4(&$0) },
    SimScenario(name: "s15-feeder", printer: "ppd", sentFormat: "URF, 300 dpi, colour", keepsSource: true) {
        sheetA4(&$0); $0.paperSource = .autoSheetFeeder
    },
    SimScenario(name: "s17-twoup", printer: "ppd", pages: [SimScenario.a4, SimScenario.a4],
                sentFormat: "URF, 300 dpi, colour") { sheetA4(&$0); $0.layout.pagesPerSheet = .two },
    SimScenario(name: "s18-poster", printer: "ppd", sentFormat: "URF, 300 dpi, colour") {
        sheetA4(&$0); $0.layout.poster = .twoByTwo
    },
    SimScenario(name: "s19-banner", printer: "ppd", pages: [SimScenario.a4, SimScenario.a4],
                sentFormat: "URF, 300 dpi, colour") {
        $0.paperSource = .rollPaper; $0.rollWidth = .w24in; $0.outputSize = .banner; $0.bannerLengthMM = 1000
    },
    SimScenario(name: "s16-high", printer: "pwg", sentFormat: "PWG Raster, 600 dpi, grey") {
        sheetA4(&$0); $0.printMode = .black; $0.printWithHighQuality = true
    },
]

@Suite(
    "Full print flow against simulated printers",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["T2170_SIM"] != nil)
)
@MainActor
struct SimulatedPrinterTests {
    @Test(arguments: scenarios)
    func printScenario(_ scenario: SimScenario) async throws {
        let uri = try #require(printers()[scenario.printer], "no \(scenario.printer) printer running")
        let document = try writeQuadrantPDF(named: "\(scenario.name).pdf", pages: scenario.pages)
        let session = try await connectedSession(uri: uri, document: document)
        scenario.change(&session.settings)
        session.sendFormat = scenario.send

        await session.print()

        if let expected = scenario.expectedError {
            #expect(session.lastError?.contains(expected) == true, "got: \(session.lastError ?? "no error")")
            #expect(session.lastJob == nil)
            return
        }
        #expect(session.lastError == nil, "\(session.lastError ?? "")")
        #expect(session.lastJob?.jobState == .completed, "\(session.printerStatusText)")
        #expect(session.lastSentFormat == scenario.sentFormat)
        // The printers here list only media-source "auto", so "manual" and "roll-1" are rightly dropped.
        var allowed: Set<String> = scenario.keepsSource ? [] : ["media-source"]
        // No custom size range here, so custom sizes lose media-col and the raster carries the size.
        if ["s09-mixed", "s10-roll24", "s19-banner"].contains(scenario.name) { allowed.formUnion(["media-col", "finishings"]) }
        // The plain PDF simulator is monochrome only.
        if scenario.name == "s13-pdfonly" { allowed.insert("print-color-mode") }
        #expect(Set(session.unsupportedAttributes).isSubset(of: allowed), "\(session.unsupportedAttributes)")
    }
}

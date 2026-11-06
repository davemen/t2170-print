import Darwin
import Foundation
import Testing
@testable import T2170Print

// Drives the real PrintSession against tools/fake_ipp.py, a printer that misbehaves on purpose. The
// URL path picks the fault, and the fake logs what reached it, so these tests check the wire as well
// as what the user is told. Skipped when T2170_FAKE is unset. Each scenario name is used once per fake
// run because the fake keeps counters per scenario.

private let fakeBase = ProcessInfo.processInfo.environment["T2170_FAKE"] ?? ""

struct FakeRaster: Decodable, Sendable {
    var magic: String
    var width: Int?
    var height: Int?
    var dpi: Int?
}

struct FakeRequest: Decodable, Sendable {
    var op: String
    var n: Int
    var version: String
    var requestId: Int
    var contentType: String?
    var contentLength: Int?
    var bodyLength: Int
    var format: String?
    var attrs: [String: [String]]
    var raster: FakeRaster?
}

private func fakeURI(_ scenario: String) -> String {
    fakeBase.replacingOccurrences(of: "http://", with: "ipp://") + "/\(scenario)/ipp/print"
}

private func fakeLog(_ scenario: String) async throws -> [FakeRequest] {
    let url = try #require(URL(string: "\(fakeBase)/__log/\(scenario)"))
    let (data, _) = try await URLSession(configuration: .ephemeral).data(from: url)
    return try JSONDecoder().decode([FakeRequest].self, from: data)
}

private extension Array where Element == FakeRequest {
    var jobs: [FakeRequest] { filter { $0.op == "Print-Job" } }
    var validates: [FakeRequest] { filter { $0.op == "Validate-Job" } }
    var polls: [FakeRequest] { filter { $0.op == "Get-Job-Attributes" } }
}

private func sheetA4(_ s: inout PrintSettings) {
    s.paperSource = .sheet
    s.paperSize = PaperSize.standard[0]
}

private func rollA3(_ s: inout PrintSettings) {
    s.paperSource = .rollPaper
    s.rollWidth = .a3
    s.outputSize = .fitToRollPaperWidth
}

@MainActor
private func report(_ name: String, _ session: PrintSession, _ log: [FakeRequest]) {
    let ops = log.map { "\($0.op)\($0.format.map { "(\($0))" } ?? "")" }.joined(separator: " ")
    Swift.print("FAKE \(name) | error=\(session.lastError ?? "nil") | status=\(session.printerStatusText) | sent=\(session.lastSentFormat ?? "nil") | \(ops)")
}

struct PrintCase: Sendable, CustomTestStringConvertible {
    var name: String
    var roll = false
    var pages: [CGSize] = [SimScenario.a4]
    var check: @MainActor @Sendable (PrintSession, [FakeRequest]) -> Void
    var testDescription: String { name }
}

/// The paper size must survive a refusal; media-source and media-type are what gets given up.
private func keptSizeOnly(_ job: FakeRequest?) {
    let members = job?.attrs["media-col"] ?? []
    #expect(members.contains { $0.hasPrefix("x-dimension=") })
    #expect(members.contains { $0.hasPrefix("y-dimension=") })
    #expect(!members.contains { $0.hasPrefix("media-source=") })
}

@MainActor private func leftSizeToPageHeader(_ s: PrintSession, _ log: [FakeRequest], jobs: Int) {
    #expect(log.jobs.count == jobs)
    #expect(log.jobs.last?.attrs["media-col"] == nil)
    #expect(log.jobs.last?.format != "application/pdf")
    #expect((log.jobs.last?.raster?.height ?? 0) > 0)
    #expect(s.paperSizeLeftToPrinter)
}

@MainActor private func succeeded(_ s: PrintSession) {
    #expect(s.lastError == nil, "unexpected error: \(s.lastError ?? "")")
    #expect(s.lastJob != nil)
}

@MainActor private func failed(_ s: PrintSession, mentioning text: String? = nil) {
    let message = s.lastError ?? ""
    #expect(!message.isEmpty, "the user was told nothing")
    if let text { #expect(message.contains(text), "message was: \(message)") }
}

private let urf = "image/urf", pwg = "image/pwg-raster", pdf = "application/pdf"

private let printCases: [PrintCase] = [
    PrintCase(name: "ok") { s, log in
        succeeded(s)
        let job = log.jobs.first
        #expect(log.jobs.count == 1)
        #expect(log.polls.count >= 3)
        #expect(job?.format == urf)
        #expect(job?.raster?.magic == "URF")
        for request in log {
            #expect(request.contentType == "application/ipp", "\(request.op)")
            #expect(request.version == "2.0", "\(request.op)")
            #expect(request.requestId != 0, "\(request.op)")
            #expect(request.contentLength == request.bodyLength, "\(request.op)")
        }
    },
    PrintCase(name: "ok-roll", roll: true) { s, log in
        succeeded(s)
        let attrs = log.jobs.first?.attrs ?? [:]
        let media = attrs["media-col"] ?? []
        #expect(media.contains("media-source=roll-1"), "\(media)")
        #expect(media.contains("x-dimension=29700"), "\(media)")
        #expect(attrs["finishings"] != nil)
        #expect(s.unsupportedAttributes.isEmpty, "\(s.unsupportedAttributes)")
    },
    PrintCase(name: "no-custom", roll: true) { s, log in
        succeeded(s)
        #expect(log.jobs.count == 1)
    },

    // Format refusals
    PrintCase(name: "print-refuse-urf") { s, log in
        succeeded(s)
        #expect(log.jobs.map(\.format) == [urf, pwg])
        #expect(s.lastSentFormat?.contains("PWG") == true)
    },
    PrintCase(name: "validate-refuse-urf") { s, log in
        succeeded(s)
        #expect(log.jobs.map(\.format) == [pwg])
    },
    PrintCase(name: "print-040b-format") { s, log in
        succeeded(s)
        #expect(log.jobs.map(\.format) == [urf, pwg])
    },
    PrintCase(name: "refuse-all") { s, log in
        failed(s)
        #expect(log.jobs.map(\.format) == [urf, pwg, pdf])
        #expect(s.lastJob == nil)
    },

    // Attribute refusals
    PrintCase(name: "drop-media-col", roll: true) { s, log in
        succeeded(s)
        #expect(log.jobs.count == 2)
        keptSizeOnly(log.jobs.last)
        #expect(s.unsupportedAttributes.contains("media-source"))
    },
    PrintCase(name: "drop-media-source", roll: true) { s, log in
        succeeded(s)
        #expect(log.jobs.count == 2)
        keptSizeOnly(log.jobs.last)
        #expect(s.unsupportedAttributes.contains("media-source"))
    },
    PrintCase(name: "echo-media-col", roll: true) { s, log in
        succeeded(s)
        #expect(log.jobs.count == 2)
        keptSizeOnly(log.jobs.last)
    },
    // A sheet job never gives up its size: without it the job could land on whatever paper is loaded.
    PrintCase(name: "refuse-media-size") { s, log in
        failed(s, mentioning: "paper size")
        #expect(log.jobs.count == 1)
        #expect(!s.paperSizeLeftToPrinter)
    },
    // PDF has no page header stating the size, so a roll job in PDF is refused too.
    PrintCase(name: "refuse-media-size-pdf", roll: true) { s, log in
        failed(s, mentioning: "paper size")
        #expect(log.jobs.count == 1)
        #expect(log.jobs.first?.format == "application/pdf")
        #expect(!s.paperSizeLeftToPrinter)
    },
    // A roll job in raster goes without media-col: each page header states the exact size.
    PrintCase(name: "refuse-media-size-roll", roll: true) { s, log in
        succeeded(s)
        leftSizeToPageHeader(s, log, jobs: 2)
    },
    PrintCase(name: "refuse-media-col-roll", roll: true) { s, log in
        succeeded(s)
        leftSizeToPageHeader(s, log, jobs: 3)
    },
    PrintCase(name: "echo-then-size-roll", roll: true) { s, log in
        succeeded(s)
        leftSizeToPageHeader(s, log, jobs: 3)
    },
    PrintCase(name: "wrong-roll", roll: true) { s, log in
        failed(s, mentioning: "Roll Width")
        #expect(log.jobs.isEmpty)
    },
    PrintCase(name: "right-roll", roll: true) { s, log in
        succeeded(s)
        #expect(log.jobs.count == 1)
    },
    PrintCase(name: "paused-now") { s, log in
        failed(s, mentioning: "not accepting jobs")
        #expect(log.jobs.isEmpty)
    },
    PrintCase(name: "always-040b", roll: true) { s, log in
        failed(s)
        #expect(log.jobs.count == 3)
    },
    PrintCase(name: "validate-040b", roll: true) { s, log in
        succeeded(s)
        #expect(log.validates.count == 2)
        #expect(log.jobs.first?.attrs["finishings"] == nil)
        #expect(s.unsupportedAttributes.contains("finishings"))
    },
    PrintCase(name: "validate-500") { s, log in
        succeeded(s)
        #expect(log.jobs.count == 1)
    },

    // Printer busy or unwilling
    PrintCase(name: "busy-twice") { s, log in
        succeeded(s)
        #expect(log.jobs.count == 3)
    },
    PrintCase(name: "busy-forever") { s, log in
        failed(s)
        #expect(log.jobs.count == 4)
    },
    PrintCase(name: "not-accepting") { s, log in
        failed(s, mentioning: "not accepting jobs")
        failed(s)
        #expect(log.jobs.count == 1)
    },
    PrintCase(name: "bad-request") { s, log in
        failed(s)
        #expect(log.jobs.count == 1)
    },
    PrintCase(name: "server-error") { s, log in
        failed(s)
        #expect(log.jobs.count == 1)
    },

    // Dropped connections. A Print-Job the printer read in full must never be sent again.
    PrintCase(name: "drop-mid-body") { s, log in
        #expect(log.jobs.filter { $0.bodyLength > 208 }.count <= 1)
        if log.jobs.count == 1 { failed(s) }
    },
    PrintCase(name: "drop-after-body") { s, log in
        #expect(log.jobs.count == 1, "the printer read the whole job, sending it again prints twice")
        failed(s, mentioning: "may or may not")
    },
    PrintCase(name: "poll-drop-3") { s, log in
        #expect(log.jobs.count == 1)
        succeeded(s)
    },
    PrintCase(name: "poll-drop-forever") { s, log in
        #expect(log.jobs.count == 1)
        #expect(s.printerStatusText.contains("lost contact"), "\(s.printerStatusText)")
        failed(s, mentioning: "Check the printer")
    },
    PrintCase(name: "poll-500-forever") { s, log in
        #expect(log.jobs.count == 1)
        #expect(s.printerStatusText.contains("lost contact"), "\(s.printerStatusText)")
        failed(s, mentioning: "Check the printer")
    },

    // How jobs end
    PrintCase(name: "job-instant") { s, _ in succeeded(s) },
    PrintCase(name: "no-job-state") { s, _ in succeeded(s) },
    PrintCase(name: "job-unknown-state") { s, _ in succeeded(s) },
    PrintCase(name: "job-gone") { s, log in
        succeeded(s)
        #expect(s.printerStatusText.contains("no longer lists"), "\(s.printerStatusText)")
    },
    PrintCase(name: "job-gone-at-once") { s, log in
        succeeded(s)
        #expect(s.printerStatusText.contains("no longer lists"), "\(s.printerStatusText)")
    },
    PrintCase(name: "job-gone-multi", roll: true, pages: [SimScenario.a4, SimScenario.a4Wide]) { s, log in
        succeeded(s)
        #expect(log.jobs.count == 2, "a purged first job must not stop the second")
    },
    PrintCase(name: "job-aborted") { s, log in
        failed(s, mentioning: "Send as")
        #expect(log.jobs.count == 1)
    },
    PrintCase(name: "job-canceled") { s, log in
        failed(s)
        #expect(log.jobs.count == 1)
    },
    PrintCase(name: "job-stopped") { s, log in
        succeeded(s)
        #expect(log.jobs.count == 1)
    },

    // Bad answers to Print-Job. The printer may have taken the job, so never resend.
    PrintCase(name: "print-html") { s, log in
        failed(s, mentioning: "may or may not")
        #expect(log.jobs.count == 1)
    },
    PrintCase(name: "print-garbage") { s, log in
        failed(s, mentioning: "may or may not")
        #expect(log.jobs.count == 1)
    },
    PrintCase(name: "no-job-id") { s, log in
        failed(s, mentioning: "may or may not")
        #expect(log.jobs.count == 1)
    },
    PrintCase(name: "ok-ignored") { s, log in
        succeeded(s)
        #expect(log.jobs.count == 1)
    },

    // Transport variations
    PrintCase(name: "version-503") { s, log in
        succeeded(s)
        #expect(log.jobs.map(\.version) == ["1.1"], "the downgrade happens at connect, so one job at 1.1")
    },
    PrintCase(name: "chunked") { s, _ in succeeded(s) },
    PrintCase(name: "conn-close") { s, _ in succeeded(s) },
    PrintCase(name: "continue-100") { s, _ in succeeded(s) },

    // Odd printer descriptions that should still connect and print
    PrintCase(name: "odd-values") { s, _ in succeeded(s) },
    PrintCase(name: "wrong-lengths") { s, _ in succeeded(s) },
    PrintCase(name: "empty-mcd") { s, _ in succeeded(s) },
    PrintCase(name: "huge-mcd") { s, _ in succeeded(s) },
    PrintCase(name: "trailing-bytes") { s, _ in succeeded(s) },
    PrintCase(name: "sparse") { s, log in
        succeeded(s)
        #expect(log.jobs.first?.format == urf)
    },
    PrintCase(name: "stopped") { s, log in
        failed(s, mentioning: "stopped")
        #expect(log.jobs.isEmpty)
    },
    PrintCase(name: "octet-only") { s, log in
        failed(s)
        #expect(log.jobs.isEmpty)
    },
    PrintCase(name: "connect-refuse-list") { s, log in
        succeeded(s)
        // Two to connect, one fresh look just before printing.
        #expect(log.filter { $0.op == "Get-Printer-Attributes" }.count == 3)
    },
]

private let connectFailures: [String: String] = [
    "connect-html": "not the way a printer does",
    "connect-426": "secure connections",
    "connect-401": "sign-in",
    "connect-garbage": "not the way a printer does",
    "connect-short": "not the way a printer does",
    "connect-truncated": "",
    "connect-drop": "",
]

/// Hosts that reach the fake over the LAN rather than localhost, which App Transport Security exempts
/// outright. These are the addresses a real printer has.
private let lanHosts = (ProcessInfo.processInfo.environment["T2170_FAKE_LAN"] ?? "")
    .split(separator: ",").map(String.init)

private actor PeakMemory {
    var peak: UInt64 = 0
    func sample() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS { peak = max(peak, info.phys_footprint) }
    }
}

@Suite("Misbehaving printer", .serialized, .enabled(if: ProcessInfo.processInfo.environment["T2170_FAKE"] != nil))
@MainActor
struct FailureTests {
    private func session(_ scenario: String, pages: [CGSize] = [SimScenario.a4]) async throws -> PrintSession {
        let document = try writeQuadrantPDF(named: "\(scenario).pdf", pages: pages)
        return try await connectedSession(uri: fakeURI(scenario), document: document)
    }

    @Test(arguments: printCases)
    func printing(_ testCase: PrintCase) async throws {
        let s = try await session(testCase.name, pages: testCase.pages)
        if testCase.roll { rollA3(&s.settings) } else { sheetA4(&s.settings) }
        await s.print()
        let log = try await fakeLog(testCase.name)
        report(testCase.name, s, log)
        #expect(!s.isPrinting)
        testCase.check(s, log)
    }

    @Test(arguments: connectFailures.keys.sorted())
    func connecting(_ scenario: String) async throws {
        let defaults = try #require(UserDefaults(suiteName: "t2170.fake.\(UUID().uuidString)"))
        let s = PrintSession(defaults: defaults)
        await s.connect(host: fakeURI(scenario))
        report(scenario, s, try await fakeLog(scenario))
        failed(s, mentioning: connectFailures[scenario].flatMap { $0.isEmpty ? nil : $0 })
        #expect(s.capabilities == nil)
    }

    @Test func nothingListening() async throws {
        let defaults = try #require(UserDefaults(suiteName: "t2170.fake.\(UUID().uuidString)"))
        let s = PrintSession(defaults: defaults)
        await s.connect(host: "ipp://localhost:9/ipp/print")
        Swift.print("FAKE nothing-listening | error=\(s.lastError ?? "nil")")
        failed(s, mentioning: "Can't reach the printer")
    }

    /// Prints over a real LAN address, so App Transport Security applies as it will on the iPad.
    @Test(.enabled(if: !lanHosts.isEmpty), arguments: lanHosts.indices)
    func overTheLAN(_ index: Int) async throws {
        let scenario = "lan-\(index)"
        let port = URL(string: fakeBase)?.port ?? 8635
        let document = try writeQuadrantPDF(named: "\(scenario).pdf", pages: [SimScenario.a4])
        let s = try await connectedSession(uri: "ipp://\(lanHosts[index]):\(port)/\(scenario)/ipp/print", document: document)
        sheetA4(&s.settings)
        await s.print()
        let log = try await fakeLog(scenario)
        report("\(scenario) \(lanHosts[index])", s, log)
        succeeded(s)
        #expect(log.jobs.count == 1)
    }

    /// Control for the test above: proves App Transport Security is live in this test host, so a pass
    /// over the LAN means the app's settings allow it. Blocked before any request leaves the device.
    @Test(.enabled(if: !lanHosts.isEmpty))
    func publicHostIsBlocked() async throws {
        let defaults = try #require(UserDefaults(suiteName: "t2170.fake.\(UUID().uuidString)"))
        let s = PrintSession(defaults: defaults)
        await s.connect(host: "ipp://example.com/ipp/print")
        Swift.print("FAKE ats-control | error=\(s.lastError ?? "nil")")
        failed(s, mentioning: "-1022")
    }

    @Test func cancelWhilePrinting() async throws {
        let s = try await session("job-cancel")
        sheetA4(&s.settings)
        let run = Task { await s.print() }
        for _ in 0..<1000 where s.lastJob == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(s.lastJob != nil)
        await s.cancelLastJob()
        await run.value
        let log = try await fakeLog("job-cancel")
        report("job-cancel", s, log)
        #expect(log.filter { $0.op == "Cancel-Job" }.count == 1)
        #expect(!s.isPrinting)
    }

    @Test func printAgainAfterFailure() async throws {
        let s = try await session("retry-after-failure")
        sheetA4(&s.settings)
        await s.print()
        failed(s)
        await s.print()
        succeeded(s)
        #expect(try await fakeLog("retry-after-failure").jobs.count == 2)
    }

    /// The fake holds Validate-Job open for longer than the client waits. Nothing has been sent, so
    /// the print must end with a message and no job.
    @Test func stalledPrinter() async throws {
        let s = try await session("stall-validate")
        sheetA4(&s.settings)
        await s.print()
        let log = try await fakeLog("stall-validate")
        report("stall-validate", s, log)
        failed(s)
        #expect(log.jobs.isEmpty)
    }

    @Test(arguments: [5000, 18000])
    func hugeBanner(lengthMM: Int) async throws {
        let name = "huge-\(lengthMM)"
        // One page of the full length: a banner ends where its content does, so the content must reach it.
        let s = try await session(name, pages: [CGSize(width: 600, height: 600 * (Double(lengthMM) - 6) / 603.6)])
        s.settings.paperSource = .rollPaper
        s.settings.rollWidth = .w24in
        s.settings.outputSize = .banner
        s.settings.bannerLengthMM = Double(lengthMM)
        let memory = PeakMemory()
        let sampler = Task.detached {
            while !Task.isCancelled {
                await memory.sample()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let start = Date()
        await s.print()
        sampler.cancel()
        let log = try await fakeLog(name)
        let peak = await memory.peak
        report(name, s, log)
        let job = try #require(log.jobs.first)
        Swift.print("FAKE \(name) took \(Int(Date().timeIntervalSince(start))) s, peak \(peak >> 20) MB, body \(job.bodyLength >> 20) MB, raster \(String(describing: job.raster))")
        succeeded(s)
        #expect(job.contentLength == job.bodyLength)
        let dpi = Double(job.raster?.dpi ?? 0)
        let expected = Double(lengthMM) / 25.4 * dpi
        #expect(abs(Double(job.raster?.height ?? 0) - expected) < dpi, "height \(String(describing: job.raster?.height)), expected about \(expected)")
    }
}

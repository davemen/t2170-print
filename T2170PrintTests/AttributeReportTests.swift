import Foundation
import Testing
@testable import T2170Print

// The report is how the real printer's replies reach us, so it has to survive anything: odd values,
// a reply cut in half, or a printer that isn't there. The fake and simulator cases are skipped when
// test-sim.sh isn't running them.

private func record(_ tag: UInt8, _ name: String, _ value: [UInt8]) -> [UInt8] {
    let nameBytes = Array(name.utf8)
    return [tag, UInt8(nameBytes.count >> 8), UInt8(nameBytes.count & 0xFF)] + nameBytes
        + [UInt8(value.count >> 8), UInt8(value.count & 0xFF)] + value
}

private func record(_ tag: UInt8, _ name: String, _ value: String) -> [UInt8] {
    record(tag, name, Array(value.utf8))
}

private let header: [UInt8] = [2, 0, 0x04, 0x06, 0, 0, 0, 7]

/// Holds one of each thing the app's own decoder loses.
private let sampleBody: [UInt8] = {
    var bytes = header
    bytes += [0x01]
    bytes += record(0x47, "attributes-charset", "utf-8")
    bytes += record(0x41, "status-message", "partial")
    bytes += [0x04]
    bytes += record(0x44, "media-supported", "iso_a4_210x297mm")
    bytes += record(0x44, "", "roll_max_44x3000in")
    bytes += record(0x42, "", "custom-name")
    bytes += record(0x21, "copies-default", [0, 0, 0, 1])
    bytes += record(0x21, "copies-default", [0, 0, 0, 2])
    bytes += record(0x11, "print-color-mode-default", [UInt8]())
    bytes += record(0x13, "printer-alert", [UInt8]())
    bytes += record(0x35, "printer-info", [0, 2] + Array("fr".utf8) + [0, 3] + Array("abc".utf8))
    bytes += record(0x33, "copies-supported", [0, 0, 0, 9, 0, 0, 0, 1])
    bytes += record(0x32, "printer-resolution-default", [0, 0, 1, 0x68, 0, 0, 2, 0xD0, 3])
    bytes += record(0x21, "too-short", [1, 2])
    bytes += record(0x7E, "made-up", [0xAB])
    bytes += record(0x34, "media-col-default", [UInt8]())
    bytes += record(0x4A, "", "media-size")
    bytes += record(0x34, "", [UInt8]())
    bytes += record(0x4A, "", "x-dimension")
    bytes += record(0x21, "", [0, 0, 0x52, 0x08])
    bytes += record(0x37, "", [UInt8]())
    bytes += record(0x4A, "", "media-type")
    bytes += record(0x44, "", "stationery")
    bytes += record(0x37, "", [UInt8]())
    bytes += [0x03]
    return bytes
}()

private func lines(of dump: IPPWireDump) -> [String] {
    dump.groups.flatMap { $0.attributes.map(\.line) }
}

private func rawResponses(in text: String) -> [Data] {
    let parts = text.components(separatedBy: "--- end raw response ---").dropLast()
    return parts.compactMap { part in
        guard let start = part.range(of: "bytes ---\n", options: .backwards) else { return nil }
        return Data(base64Encoded: String(part[start.upperBound...]), options: .ignoreUnknownCharacters)
    }
}

private func report(_ responses: [IPPRawResponse]) -> IPPAttributeReport {
    IPPAttributeReport(context: .init(appVersion: "1.0 (3)", printerURI: "ipp://p/ipp/print",
                                      endpoint: "http://p:631/ipp/print", discovery: ["txt ty=Test"]),
                       responses: responses)
}

private func response(_ body: [UInt8]) -> IPPRawResponse {
    var result = IPPRawResponse(requested: ["all"], versionSent: "2.0")
    result.body = Data(body)
    result.httpStatus = 200
    result.contentType = "application/ipp"
    return result
}

@Suite("Attribute report wire dump")
struct IPPWireDumpTests {
    @Test func keepsWhatTheDecoderLoses() {
        let dump = IPPWireDump(Data(sampleBody))
        #expect(dump.fault == nil)
        #expect(dump.sawEnd)
        #expect(dump.status == 0x0406)
        #expect(dump.requestID == 7)
        #expect(dump.groups.map(\.tag) == [0x01, 0x04])

        let all = lines(of: dump)
        let expected = [
            "media-supported (1setOf keyword|nameWithoutLanguage) = iso_a4_210x297mm,roll_max_44x3000in,custom-name",
            "copies-default (integer) = 1",
            "copies-default (integer) = 2",
            "print-color-mode-default (default) = default",
            "printer-alert (no-value) = no-value",
            "printer-info (textWithLanguage) = abc [language=fr]",
            "copies-supported (rangeOfInteger) = 9-1",
            "printer-resolution-default (resolution) = 360x720dpi",
            "too-short (integer) = <wrong length 2 hex=0102>",
            "made-up (tag-0x7e) = tag 0x7e hex=ab",
            "media-col-default (collection) = {media-size={x-dimension=21000} media-type=stationery}",
        ]
        for line in expected {
            #expect(all.contains(line), "missing: \(line)")
        }
        let printerGroup = dump.groups[1].attributes.map(\.name)
        #expect(printerGroup.first == "media-supported")
        #expect(printerGroup.last == "media-col-default")
    }

    @Test func everyCutPointKeepsTheBytesAndNeverTraps() {
        for length in 0..<sampleBody.count {
            let cut = Array(sampleBody[..<length])
            let text = report([response(cut)]).text
            if length > 0 {
                #expect(rawResponses(in: text) == [Data(cut)], "cut at \(length)")
            }
            #expect(text.contains("[") , "cut at \(length)")
            if length >= 8 {
                #expect(text.contains("[stopped at byte"), "cut at \(length)")
            }
        }
    }

    @Test func keepsAttributesBeforeAFault() {
        let cut = Array(sampleBody[..<(sampleBody.count - 20)])
        let dump = IPPWireDump(Data(cut))
        #expect(dump.fault != nil)
        #expect(lines(of: dump).contains { $0.hasPrefix("media-supported ") })
    }

    @Test func randomBytesNeverTrap() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            var bytes = sampleBody
            for _ in 0..<8 {
                bytes[Int.random(in: 0..<bytes.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            _ = report([response(bytes)]).text
        }
    }

    @Test func deepCollectionsStopInsteadOfOverflowing() {
        var bytes = header + [0x04]
        bytes += record(0x34, "deep", [UInt8]())
        for _ in 0..<5000 {
            bytes += record(0x4A, "", "m")
            bytes += record(0x34, "", [UInt8]())
        }
        #expect(IPPWireDump(Data(bytes)).fault?.reason.contains("nested") == true)
    }

    @Test func trailingBytesAreCounted() {
        let dump = IPPWireDump(Data(sampleBody + [1, 2, 3]))
        #expect(dump.trailingBytes == 3)
        #expect(report([response(sampleBody + [1, 2, 3])]).text.contains("[3 bytes after end-of-attributes]"))
    }

    @Test func aWebPageIsReportedAsIs() {
        let text = report([response(Array("<html>login</html>".utf8))]).text
        #expect(text.contains("[body is not IPP]"))
        #expect(text.contains("<html>login</html>"))
    }

    @Test func headerAndCountsAreThere() {
        let result = report([response(sampleBody)])
        let text = result.text
        #expect(text.contains("App: 1.0 (3)"))
        #expect(text.contains("Printer URI: ipp://p/ipp/print"))
        #expect(text.contains("  txt ty=Test"))
        #expect(text.contains("status 0x0406, request-id 7"))
        #expect(text.contains("GROUP printer-attributes-tag"))
        #expect(result.attributeCount == 10)
        #expect(rawResponses(in: text) == [Data(sampleBody)])
    }

    @Test func filesAreWrittenForSharing() throws {
        let file = AttributeReportFile(report([response(sampleBody)]))
        let url = try #require(file.fileURL)
        #expect(try String(contentsOf: url, encoding: .utf8) == file.text)
        #expect(file.summary.hasPrefix("10 attributes, "))
    }
}

@Suite("Attribute report against printers", .serialized)
struct AttributeReportCaptureTests {
    private static let env = ProcessInfo.processInfo.environment

    private static func simURIs() -> [String] {
        (env["T2170_SIM"] ?? "").split(separator: ",").compactMap { pair in
            pair.split(separator: "=", maxSplits: 1).last.map(String.init)
        }
    }

    private func capture(_ uri: String) async throws -> [IPPRawResponse] {
        await IPPAttributeReport.capture(from: IPPClient(printerURI: try #require(URL(string: uri))))
    }

    @Test(.enabled(if: env["T2170_SIM"] != nil))
    func realIPPServersReportInFull() async throws {
        for uri in Self.simURIs() {
            let responses = try await capture(uri)
            let result = report(responses)
            #expect(responses.count == 2, "\(uri)")
            #expect(responses.allSatisfy { $0.transportError == nil && $0.httpStatus == 200 })
            #expect(responses.allSatisfy { IPPWireDump($0.body).fault == nil })
            #expect(result.attributeCount > 50, "\(uri)")
            let names = IPPWireDump(responses[0].body).printerAttributeNames
            #expect(names.contains("media-col-database"), "\(uri)")
            #expect(rawResponses(in: result.text) == responses.map(\.body))
            if let dir = Self.env["T2170_REPORT_DIR"], let port = URL(string: uri)?.port {
                try result.text.write(toFile: "\(dir)/report-\(port).txt", atomically: true, encoding: .utf8)
            }
        }
    }

    @Test(.enabled(if: env["T2170_FAKE"] != nil),
          arguments: ["odd-values", "wrong-lengths", "trailing-bytes", "octet-only", "huge-mcd", "empty-mcd"])
    func misbehavingRepliesAreKept(scenario: String) async throws {
        let base = try #require(Self.env["T2170_FAKE"])
        let uri = base.replacingOccurrences(of: "http://", with: "ipp://") + "/\(scenario)"
        let responses = try await capture(uri)
        let result = report(responses)
        #expect(responses.allSatisfy { $0.transportError == nil && !$0.body.isEmpty }, "\(scenario)")
        #expect(result.attributeCount > 0, "\(scenario)")
        #expect(rawResponses(in: result.text) == responses.map(\.body), "\(scenario)")
    }

    @Test func aPrinterThatIsNotThereStillGivesAReport() async throws {
        let responses = try await capture("ipp://127.0.0.1:9/ipp/print")
        #expect(responses.count == 1)
        #expect(responses[0].transportError != nil)
        #expect(report(responses).text.contains("Transport error:"))
    }

    @MainActor
    @Test func aFailedConnectCanStillBeCaptured() async throws {
        let defaults = try #require(UserDefaults(suiteName: "t2170.report.\(UUID().uuidString)"))
        let session = PrintSession(defaults: defaults)
        #expect(!session.canCaptureReport)
        await session.connect(host: "ipp://127.0.0.1:9/ipp/print")
        let error = session.lastError
        #expect(error != nil)
        #expect(session.canCaptureReport)

        await session.captureAttributeReport()
        #expect(session.attributeReport?.text.contains("Transport error:") == true)
        #expect(session.lastError == error)
        #expect(session.capabilities == nil)
        #expect(!session.isCapturingReport)
    }

    @MainActor
    @Test(.enabled(if: env["T2170_SIM"] != nil))
    func captureLeavesAConnectedSessionAlone() async throws {
        let uri = try #require(Self.simURIs().last)
        let defaults = try #require(UserDefaults(suiteName: "t2170.report.\(UUID().uuidString)"))
        let session = PrintSession(defaults: defaults)
        await session.connect(host: uri)
        let name = session.printerName
        #expect(session.capabilities != nil)
        #expect(session.attributeReport == nil)

        await session.captureAttributeReport()
        #expect((session.attributeReport?.attributeCount ?? 0) > 50)
        #expect(session.capabilities != nil)
        #expect(session.printerName == name)
        #expect(session.lastError == nil)

        await session.connect(host: uri)
        #expect(session.attributeReport == nil)
    }
}

import Foundation

/// Error returned by `IPPClient` when an HTTP transport or IPP operation fails.
struct IPPError: Error, LocalizedError, Sendable, Equatable {
    /// HTTP status code if the failure occurred at the HTTP layer.
    var httpStatus: Int?
    /// Raw IPP status code (`>= 0x0400`) when the printer returned an IPP error response.
    var status: UInt16?
    /// Typed IPP status code, if recognized.
    var ippStatus: IPPStatus?
    /// Optional `status-message` returned by the printer or transport description.
    var statusMessage: String?
    /// Names of attributes the printer reported in the unsupported-attributes group (0x05).
    var unsupportedAttributes: [String] = []
    /// For a collection in that group, the member names the printer echoed back: `media-col` -> `media-source`.
    var unsupportedMembers: [String: [String]] = [:]

    init(
        httpStatus: Int? = nil,
        status: UInt16? = nil,
        statusMessage: String? = nil,
        unsupportedAttributes: [String] = [],
        unsupportedMembers: [String: [String]] = [:]
    ) {
        self.httpStatus = httpStatus
        self.status = status
        self.ippStatus = status.flatMap(IPPStatus.init(rawValue:))
        self.statusMessage = statusMessage
        self.unsupportedAttributes = unsupportedAttributes
        self.unsupportedMembers = unsupportedMembers
    }

    init(
        ippStatus: IPPStatus,
        statusMessage: String? = nil,
        unsupportedAttributes: [String] = []
    ) {
        self.httpStatus = nil
        self.status = ippStatus.rawValue
        self.ippStatus = ippStatus
        self.statusMessage = statusMessage
        self.unsupportedAttributes = unsupportedAttributes
    }

    var errorDescription: String? {
        if let status {
            let codeDesc = IPPStatus.description(for: status)
            if let statusMessage, !statusMessage.isEmpty {
                return String(format: "IPP error 0x%04X (%@): %@", status, codeDesc, statusMessage)
            }
            return String(format: "IPP error 0x%04X (%@)", status, codeDesc)
        }
        if let httpStatus {
            if let statusMessage, !statusMessage.isEmpty {
                return "HTTP \(httpStatus): \(statusMessage)"
            }
            return "HTTP \(httpStatus)"
        }
        return statusMessage ?? "Unknown IPP error"
    }
}

/// Representation of an IPP print job returned by job operations.
struct IPPJob: Sendable, Identifiable, Hashable, Codable {
    /// Standard IPP `job-state` enum values (RFC 8011 Section 5.3.7).
    enum JobState: Int32, Sendable, Hashable, Codable, CaseIterable {
        case pending = 3
        case pendingHeld = 4
        case processing = 5
        case processingStopped = 6
        case canceled = 7
        case aborted = 8
        case completed = 9

        /// Human-readable label for the job state.
        var label: String {
            switch self {
            case .pending: "Pending"
            case .pendingHeld: "Pending (Held)"
            case .processing: "Processing"
            case .processingStopped: "Stopped"
            case .canceled: "Canceled"
            case .aborted: "Aborted"
            case .completed: "Completed"
            }
        }
    }

    var id: Int32 { jobID }
    var jobID: Int32
    var jobState: JobState
    var jobStateReasons: [String]
    var jobURI: String?
    var jobName: String?
    /// Names of attributes the printer reported in the unsupported-attributes group (0x05).
    var unsupportedAttributes: [String] = []

    /// Alias for `jobState`.
    var state: JobState { jobState }
    /// Alias for `jobStateReasons`.
    var stateReasons: [String] { jobStateReasons }

    init(
        jobID: Int32,
        jobState: JobState = .pending,
        jobStateReasons: [String] = [],
        jobURI: String? = nil,
        jobName: String? = nil,
        unsupportedAttributes: [String] = []
    ) {
        self.unsupportedAttributes = unsupportedAttributes
        self.jobID = jobID
        self.jobState = jobState
        self.jobStateReasons = jobStateReasons
        self.jobURI = jobURI
        self.jobName = jobName
    }

    /// Initializes an `IPPJob` from a list of IPP job attributes.
    init(attributes: [IPPAttribute], fallbackJobID: Int32 = 0) {
        func find(_ name: String) -> IPPAttribute? {
            attributes.first { $0.name == name }
        }
        let id = find("job-id")?.int32Value ?? fallbackJobID
        let rawState = find("job-state")?.int32Value ?? JobState.pending.rawValue
        let state = JobState(rawValue: rawState) ?? .pending
        let reasons = find("job-state-reasons")?.keywords ?? []
        let uri = find("job-uri")?.stringValue
        let name = find("job-name")?.stringValue

        self.init(
            jobID: id,
            jobState: state,
            jobStateReasons: reasons,
            jobURI: uri,
            jobName: name
        )
    }
}

/// One Get-Printer-Attributes exchange exactly as it happened, for the diagnostic report.
struct IPPRawResponse: Sendable {
    /// The `requested-attributes` sent; nil for a plain request.
    var requested: [String]?
    var versionSent: String
    var body = Data()
    var httpStatus: Int?
    var contentType: String?
    var transportError: String?
    var elapsed: TimeInterval = 0

    /// Bytes 2-3 of an IPP response, when the body is long enough to have them.
    var ippStatus: UInt16? {
        guard body.count >= 4 else { return nil }
        let start = body.startIndex
        return UInt16(body[start + 2]) << 8 | UInt16(body[start + 3])
    }
}

/// Asynchronous IPP/1.1 & IPP/2.0 client over HTTP/HTTPS (RFC 8010/8011).
actor IPPClient {
    /// Canonical `ipp://` or `ipps://` URI sent in the `printer-uri` attribute.
    let printerURI: URL
    /// Normalized `http://` or `https://` endpoint used by `URLSession`.
    let endpointURL: URL

    private let session: URLSession
    /// The endpoint that last answered. Starts as `endpointURL`; moves to HTTPS when the printer
    /// demands TLS (HTTP 426), which Epson printers do on their plain `ipp://` port.
    private var activeEndpoint: URL
    private var nextRequestID: UInt32 = 1
    private var version: (UInt8, UInt8) = (2, 0)

    /// Creates an IPP client for the given printer URI.
    ///
    /// Converts `ipp://` and `ipps://` schemes to `http://` and `https://`,
    /// defaulting to port `631` and path `/ipp/print` when omitted.
    init(printerURI: URL, session: URLSession? = nil) {
        let (canonicalIPP, httpEndpoint) = Self.normalizeURIs(from: printerURI)
        self.session = session ?? Self.makeSession(trustedHost: httpEndpoint.host())
        self.printerURI = canonicalIPP
        self.endpointURL = httpEndpoint
        self.activeEndpoint = httpEndpoint
    }

    /// The endpoint requests are going to now (differs from `endpointURL` after a TLS fallback).
    var currentEndpoint: URL { activeEndpoint }

    /// A printer's TLS certificate is self-signed, so a session that talks to one has to accept it,
    /// for that one host only.
    private static func makeSession(trustedHost: String?) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: PrinterTrustDelegate(host: trustedHost), delegateQueue: nil)
    }

    private final class PrinterTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
        let host: String?
        init(host: String?) { self.host = host }
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let space = challenge.protectionSpace
            if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = space.serverTrust, let host, space.host == host {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    /// The same endpoint over HTTPS on this port, then on 443.
    private func tlsCandidates() -> [URL] {
        guard var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) else { return [] }
        components.scheme = "https"
        var urls: [URL] = []
        if let url = components.url { urls.append(url) }
        if components.port != 443 {
            components.port = 443
            if let url = components.url { urls.append(url) }
        }
        return urls
    }

    /// `ipps://` form of an HTTPS endpoint, for the `printer-uri` attribute.
    private var activePrinterURI: URL {
        guard activeEndpoint.scheme == "https",
              var components = URLComponents(url: activeEndpoint, resolvingAgainstBaseURL: false) else { return printerURI }
        components.scheme = "ipps"
        return components.url ?? printerURI
    }

    /// Normalizes a printer URI into its canonical IPP URI and HTTP(S) transport URL.
    static func normalizeURIs(from rawURI: URL) -> (ippURI: URL, httpURL: URL) {
        guard var components = URLComponents(url: rawURI, resolvingAgainstBaseURL: false) else {
            return (rawURI, rawURI)
        }

        let lowerScheme = (components.scheme ?? "ipp").lowercased()
        let isSecure = (lowerScheme == "ipps" || lowerScheme == "https")

        if components.port == nil {
            components.port = 631
        }
        if components.path.isEmpty || components.path == "/" {
            components.path = "/ipp/print"
        }

        var ippComponents = components
        ippComponents.scheme = isSecure ? "ipps" : "ipp"

        var httpComponents = components
        httpComponents.scheme = isSecure ? "https" : "http"

        let ippURL = ippComponents.url ?? rawURI
        let httpURL = httpComponents.url ?? rawURI
        return (ippURL, httpURL)
    }

    private func allocateRequestID() -> UInt32 {
        let current = nextRequestID
        nextRequestID = nextRequestID == .max ? 1 : nextRequestID + 1
        return current
    }

    private func standardOperationAttributes(extra: [IPPAttribute] = []) -> [IPPAttribute] {
        var attributes: [IPPAttribute] = [
            .charset("attributes-charset", "utf-8"),
            .naturalLanguage("attributes-natural-language", "en"),
            .uri("printer-uri", activePrinterURI.absoluteString),
            .name("requesting-user-name", "iPad")
        ]
        attributes.append(contentsOf: extra)
        return attributes
    }

    // MARK: - Transport

    /// Sends an `IPPMessage` over HTTP(S) POST and decodes the response `IPPMessage`.
    /// With `documentFile`, the file's bytes follow the encoded message and are streamed from disk.
    func send(_ message: IPPMessage, documentFile: URL? = nil) async throws -> IPPMessage {
        var decoded = try await sendOnce(message, documentFile: documentFile)
        if decoded.operationOrStatus == IPPStatus.serverErrorVersionNotSupported.rawValue,
           version != (1, 1) {
            version = (1, 1)
            decoded = try await sendOnce(message, documentFile: documentFile)
        }
        if decoded.operationOrStatus >= 0x0400 {
            throw IPPError(
                httpStatus: nil,
                status: decoded.operationOrStatus,
                statusMessage: decoded.statusMessage,
                unsupportedAttributes: Self.unsupportedNames(in: decoded),
                unsupportedMembers: Self.unsupportedMembers(in: decoded)
            )
        }
        return decoded
    }

    private func sendOnce(_ message: IPPMessage, documentFile: URL?) async throws -> IPPMessage {
        let (responseData, urlResponse) = try await exchange(message, documentFile: documentFile)

        if let httpResponse = urlResponse as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw IPPError(
                httpStatus: httpResponse.statusCode,
                status: nil,
                statusMessage: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
        }

        if let httpResponse = urlResponse as? HTTPURLResponse {
            let contentType = (httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "")
                .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            if contentType != "application/ipp" {
                let snippet = String(data: responseData.prefix(200), encoding: .utf8) ?? ""
                var detail = "Unexpected Content-Type \"\(contentType.isEmpty ? "(none)" : contentType)\" in printer response"
                if !snippet.isEmpty { detail += ": \(snippet)" }
                throw IPPError(httpStatus: httpResponse.statusCode, status: nil, statusMessage: detail)
            }
        }

        return try IPPMessage.decode(responseData)
    }

    /// One HTTP round trip. If a plain-HTTP printer answers 426 (Upgrade Required) or an empty 500,
    /// URLSession cannot do the RFC 2817 upgrade, so the same request is retried straight over TLS;
    /// whichever endpoint answers properly is kept for later requests.
    private func exchange(_ message: IPPMessage, documentFile: URL?) async throws -> (Data, URLResponse) {
        var outgoing = message
        outgoing.version = version
        outgoing.requestID = allocateRequestID()

        let header = try outgoing.encode()
        let timeout: TimeInterval = outgoing.operationOrStatus == IPPOperation.printJob.rawValue ? 600 : 60
        let bodyFile = try documentFile.map { try Self.requestBodyFile(header: header, documentFile: $0) }
        defer { if let bodyFile { try? FileManager.default.removeItem(at: bodyFile) } }

        func attempt(_ url: URL) async throws -> (Data, URLResponse) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/ipp", forHTTPHeaderField: "Content-Type")
            request.setValue("application/ipp", forHTTPHeaderField: "Accept")
            // An idle timeout, not a total one. A printer slows its reads to the speed of the print head,
            // so Print-Job gets a long allowance.
            request.timeoutInterval = timeout
            if let bodyFile {
                return try await session.upload(for: request, fromFile: bodyFile)
            }
            request.httpBody = header
            return try await session.data(for: request)
        }

        let first = try await attempt(activeEndpoint)
        guard activeEndpoint.scheme == "http", let http = first.1 as? HTTPURLResponse,
              http.statusCode == 426 || (http.statusCode == 500 && first.0.isEmpty) else { return first }

        for url in tlsCandidates() {
            if let retry = try? await attempt(url), let retryHTTP = retry.1 as? HTTPURLResponse,
               retryHTTP.statusCode != 426, retryHTTP.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/ipp") == true {
                activeEndpoint = url
                return retry
            }
        }
        return first
    }

    /// Writes the IPP header followed by the document to a temporary file, 1 MB at a time, so a
    /// multi-gigabyte raster never has to sit in memory.
    private static func requestBodyFile(header: Data, documentFile: URL) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipp-\(UUID().uuidString).body")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            let input = try FileHandle(forReadingFrom: documentFile)
            defer { try? input.close() }
            try output.write(contentsOf: header)
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    // MARK: - High-Level Operations

    /// Queries the printer's capabilities and state via `Get-Printer-Attributes` (`0x000B`).
    func getPrinterAttributes(requested: [String]? = nil) async throws -> [IPPAttribute] {
        var extra: [IPPAttribute] = []
        if let requested, !requested.isEmpty {
            extra.append(.keywords("requested-attributes", requested))
        }
        let message = IPPMessage(
            operation: .getPrinterAttributes,
            groups: [(.operationAttributes, standardOperationAttributes(extra: extra))]
        )
        let response = try await send(message)
        let printerAttrs = response.attributes(in: .printerAttributes)
        return printerAttrs.isEmpty ? response.allAttributes : printerAttrs
    }

    /// Get-Printer-Attributes for the diagnostic report. Returns exactly what came back and never
    /// throws: a refusal, an HTML error page or a dropped connection is the finding, not a failure.
    func rawPrinterAttributes(requested: [String]? = nil) async -> IPPRawResponse {
        var extra: [IPPAttribute] = []
        if let requested, !requested.isEmpty {
            extra.append(.keywords("requested-attributes", requested))
        }
        let message = IPPMessage(operation: .getPrinterAttributes,
                                 groups: [(.operationAttributes, standardOperationAttributes(extra: extra))])
        let started = Date()
        var result = await rawExchange(message, requested: requested)
        if result.ippStatus == IPPStatus.serverErrorVersionNotSupported.rawValue, version != (1, 1) {
            version = (1, 1)
            result = await rawExchange(message, requested: requested)
        }
        result.elapsed = Date().timeIntervalSince(started)
        return result
    }

    private func rawExchange(_ message: IPPMessage, requested: [String]?) async -> IPPRawResponse {
        var result = IPPRawResponse(requested: requested, versionSent: "\(version.0).\(version.1)")
        do {
            let (body, response) = try await exchange(message, documentFile: nil)
            result.body = body
            if let http = response as? HTTPURLResponse {
                result.httpStatus = http.statusCode
                result.contentType = http.value(forHTTPHeaderField: "Content-Type")
            }
        } catch {
            result.transportError = String(describing: error)
        }
        return result
    }

    /// Validates a set of job attributes with the printer via `Validate-Job` (`0x0004`).
    @discardableResult
    func validateJob(format: String, attributes: [IPPAttribute]) async throws -> [String] {
        let operationNames: Set<String> = [
            "attributes-charset",
            "attributes-natural-language",
            "printer-uri",
            "requesting-user-name",
            "job-name",
            "document-format",
            "ipp-attribute-fidelity"
        ]
        var extraOp = attributes.filter { operationNames.contains($0.name) && $0.name != "document-format" }
        extraOp.append(.mimeType("document-format", format))
        let jobAttrs = attributes.filter { !operationNames.contains($0.name) }

        var groups: [(tag: IPPTag, attributes: [IPPAttribute])] = [
            (.operationAttributes, standardOperationAttributes(extra: extraOp))
        ]
        if !jobAttrs.isEmpty {
            groups.append((.jobAttributes, jobAttrs))
        }

        let message = IPPMessage(operation: .validateJob, groups: groups)
        let response = try await send(message)
        return Self.unsupportedNames(in: response)
    }

    /// Members the printer named inside each collection of the unsupported-attributes group (delimiter tag 0x05).
    private static func unsupportedMembers(in response: IPPMessage) -> [String: [String]] {
        var members: [String: [String]] = [:]
        for attribute in response.attributes(in: .unsupportedAttributes) where !attribute.name.isEmpty {
            let names = attribute.collections.flatMap { $0.members.map(\.name) }.filter { !$0.isEmpty }
            if !names.isEmpty { members[attribute.name, default: []] += names }
        }
        return members
    }

    private static func unsupportedNames(in response: IPPMessage) -> [String] {
        response.attributes(in: .unsupportedAttributes).map(\.name).filter { !$0.isEmpty }
    }

    /// Submits a print job via `Print-Job` (`0x0002`) and returns the resulting `IPPJob`.
    func printJob(
        documentFile: URL,
        format: String,
        jobName: String,
        attributes: [IPPAttribute]
    ) async throws -> IPPJob {
        let extraOp: [IPPAttribute] = [
            .name("job-name", jobName),
            .mimeType("document-format", format)
        ]
        let filteredJobAttrs = attributes.filter {
            $0.name != "job-name" && $0.name != "document-format"
        }

        var groups: [(tag: IPPTag, attributes: [IPPAttribute])] = [
            (.operationAttributes, standardOperationAttributes(extra: extraOp))
        ]
        if !filteredJobAttrs.isEmpty {
            groups.append((.jobAttributes, filteredJobAttrs))
        }

        let message = IPPMessage(operation: .printJob, groups: groups)
        let response = try await send(message, documentFile: documentFile)
        let jobAttrs = response.attributes(in: .jobAttributes)
        guard let jobIDAttr = jobAttrs.first(where: { $0.name == "job-id" }),
              jobIDAttr.int32Value != nil else {
            throw IPPError(
                status: nil,
                statusMessage: "Printer accepted Print-Job (status 0x\(String(response.operationOrStatus, radix: 16))) but returned no job-id."
            )
        }
        var job = IPPJob(attributes: jobAttrs)
        job.unsupportedAttributes = Self.unsupportedNames(in: response)
        return job
    }

    /// Queries the status of a specific job via `Get-Job-Attributes` (`0x0009`).
    func getJobAttributes(jobID: Int32) async throws -> IPPJob {
        let extra: [IPPAttribute] = [
            .integer("job-id", jobID)
        ]
        let message = IPPMessage(
            operation: .getJobAttributes,
            groups: [(.operationAttributes, standardOperationAttributes(extra: extra))]
        )
        let response = try await send(message)
        let jobAttrs = response.attributes(in: .jobAttributes)
        return IPPJob(
            attributes: jobAttrs.isEmpty ? response.allAttributes : jobAttrs,
            fallbackJobID: jobID
        )
    }

    /// Lists jobs on the printer via `Get-Jobs` (`0x000A`).
    func getJobs(whichJobs: String = "not-completed") async throws -> [IPPJob] {
        let extra: [IPPAttribute] = [
            .keyword("which-jobs", whichJobs),
            .keywords(
                "requested-attributes",
                ["job-id", "job-uri", "job-name", "job-state", "job-state-reasons"]
            )
        ]
        let message = IPPMessage(
            operation: .getJobs,
            groups: [(.operationAttributes, standardOperationAttributes(extra: extra))]
        )
        let response = try await send(message)
        return response.groups
            .filter { $0.tag == .jobAttributes }
            .map { IPPJob(attributes: $0.attributes) }
    }

    /// Cancels an active job via `Cancel-Job` (`0x0008`).
    func cancelJob(jobID: Int32) async throws {
        let extra: [IPPAttribute] = [
            .integer("job-id", jobID)
        ]
        let message = IPPMessage(
            operation: .cancelJob,
            groups: [(.operationAttributes, standardOperationAttributes(extra: extra))]
        )
        _ = try await send(message)
    }

    /// Triggers printer identification (beep/flash panel) via `Identify-Printer` (`0x003C`).
    func identify() async throws {
        let message = IPPMessage(
            operation: .identifyPrinter,
            groups: [(.operationAttributes, standardOperationAttributes())]
        )
        _ = try await send(message)
    }
}

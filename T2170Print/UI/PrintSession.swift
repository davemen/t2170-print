import CoreGraphics
import Foundation
import Observation
import UIKit

/// Single ink cartridge reading reported by the printer.
struct InkLevel: Identifiable, Hashable, Codable, Sendable {
    var name: String
    var color: String?
    var percent: Int

    var id: String { name }
}

/// Observable facade connecting the settings UI to printer discovery, IPP attributes,
/// document loading, preview rasterisation, and print submission.
/// A finished report: its text for the clipboard and a file for Mail and the share sheet, which cope
/// with a large capture better than a pasted body does.
struct AttributeReportFile {
    let text: String
    let attributeCount: Int
    /// Nil if the file couldn't be written; sharing then falls back to the text.
    let fileURL: URL?

    init(_ report: IPPAttributeReport) {
        let text = report.text
        self.text = text
        attributeCount = report.attributeCount
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("T2170-printer-attributes.txt")
        fileURL = (try? Data(text.utf8).write(to: url, options: .atomic)) == nil ? nil : url
    }

    var summary: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file)
        return "\(attributeCount) attributes, \(size)"
    }
}

@MainActor
@Observable
final class PrintSession {
    static let settingsDefaultsKey = "settings"
    static let presetsDefaultsKey = "presets"
    static let sendFormatDefaultsKey = "sendFormat"

    var settings = PrintSettings()
    var presets: [SettingsPreset] = []
    var selectedPreset: SettingsPreset.ID?
    var printerName: String?
    var printerStatusText: String = "Not connected"
    var inkLevels: [InkLevel] = []
    var printerSupportedMediaTypes: [String] = []
    var printerSupportedSources: [String] = []
    /// Everything the printer reported, for the Printer pane and for sending to someone diagnosing it.
    var printerAttributes: [String: [String]] = [:]
    /// The latest full capture, ready to copy or share. Only Capture Printer Details fills this, so the
    /// extra requests never run alongside a connect or a print.
    var attributeReport: AttributeReportFile?
    var isCapturingReport = false
    /// A failed connect keeps its client, so the report can still record what the printer answered.
    var canCaptureReport: Bool { client != nil }

    var printerAttributesText: String {
        printerAttributes.keys.sorted()
            .map { "\($0): \((printerAttributes[$0] ?? []).joined(separator: ", "))" }
            .joined(separator: "\n")
    }
    var previewImages: [UIImage] = []
    var documentName: String?
    var pageCount: Int = 0
    var isPrinting: Bool = false
    var lastError: String?

    /// Capabilities parsed from the last Get-Printer-Attributes; nil until connected.
    var capabilities: PrinterCapabilities?
    /// Last submitted job, updated while polling.
    var lastJob: IPPJob?
    /// Attributes the builder dropped because the printer does not advertise them.
    var unsupportedAttributes: [String] = []
    /// The printer wouldn't take the roll job's size, so the job went without media-col and the size
    /// came from the raster page header alone. The paper source wasn't named either.
    var paperSizeLeftToPrinter = false
    /// "Send as" preference from the Printer pane.
    var sendFormat: SendFormatChoice = .automatic {
        didSet { defaults.set(sendFormat.rawValue, forKey: Self.sendFormatDefaultsKey) }
    }
    /// What the last job actually went out as, for the Last job section.
    var lastSentFormat: String?
    /// Bonjour discovery; start/stop from the Printer pane.
    let discovery = PrinterDiscovery()

    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private var client: IPPClient?
    private var discoveryLines: [String] = []
    @ObservationIgnored
    private var pageSource: PageSource?
    @ObservationIgnored
    private var documentURL: URL?
    @ObservationIgnored
    private var previewTask: Task<Void, Never>?
    @ObservationIgnored
    private var previewGeneration = 0
    @ObservationIgnored
    private var loadGeneration = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.settingsDefaultsKey),
           let decoded = try? JSONDecoder().decode(PrintSettings.self, from: data) {
            self.settings = decoded
        }
        if let data = defaults.data(forKey: Self.presetsDefaultsKey),
           let decoded = try? JSONDecoder().decode([SettingsPreset].self, from: data) {
            self.presets = decoded
        }
        if let raw = defaults.string(forKey: Self.sendFormatDefaultsKey),
           let choice = SendFormatChoice(rawValue: raw) {
            self.sendFormat = choice
        }
    }

    /// Choices for the "Send as" picker, limited to what the connected printer can take.
    var availableSendFormats: [SendFormatChoice] {
        OutputFormatSelector.availableChoices(capabilities: capabilities)
    }

    func save() {
        let encoder = JSONEncoder()
        if let settingsData = try? encoder.encode(settings) {
            defaults.set(settingsData, forKey: Self.settingsDefaultsKey)
        }
        if let presetsData = try? encoder.encode(presets) {
            defaults.set(presetsData, forKey: Self.presetsDefaultsKey)
        }
    }

    // MARK: - Presets

    @discardableResult
    func savePreset(name: String) -> SettingsPreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = SettingsPreset(
            name: trimmed.isEmpty ? "Preset \(presets.count + 1)" : trimmed,
            settings: settings
        )
        presets.append(preset)
        selectedPreset = preset.id
        save()
        return preset
    }

    func renamePreset(id: SettingsPreset.ID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index].name = trimmed
        save()
    }

    func deletePreset(id: SettingsPreset.ID) {
        presets.removeAll { $0.id == id }
        if selectedPreset == id {
            selectedPreset = nil
        }
        save()
    }

    func applyPreset(_ preset: SettingsPreset) {
        settings = preset.settings
        selectedPreset = preset.id
        save()
    }

    func applyPreset(id: SettingsPreset.ID) {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        applyPreset(preset)
    }

    // MARK: - Printer

    /// Connects to a printer by host name / IP (port 631, `/ipp/print`) or full `ipp://` URI.
    func connect(host: String) async {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let uri: URL
        if trimmed.contains("://"), let url = URL(string: trimmed) {
            uri = url
        } else {
            // "host", "host:631", "[fe80::1]:631" or a bare IPv6 literal (no port).
            var hostPart = trimmed
            var port = 631
            if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
                hostPart = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
                let rest = trimmed[trimmed.index(after: close)...]
                if rest.hasPrefix(":"), let p = Int(rest.dropFirst()) { port = p }
            } else if trimmed.filter({ $0 == ":" }).count == 1 {
                let parts = trimmed.split(separator: ":", maxSplits: 1)
                hostPart = String(parts[0])
                if parts.count == 2, let p = Int(parts[1]) { port = p }
            }
            guard !hostPart.isEmpty, (1...65535).contains(port) else {
                lastError = "Enter a printer address like 192.168.1.20 or 192.168.1.20:631."
                return
            }
            uri = discovery.manual(host: hostPart, port: port).uri
        }
        await connect(uri: uri, displayName: nil)
    }

    /// Connects to a printer found by Bonjour.
    func connect(to printer: DiscoveredPrinter) async {
        await connect(uri: printer.uri, displayName: printer.name, discovery: Self.discoveryLines(for: printer))
    }

    private static func discoveryLines(for printer: DiscoveredPrinter) -> [String] {
        ["name: \(printer.name)", "host: \(printer.host)", "port: \(printer.port)", "tls: \(printer.isTLS)",
         "resource path: \(printer.resourcePath)"]
            + printer.txt.keys.sorted().map { "txt \($0)=\(printer.txt[$0] ?? "")" }
    }

    private func connect(uri: URL, displayName: String?, discovery: [String] = []) async {
        lastError = nil
        attributeReport = nil
        discoveryLines = discovery
        printerStatusText = "Connecting…"
        let newClient = IPPClient(printerURI: uri)
        client = newClient
        do {
            let attrs = try await Self.fetchAttributes(from: newClient)
            let caps = PrinterCapabilities(attributes: attrs)
            capabilities = caps
            let name = caps.makeAndModel.isEmpty ? caps.printerName : caps.makeAndModel
            printerName = name.isEmpty ? (displayName ?? uri.host() ?? uri.absoluteString) : name
            applyCapabilities(caps)
        } catch {
            capabilities = nil
            printerName = nil
            printerStatusText = "Connection failed: \(displayName ?? uri.host() ?? uri.absoluteString)"
            lastError = PrintErrorText.message(for: error)
        }
    }

    /// Re-queries Get-Printer-Attributes: ink levels, media lists, vendor attributes, state.
    func acquirePrinterInfo() async {
        guard let client else {
            lastError = "Connect to a printer first."
            return
        }
        do {
            let attrs = try await Self.fetchAttributes(from: client)
            let caps = PrinterCapabilities(attributes: attrs)
            capabilities = caps
            applyCapabilities(caps)
        } catch {
            lastError = PrintErrorText.message(for: error)
        }
    }

    /// Records everything the printer will say about itself. Diagnostics only: it leaves `capabilities`
    /// and `lastError` alone, because its failures are part of what it reports.
    func captureAttributeReport() async {
        guard let client, !isCapturingReport else { return }
        isCapturingReport = true
        defer { isCapturingReport = false }
        let responses = await IPPAttributeReport.capture(from: client)
        guard client === self.client else { return }

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let report = IPPAttributeReport(
            context: .init(appVersion: "\(version) (\(build))", printerURI: client.printerURI.absoluteString,
                           endpoint: client.endpointURL.absoluteString, discovery: discoveryLines),
            responses: responses)
        attributeReport = AttributeReportFile(report)
    }

    /// Asks for the full attribute list by name. A printer that refuses the list with a client error
    /// gets a plain request instead.
    private static func fetchAttributes(from client: IPPClient) async throws -> [IPPAttribute] {
        do {
            return try await client.getPrinterAttributes(requested: PrinterCapabilities.requestedAttributes)
        } catch let error as IPPError where (error.status ?? 0) & 0xFF00 == 0x0400 {
            return try await client.getPrinterAttributes()
        }
    }

    private func applyCapabilities(_ caps: PrinterCapabilities) {
        if !OutputFormatSelector.availableChoices(capabilities: caps).contains(sendFormat) {
            sendFormat = .automatic
        }
        inkLevels = zip(caps.markerNames, caps.markerLevels).enumerated().map { index, pair in
            InkLevel(
                name: pair.0,
                color: index < caps.markerColors.count ? caps.markerColors[index] : nil,
                percent: max(0, min(100, pair.1))
            )
        }
        printerSupportedMediaTypes = caps.mediaTypeSupported
        printerSupportedSources = caps.mediaSourceSupported
        printerAttributes = caps.rawDump
        printerStatusText = Self.statusText(state: caps.state, reasons: caps.stateReasons, message: caps.stateMessage)
    }

    private static func statusText(state: Int, reasons: [String], message: String?) -> String {
        let base: String
        switch state {
        case 3: base = "Idle"
        case 4: base = "Printing"
        case 5: base = "Stopped"
        default: base = "State \(state)"
        }
        let interesting = reasons.filter { $0 != "none" }
        if interesting.isEmpty {
            return message.map { $0.isEmpty ? base : "\(base) – \($0)" } ?? base
        }
        return "\(base) – \(interesting.joined(separator: ", "))"
    }

    // MARK: - Printing

    /// Everything one print run needs, fixed when the user presses Print.
    private struct PrintRun {
        let client: IPPClient
        let capabilities: PrinterCapabilities
        let source: PageSource
        let settings: PrintSettings
        let choice: SendFormatChoice
        let quality: Int
        /// Formats still worth trying. A format refused on one job is not tried again on the next.
        var candidates: [PrintPayload]
    }

    private enum JobOutcome {
        case completed
        case failed
        case lostContact
        case stillPrinting
    }

    private enum ValidateResult {
        case proceed
        case tryNextFormat
    }

    private enum SendResult {
        case sent(IPPJob)
        case tryNextFormat
    }

    private static func batchSummary(finished: Int, total: Int) -> String {
        "\(finished) of \(total) jobs had finished; no further jobs were sent."
    }

    /// Renders the current settings in a format the printer lists and submits them with Print-Job,
    /// one job per media size, polling each job to a terminal state before starting the next.
    func print() async {
        guard !isPrinting else { return }
        guard let client, let caps = capabilities else {
            lastError = "Connect to a printer first."
            return
        }
        guard let source = pageSource else {
            lastError = "Open a document first."
            return
        }

        isPrinting = true
        lastError = nil
        lastJob = nil
        lastSentFormat = nil
        unsupportedAttributes = []
        paperSizeLeftToPrinter = false
        // Auto-lock would suspend the app and cut a long upload in half.
        let idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        // The job's own claim on the file, so nothing that happens to the session can pull it away mid-render.
        let scopedDocument = documentURL
        let hasDocumentAccess = scopedDocument?.startAccessingSecurityScopedResource() == true
        defer {
            if hasDocumentAccess { scopedDocument?.stopAccessingSecurityScopedResource() }
            UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
            isPrinting = false
        }

        let snapshot = settings
        let jobName = documentName ?? "T2170 Print"
        var finishedJobs = 0
        var totalJobs = 0
        do {
            let plans = Imposer.plan(settings: snapshot, pageSizes: source.pageSizes)
            guard !plans.isEmpty else {
                lastError = "Nothing to print with the current page selection."
                return
            }
            let quality = JobAttributesBuilder.printQuality(for: snapshot)
            let candidates = OutputFormatSelector.candidates(
                capabilities: caps,
                choice: sendFormat,
                printQuality: quality,
                colorMode: snapshot.printMode.ippPrintColorMode)
            guard !candidates.isEmpty else {
                throw OutputFormatError.noUsableFormat(choice: sendFormat, printerFormats: caps.documentFormatSupported)
            }
            var run = PrintRun(
                client: client, capabilities: caps, source: source, settings: snapshot,
                choice: sendFormat, quality: quality, candidates: candidates)

            let batches = PrintBatch.make(plans: plans, settings: snapshot)
            if let refusal = PrintReadiness.widthRefusal(plans: plans, settings: snapshot) {
                throw refusal
            }
            printerStatusText = "Checking printer…"
            try await checkReadiness(client: client, settings: snapshot)
            totalJobs = batches.count
            for (index, batch) in batches.enumerated() {
                let name = batches.count > 1 ? "\(jobName) (\(index + 1) of \(batches.count))" : jobName
                let job = try await submit(batch, jobName: name, run: &run)
                let outcome = try await pollToEnd(job, client: client)
                guard case .completed = outcome else {
                    if batches.count > 1 {
                        let stopped = Self.batchSummary(finished: index, total: batches.count)
                        lastError = lastError.map { "\($0) \(stopped)" } ?? stopped
                    }
                    return
                }
                finishedJobs = index + 1
            }
        } catch {
            printerStatusText = "Print failed"
            var message = PrintErrorText.message(for: error)
            if totalJobs > 1 {
                message += " " + Self.batchSummary(finished: finishedJobs, total: totalJobs)
            }
            lastError = message
        }
    }

    /// Takes a fresh look at the printer, since the state from Connect may be hours old.
    private func checkReadiness(client: IPPClient, settings: PrintSettings) async throws {
        let fresh: PrinterCapabilities
        do {
            fresh = PrinterCapabilities(attributes: try await Self.fetchAttributes(from: client))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            throw error
        } catch {
            // It answered, just not usefully. That is no reason to stop; Print-Job gets the real answer.
            return
        }
        if let refusal = PrintReadiness.refusal(settings: settings, capabilities: fresh) {
            throw refusal
        }
    }

    /// Sends one batch, moving down the candidate formats if the printer refuses one outright.
    private func submit(_ batch: PrintBatch, jobName: String, run: inout PrintRun) async throws -> IPPJob {
        while true {
            guard let payload = run.candidates.first else {
                throw OutputFormatError.noUsableFormat(
                    choice: run.choice, printerFormats: run.capabilities.documentFormatSupported)
            }
            let canFallBack = run.candidates.count > 1

            let built = JobAttributesBuilder.attributes(
                for: run.settings,
                capabilities: run.capabilities,
                documentFormat: payload.mimeType,
                sheetSizeMM: batch.mediaMM)
            var attributes = built.attributes
            noteUnsupported(built.unsupported)

            printerStatusText = "Validating…"
            let validated = try await validate(
                format: payload.mimeType, attributes: &attributes, client: run.client, canFallBack: canFallBack)
            if case .tryNextFormat = validated {
                run.candidates.removeFirst()
                continue
            }

            if case .raster = payload.kind {
                let bytes = PrintReadiness.rasterBytes(
                    plans: batch.plans, settings: run.settings, dpi: payload.dpi, gray: payload.gray)
                if let refusal = PrintReadiness.diskRefusal(
                    rasterBytes: bytes, available: PrintReadiness.availableDiskBytes()) {
                    throw refusal
                }
            }

            printerStatusText = "Rendering…"
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("t2170-\(UUID().uuidString).print")
            defer { try? FileManager.default.removeItem(at: file) }
            switch payload.kind {
            case .pdf:
                try await SheetComposer.composePDF(
                    plans: batch.plans, source: run.source, settings: run.settings,
                    dpi: CGFloat(payload.dpi), to: file)
            case .raster(let format):
                try await SheetComposer.composeRaster(
                    plans: batch.plans, source: run.source, settings: run.settings,
                    format: format, dpi: payload.dpi, gray: payload.gray, quality: run.quality, to: file)
            }

            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            printerStatusText = "Sending \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))…"
            var sizeIsInPageHeader = false
            if case .raster = payload.kind { sizeIsInPageHeader = run.settings.paperSource == .rollPaper }
            let sent = try await send(
                file: file, format: payload.mimeType, jobName: jobName,
                attributes: attributes, client: run.client, canFallBack: canFallBack,
                sizeIsInPageHeader: sizeIsInPageHeader)
            switch sent {
            case .tryNextFormat:
                run.candidates.removeFirst()
            case .sent(let job):
                lastJob = job
                lastSentFormat = payload.summary
                noteUnsupported(job.unsupportedAttributes)
                return job
            }
        }
    }

    /// Validate-Job is advice, not a gate: printers differ in how well they implement it, so only a
    /// network failure or a definite verdict on the format changes what happens next. Print-Job decides.
    private func validate(
        format: String,
        attributes: inout [IPPAttribute],
        client: IPPClient,
        canFallBack: Bool
    ) async throws -> ValidateResult {
        for attempt in 0..<2 {
            do {
                noteUnsupported(try await client.validateJob(format: format, attributes: attributes))
                return .proceed
            } catch let error as IPPError {
                if Self.refusesFormat(error) {
                    return canFallBack ? .tryNextFormat : .proceed
                }
                guard error.status == IPPStatus.clientErrorAttributesOrValuesNotSupported.rawValue,
                      !error.unsupportedAttributes.isEmpty, !error.refusesMediaSize, attempt == 0
                else { return .proceed }
                dropAttributes(rejectedBy: error, from: &attributes)
            }
        }
        return .proceed
    }

    /// Print-Job with the recoveries that cannot print twice: every case here is a refusal before
    /// the printer accepted the job. Once a job id exists nothing is resent.
    ///
    /// `sizeIsInPageHeader` is the last resort for roll jobs in a raster format. A roll job's length is
    /// custom, and a printer that only lists fixed sizes refuses it, yet each raster page states its own
    /// exact size, so media-col can go. Sheet jobs and PDF never do this: without media-col they could
    /// land on whatever paper is loaded.
    private func send(
        file: URL,
        format: String,
        jobName: String,
        attributes: [IPPAttribute],
        client: IPPClient,
        canFallBack: Bool,
        sizeIsInPageHeader: Bool
    ) async throws -> SendResult {
        var attributes = attributes
        var droppedOnce = false
        var droppedMediaCol = false
        var busyRetries = 0
        while true {
            do {
                let job = try await client.printJob(
                    documentFile: file, format: format, jobName: jobName, attributes: attributes)
                return .sent(job)
            } catch let error as IPPError {
                if Self.refusesFormat(error), canFallBack {
                    return .tryNextFormat
                }
                let refusedAttributes = error.status == IPPStatus.clientErrorAttributesOrValuesNotSupported.rawValue
                    && !error.unsupportedAttributes.isEmpty && !Self.refusesFormat(error)
                if refusedAttributes, !error.refusesMediaSize, !droppedOnce {
                    droppedOnce = true
                    dropAttributes(rejectedBy: error, from: &attributes)
                    continue
                }
                if refusedAttributes, sizeIsInPageHeader, !droppedMediaCol,
                   error.unsupportedAttributes.contains("media-col") {
                    droppedMediaCol = true
                    dropAttributes(rejectedBy: error, from: &attributes)
                    attributes.removeAll { $0.name == "media-col" }
                    paperSizeLeftToPrinter = true
                    continue
                }
                if error.status == IPPStatus.serverErrorBusy.rawValue, busyRetries < 3 {
                    busyRetries += 1
                    printerStatusText = "Printer busy; retrying…"
                    try await Task.sleep(for: .seconds(Self.busyRetryDelay))
                    continue
                }
                if error.isRefusal { throw error }
                throw UncertainDelivery(underlying: error)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.neverReachedPrinter {
                throw error
            } catch {
                // Never retried: the printer may already have the job.
                throw UncertainDelivery(underlying: error)
            }
        }
    }

    /// Seconds between Print-Job attempts while the printer reports busy.
    private static let busyRetryDelay = 5

    private static func refusesFormat(_ error: IPPError) -> Bool {
        if error.status == IPPStatus.clientErrorDocumentFormatNotSupported.rawValue { return true }
        return error.status == IPPStatus.clientErrorAttributesOrValuesNotSupported.rawValue
            && error.unsupportedAttributes.contains("document-format")
    }

    /// Removes what the printer refused. `media-col` is never removed whole here: it carries the paper
    /// size, and without it the printer would fall back to whatever it has loaded. Only its other members
    /// go. The one exception is the roll raster case in `send`.
    private func dropAttributes(rejectedBy error: IPPError, from attributes: inout [IPPAttribute]) {
        let rejected = Set(error.unsupportedAttributes).subtracting(["media-col"])
        attributes.removeAll { rejected.contains($0.name) }
        var dropped = error.unsupportedAttributes.filter { $0 != "media-col" }

        if error.unsupportedAttributes.contains("media-col"),
           let index = attributes.firstIndex(where: { $0.name == "media-col" }),
           let mediaCol = attributes[index].collections.first {
            let named = Set(error.unsupportedMembers["media-col"] ?? []).subtracting(["media-size"])
            let strip = named.isEmpty ? ["media-source", "media-type"] : named
            attributes[index] = .collection(
                "media-col", IPPCollection(members: mediaCol.members.filter { !strip.contains($0.name) }))
            dropped += mediaCol.members.map(\.name).filter { strip.contains($0) }
        }
        noteUnsupported(dropped)
    }

    private func noteUnsupported(_ names: [String]) {
        for name in names where !unsupportedAttributes.contains(name) {
            unsupportedAttributes.append(name)
        }
    }

    /// Polls a job until it ends. Rethrows cancellation; network blips are tolerated.
    private func pollToEnd(_ submitted: IPPJob, client: IPPClient) async throws -> JobOutcome {
        var job = submitted
        printerStatusText = "Job \(job.jobID): \(job.jobState.label)"
        let terminal: Set<IPPJob.JobState> = [.completed, .canceled, .aborted]
        var polls = 0
        var consecutiveFailures = 0
        while !terminal.contains(job.jobState), polls < 600 {
            try await Task.sleep(for: .seconds(polls < 10 ? 1 : 3))
            polls += 1
            do {
                job = try await client.getJobAttributes(jobID: job.jobID)
                consecutiveFailures = 0
                lastJob = job
                printerStatusText = "Job \(job.jobID): \(job.jobState.label)"
            } catch let error as CancellationError {
                throw error
            } catch let error as IPPError where error.status == IPPStatus.clientErrorNotFound.rawValue {
                // Printers that keep no job history forget a job as soon as it ends. The printer
                // answered and the job is over, but how it ended is unknown, so don't say Completed.
                printerStatusText = "Job \(job.jobID) sent; the printer no longer lists it"
                return .completed
            } catch {
                consecutiveFailures += 1
                if consecutiveFailures >= 5 {
                    printerStatusText = "Job \(job.jobID) sent; lost contact with printer"
                    lastError = "Job \(job.jobID) reached the printer, but the app lost contact before it finished. Check the printer before printing again."
                    return .lostContact
                }
            }
        }
        guard terminal.contains(job.jobState) else {
            printerStatusText = "Job \(job.jobID) still printing; check the printer"
            lastError = "Job \(job.jobID) is still printing and the app has stopped watching it. Check the printer."
            return .stillPrinting
        }
        printerStatusText = "Job \(job.jobID): \(job.jobState.label)"
        guard job.jobState == .completed else {
            var message = "Job \(job.jobState.label.lowercased()): \(job.jobStateReasons.joined(separator: ", "))."
            if job.jobState == .aborted {
                // Never resent automatically: some of it may already be on paper.
                message += " If the printer could not read the job, try another \"Send as\" format in the Printer pane."
            }
            lastError = message
            return .failed
        }
        return .completed
    }

    /// Cancels the last submitted job if it is still running.
    func cancelLastJob() async {
        guard let client, let job = lastJob else { return }
        do {
            try await client.cancelJob(jobID: job.jobID)
            lastJob = try await client.getJobAttributes(jobID: job.jobID)
        } catch {
            lastError = "Could not cancel the job. " + PrintErrorText.message(for: error)
        }
    }

    // MARK: - Document

    /// Opens a PDF or image at `url` (a security-scoped URL from the file importer is fine).
    /// Security-scoped access is held for the life of the document: PDFKit reads pages lazily.
    func loadDocument(url: URL) {
        lastError = nil
        releaseDocument()
        documentName = url.lastPathComponent
        loadGeneration += 1
        let generation = loadGeneration

        if url.startAccessingSecurityScopedResource() {
            documentURL = url
        }
        Task {
            let result: Result<PageSource, Error> = await Task.detached(priority: .userInitiated) {
                Result { try PageSource.load(url: url) }
            }.value
            guard generation == loadGeneration else { return }
            switch result {
            case .success(let source):
                pageSource = source
                pageCount = source.pageCount
                refreshPreview()
            case .failure(let error):
                releaseDocument()
                documentName = nil
                lastError = error.localizedDescription
            }
        }
    }

    private func releaseDocument() {
        previewTask?.cancel()
        documentURL?.stopAccessingSecurityScopedResource()
        documentURL = nil
        pageSource = nil
        previewImages = []
        pageCount = 0
    }

    deinit {
        documentURL?.stopAccessingSecurityScopedResource()
    }

    /// Re-renders `previewImages` for the current settings; cancels any render in flight.
    func refreshPreview() {
        previewTask?.cancel()
        guard let source = pageSource else {
            previewImages = []
            return
        }
        previewGeneration += 1
        let generation = previewGeneration
        let settingsSnapshot = settings
        previewTask = Task {
            let plans = Imposer.plan(settings: settingsSnapshot, pageSizes: source.pageSizes)
            let shown = Array(plans.prefix(Self.maxPreviewSheets))
            let images = await SheetComposer.previewImages(plans: shown, source: source, settings: settingsSnapshot, maxPixels: 1600)
            guard !Task.isCancelled, generation == previewGeneration else { return }
            previewImages = images.map { UIImage(cgImage: $0) }
        }
    }

    static let maxPreviewSheets = 24
}

extension PageSource {
    /// Page sizes in points, in page order.
    var pageSizes: [CGSize] {
        (0..<pageCount).map { pageSizePt($0) }
    }
}

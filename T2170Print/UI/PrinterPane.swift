import SwiftUI

/// Captures everything the printer reports and hands it off, in plain view rather than behind a
/// disclosure. In a Form row, buttons need a style of their own or a tap anywhere fires them all.
private struct PrinterDetailsSection: View {
    let session: PrintSession

    @State private var justCopied = false

    var body: some View {
        Section {
            Button {
                Task { await session.captureAttributeReport() }
            } label: {
                if session.isCapturingReport {
                    Label("Asking the printer…", systemImage: "hourglass")
                } else {
                    Label(session.attributeReport == nil ? "Capture Printer Details" : "Capture Again",
                          systemImage: "doc.text.magnifyingglass")
                }
            }
            .buttonStyle(.bordered)
            .disabled(!session.canCaptureReport || session.isCapturingReport)

            if let report = session.attributeReport {
                LabeledContent("Captured", value: report.summary)

                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = report.text
                        justCopied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            justCopied = false
                        }
                    } label: {
                        Label(justCopied ? "Copied" : "Copy", systemImage: justCopied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)

                    shareLink(for: report)
                        .buttonStyle(.borderedProminent)
                }
            }
        } header: {
            Text("Printer Details")
        } footer: {
            Text(session.canCaptureReport
                 ? "Share offers Mail, Messages and AirDrop. This prints nothing and uses no ink or paper."
                 : "Connect to a printer first.")
        }
    }

    @ViewBuilder
    private func shareLink(for report: AttributeReportFile) -> some View {
        let subject = Text("T2170 printer details")
        if let url = report.fileURL {
            ShareLink(item: url, subject: subject) {
                Label("Email or Share", systemImage: "square.and.arrow.up")
            }
        } else {
            ShareLink(item: report.text, subject: subject) {
                Label("Email or Share", systemImage: "square.and.arrow.up")
            }
        }
    }
}

struct PrinterPane: View {
    @Bindable var session: PrintSession

    @State private var printerAddress: String = ""
    @State private var showingAttributes = false

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Printer", value: session.printerName ?? "None")
                LabeledContent("Status", value: session.printerStatusText)

                HStack(spacing: 10) {
                    TextField("Printer address", text: $printerAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textFieldStyle(.roundedBorder)

                    Button("Connect") {
                        let host = printerAddress
                        Task {
                            await session.connect(host: host)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(printerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Button("Acquire Info") {
                    Task {
                        await session.acquirePrinterInfo()
                    }
                }
                .disabled(session.capabilities == nil)

                if session.capabilities != nil {
                    Picker("Send as", selection: $session.sendFormat) {
                        ForEach(session.availableSendFormats) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                }

                if let error = session.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            PrinterDetailsSection(session: session)

            Section {
                if session.discovery.printers.isEmpty {
                    Text(session.discovery.isBrowsing ? "Searching…" : "No printers found yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(session.discovery.printers) { printer in
                        Button {
                            printerAddress = printer.host
                            Task { await session.connect(to: printer) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(printer.name)
                                Text(printer.uri.absoluteString)
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let error = session.discovery.lastError {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Discovered")
                    Spacer()
                    Button(session.discovery.isBrowsing ? "Stop" : "Search") {
                        if session.discovery.isBrowsing {
                            session.discovery.stop()
                        } else {
                            session.discovery.start()
                        }
                    }
                    .font(.footnote)
                }
            }

            if let job = session.lastJob {
                Section("Last job") {
                    LabeledContent("Job \(job.jobID)", value: job.jobState.label)
                    if let sent = session.lastSentFormat {
                        LabeledContent("Sent as", value: sent)
                    }
                    if !job.jobStateReasons.isEmpty {
                        Text(job.jobStateReasons.joined(separator: ", "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if !session.unsupportedAttributes.isEmpty {
                        Text("Left out (the printer didn't list or refused these): " + session.unsupportedAttributes.joined(separator: ", "))
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if session.paperSizeLeftToPrinter {
                        Text("The printer refused this roll length, so the size was sent in the print data only. Check it printed on the roll at the right size.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if ![.completed, .canceled, .aborted].contains(job.jobState) {
                        Button("Cancel job", role: .destructive) {
                            Task { await session.cancelLastJob() }
                        }
                    }
                }
            }

            Section("Ink Levels") {
                if session.inkLevels.isEmpty {
                    Text("No ink level information available.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(session.inkLevels) { ink in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(ink.name)
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text("\(ink.percent)%")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }

                            GeometryReader { proxy in
                                let fraction = Double(max(0, min(100, ink.percent))) / 100.0
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.secondary.opacity(0.2))
                                    Capsule()
                                        .fill(Self.markerColor(for: ink))
                                        .frame(width: proxy.size.width * fraction)
                                    Capsule()
                                        .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
                                }
                            }
                            .frame(height: 12)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section {
                DisclosureGroup("Printer attributes", isExpanded: $showingAttributes) {
                    if session.printerAttributes.isEmpty {
                        Text("No attributes acquired.")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        ShareLink("Share all attributes", item: session.printerAttributesText)
                        ForEach(session.printerAttributes.keys.sorted(), id: \.self) { key in
                            let values = session.printerAttributes[key] ?? []
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key)
                                    .font(.system(.footnote, design: .monospaced).weight(.semibold))
                                Text(values.joined(separator: ", "))
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .textSelection(.enabled)
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .navigationTitle("Printer")
        .onAppear { session.discovery.start() }
        .onDisappear { session.discovery.stop() }
    }

    private static func markerColor(for ink: InkLevel) -> Color {
        if let raw = ink.color?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            if let hexColor = parseHexColor(raw) {
                return hexColor
            }
            let lower = raw.lowercased()
            if lower.contains("cyan") { return .cyan }
            if lower.contains("magenta") { return .pink }
            if lower.contains("yellow") { return .yellow }
            if lower.contains("black") { return .black }
        }
        let lowerName = ink.name.lowercased()
        if lowerName.contains("cyan") { return .cyan }
        if lowerName.contains("magenta") { return .pink }
        if lowerName.contains("yellow") { return .yellow }
        if lowerName.contains("black") { return .black }
        return .accentColor
    }

    private static func parseHexColor(_ string: String) -> Color? {
        var cleaned = string
        if cleaned.hasPrefix("#") {
            cleaned.removeFirst()
        }
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else {
            return nil
        }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}

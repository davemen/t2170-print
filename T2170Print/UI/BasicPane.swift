import SwiftUI

struct BasicPane: View {
    @Bindable var session: PrintSession

    @State private var showingSavePresetAlert = false
    @State private var showingRenamePresetAlert = false
    @State private var presetNameInput = ""
    @State private var showingCustomPaperSheet = false
    @State private var showingColorControls = false
    @State private var pageListText = ""

    private enum PageRangeMode: String, CaseIterable, Identifiable {
        case all = "All"
        case fromTo = "From–To"
        case list = "List"
        var id: String { rawValue }
    }

    private enum PaperSizeChoice: Hashable {
        case standard(PaperSize)
        case custom
    }

    var body: some View {
        Form {
            presetsSection
            copiesAndPagesSection
            paperAndOutputSection
            mediaAndQualitySection
        }
        .navigationTitle("Basic")
        .onChange(of: session.settings) { _, _ in
            session.save()
        }
        .alert("Save Preset", isPresented: $showingSavePresetAlert) {
            TextField("Preset Name", text: $presetNameInput)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                session.savePreset(name: presetNameInput)
                presetNameInput = ""
            }
        } message: {
            Text("Enter a name for the current print settings preset.")
        }
        .alert("Rename Preset", isPresented: $showingRenamePresetAlert) {
            TextField("Preset Name", text: $presetNameInput)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let id = session.selectedPreset {
                    session.renamePreset(id: id, name: presetNameInput)
                }
                presetNameInput = ""
            }
        } message: {
            Text("Enter a new name for the selected preset.")
        }
        .sheet(isPresented: $showingCustomPaperSheet) {
            CustomPaperSizeSheet(
                initialSize: session.settings.customPaperSize ?? session.settings.paperSize
            ) { customSize in
                session.settings.customPaperSize = customSize
                session.save()
            }
        }
    }

    // MARK: - Sections

    private var presetsSection: some View {
        Section {
            LabeledContent("Presets") {
                Menu {
                    Button {
                        session.settings = PrintSettings()
                        session.selectedPreset = nil
                        session.save()
                    } label: {
                        if session.selectedPreset == nil {
                            Label("Default Settings", systemImage: "checkmark")
                        } else {
                            Text("Default Settings")
                        }
                    }

                    if !session.presets.isEmpty {
                        Section("Saved Presets") {
                            ForEach(session.presets) { preset in
                                Button {
                                    session.applyPreset(preset)
                                } label: {
                                    if session.selectedPreset == preset.id {
                                        Label(preset.name, systemImage: "checkmark")
                                    } else {
                                        Text(preset.name)
                                    }
                                }
                            }
                        }
                    }

                    Divider()

                    Button("Save Current Settings as Preset…") {
                        presetNameInput = ""
                        showingSavePresetAlert = true
                    }

                    if let selectedID = session.selectedPreset,
                       let current = session.presets.first(where: { $0.id == selectedID }) {
                        Button("Rename \"\(current.name)\"…") {
                            presetNameInput = current.name
                            showingRenamePresetAlert = true
                        }
                        Button("Delete \"\(current.name)\"", role: .destructive) {
                            session.deletePreset(id: selectedID)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedPresetTitle)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                    }
                }
            }
        }
    }

    private var copiesAndPagesSection: some View {
        Section("Copies & Pages") {
            LabeledContent("Copies") {
                HStack(spacing: 8) {
                    TextField(
                        "Copies",
                        value: Binding(
                            get: { session.settings.copies },
                            set: { session.settings.copies = max(1, min(999, $0)) }
                        ),
                        format: .number
                    )
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)

                    Stepper(
                        "",
                        value: $session.settings.copies,
                        in: 1...999
                    )
                    .labelsHidden()
                }
            }

            Picker("Pages", selection: pageRangeModeBinding) {
                ForEach(PageRangeMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            switch session.settings.pageRange {
            case .all:
                EmptyView()
            case .range(let from, let to):
                HStack(spacing: 16) {
                    LabeledContent("From") {
                        HStack(spacing: 6) {
                            TextField(
                                "From",
                                value: Binding(
                                    get: { from },
                                    set: { newFrom in
                                        let clamped = max(1, newFrom)
                                        session.settings.pageRange = .range(from: clamped, to: max(clamped, to))
                                    }
                                ),
                                format: .number
                            )
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)

                            Stepper(
                                "",
                                value: Binding(
                                    get: { from },
                                    set: { newFrom in
                                        let clamped = max(1, newFrom)
                                        session.settings.pageRange = .range(from: clamped, to: max(clamped, to))
                                    }
                                ),
                                in: 1...9999
                            )
                            .labelsHidden()
                        }
                    }

                    LabeledContent("To") {
                        HStack(spacing: 6) {
                            TextField(
                                "To",
                                value: Binding(
                                    get: { to },
                                    set: { newTo in
                                        let clamped = max(from, newTo)
                                        session.settings.pageRange = .range(from: from, to: clamped)
                                    }
                                ),
                                format: .number
                            )
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)

                            Stepper(
                                "",
                                value: Binding(
                                    get: { to },
                                    set: { newTo in
                                        let clamped = max(from, newTo)
                                        session.settings.pageRange = .range(from: from, to: clamped)
                                    }
                                ),
                                in: max(1, from)...9999
                            )
                            .labelsHidden()
                        }
                    }
                }
            case .selection(let pages):
                LabeledContent("Page Numbers") {
                    TextField(
                        "e.g. 1, 3, 5-8",
                        text: Binding(
                            get: {
                                pageListText.isEmpty
                                    ? pages.map(String.init).joined(separator: ", ")
                                    : pageListText
                            },
                            set: { newValue in
                                pageListText = newValue
                                let parsed = Self.parsePageSelection(newValue)
                                session.settings.pageRange = .selection(parsed.isEmpty ? [1] : parsed)
                            }
                        )
                    )
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                }
            }
        }
    }

    private var paperAndOutputSection: some View {
        Section("Paper & Output") {
            Picker("Paper Size", selection: paperSizeChoiceBinding) {
                ForEach(PaperSize.standard) { size in
                    Text(size.name).tag(PaperSizeChoice.standard(size))
                }
                Divider()
                Text("Custom…").tag(PaperSizeChoice.custom)
            }
            .pickerStyle(.menu)

            if let custom = session.settings.customPaperSize {
                LabeledContent("Custom Size") {
                    HStack(spacing: 8) {
                        Text("\(custom.name) (\(Int(custom.widthMM.rounded())) × \(Int(custom.heightMM.rounded())) mm)")
                            .foregroundStyle(.secondary)
                        Button("Edit…") {
                            showingCustomPaperSheet = true
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Picker("Orientation", selection: $session.settings.orientation) {
                ForEach(Orientation.allCases) { orientation in
                    Text(orientation.label).tag(orientation)
                }
            }
            .pickerStyle(.segmented)

            Picker("Output Size", selection: $session.settings.outputSize) {
                ForEach(OutputSizeMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)

            switch session.settings.outputSize {
            case .specifySize:
                LabeledContent("Width (mm)") {
                    TextField(
                        "Width",
                        value: specifiedWidthBinding,
                        format: .number
                    )
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                }
                LabeledContent("Height (mm)") {
                    TextField(
                        "Height",
                        value: specifiedHeightBinding,
                        format: .number
                    )
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                }
            case .retainScale:
                LabeledContent("Scale (%)") {
                    TextField(
                        "Scale %",
                        value: $session.settings.retainScalePercent,
                        format: .number
                    )
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                }
            case .banner:
                LabeledContent("Banner Length (mm)") {
                    TextField(
                        "Length (mm)",
                        value: $session.settings.bannerLengthMM,
                        format: .number
                    )
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                }
            case .sameAsPaperSize, .fitToRollPaperWidth, .outputSize:
                EmptyView()
            }

            Picker("Paper Source", selection: $session.settings.paperSource) {
                ForEach(PaperSource.allCases) { source in
                    Text(source.label).tag(source)
                }
            }
            .pickerStyle(.segmented)

            if session.settings.paperSource == .rollPaper {
                Picker("Roll Paper Width", selection: $session.settings.rollWidth) {
                    ForEach(RollWidth.allCases) { width in
                        Text(width.label).tag(width)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var mediaAndQualitySection: some View {
        Section("Media & Quality") {
            HStack {
                Picker("Media Type", selection: $session.settings.mediaType) {
                    Section {
                        ForEach(MediaType.allCases) { media in
                            Text(media.label).tag(media)
                        }
                    }
                    if !session.printerSupportedMediaTypes.isEmpty {
                        Section("From printer") {
                            ForEach(session.printerSupportedMediaTypes, id: \.self) { printerMedia in
                                Button(printerMedia) {
                                    if let matched = Self.matchMediaType(printerMedia) {
                                        session.settings.mediaType = matched
                                    }
                                }
                            }
                        }
                    }
                }
                .pickerStyle(.menu)

                Button("Acquire Info") {
                    Task {
                        await session.acquirePrinterInfo()
                    }
                }
                .buttonStyle(.bordered)
            }

            Picker("Select Target", selection: $session.settings.selectTarget) {
                ForEach(SelectTarget.allCases) { target in
                    Text(target.label).tag(target)
                }
            }
            .pickerStyle(.menu)

            Toggle("Simple Settings", isOn: $session.settings.simpleSettings)

            if session.settings.simpleSettings {
                Toggle("Print with High Quality", isOn: $session.settings.printWithHighQuality)
            } else {
                Picker("Print Mode", selection: $session.settings.printMode) {
                    ForEach(PrintMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                Picker("Color Mode", selection: $session.settings.colorMode) {
                    ForEach(ColorMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                Picker("Level", selection: $session.settings.level) {
                    ForEach(QualityLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Emphasize Thin Lines", isOn: $session.settings.emphasizeThinLines)

                DisclosureGroup("Color Controls…", isExpanded: $showingColorControls) {
                    ColorControlsView(session: session)
                }
            }
        }
    }

    // MARK: - Bindings & Helpers

    private var selectedPresetTitle: String {
        if let id = session.selectedPreset,
           let preset = session.presets.first(where: { $0.id == id }) {
            return preset.name
        }
        return "Default Settings"
    }

    private var pageRangeModeBinding: Binding<PageRangeMode> {
        Binding(
            get: {
                switch session.settings.pageRange {
                case .all: .all
                case .range: .fromTo
                case .selection: .list
                }
            },
            set: { newMode in
                switch newMode {
                case .all:
                    session.settings.pageRange = .all
                case .fromTo:
                    let end = max(1, session.pageCount)
                    session.settings.pageRange = .range(from: 1, to: end)
                case .list:
                    pageListText = "1"
                    session.settings.pageRange = .selection([1])
                }
            }
        )
    }

    private var paperSizeChoiceBinding: Binding<PaperSizeChoice> {
        Binding(
            get: {
                if session.settings.customPaperSize != nil {
                    return .custom
                }
                return .standard(session.settings.paperSize)
            },
            set: { choice in
                switch choice {
                case .standard(let size):
                    session.settings.paperSize = size
                    session.settings.customPaperSize = nil
                case .custom:
                    showingCustomPaperSheet = true
                }
            }
        )
    }

    private var specifiedWidthBinding: Binding<Double> {
        Binding(
            get: {
                (session.settings.specifiedOutputSize ?? session.settings.effectivePaperSize).widthMM
            },
            set: { newWidth in
                let current = session.settings.specifiedOutputSize ?? session.settings.effectivePaperSize
                session.settings.specifiedOutputSize = PaperSize(
                    name: "Specified",
                    widthMM: max(1, newWidth),
                    heightMM: current.heightMM,
                    ippMediaName: nil
                )
            }
        )
    }

    private var specifiedHeightBinding: Binding<Double> {
        Binding(
            get: {
                (session.settings.specifiedOutputSize ?? session.settings.effectivePaperSize).heightMM
            },
            set: { newHeight in
                let current = session.settings.specifiedOutputSize ?? session.settings.effectivePaperSize
                session.settings.specifiedOutputSize = PaperSize(
                    name: "Specified",
                    widthMM: current.widthMM,
                    heightMM: max(1, newHeight),
                    ippMediaName: nil
                )
            }
        )
    }

    private static func parsePageSelection(_ input: String) -> [Int] {
        var result = Set<Int>()
        let parts = input.split(separator: ",")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let bounds = trimmed.split(separator: "-")
            if bounds.count == 2,
               let start = Int(bounds[0].trimmingCharacters(in: .whitespaces)),
               let end = Int(bounds[1].trimmingCharacters(in: .whitespaces)),
               start >= 1, end >= start {
                for page in start...min(end, start + 1000) {
                    result.insert(page)
                }
            } else if let single = Int(trimmed), single >= 1 {
                result.insert(single)
            }
        }
        return result.sorted()
    }

    private static func matchMediaType(_ name: String) -> MediaType? {
        MediaType.allCases.first { media in
            media.label.localizedCaseInsensitiveCompare(name) == .orderedSame ||
            media.rawValue.localizedCaseInsensitiveCompare(name) == .orderedSame ||
            media.ippMediaType?.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }
}

private struct CustomPaperSizeSheet: View {
    enum Unit: String, CaseIterable, Identifiable {
        case mm = "mm"
        case inches = "in"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var widthValue: Double
    @State private var heightValue: Double
    @State private var unit: Unit = .mm

    let onSave: (PaperSize) -> Void

    init(initialSize: PaperSize, onSave: @escaping (PaperSize) -> Void) {
        _name = State(initialValue: initialSize.ippMediaName == nil ? initialSize.name : "Custom")
        _widthValue = State(initialValue: initialSize.widthMM)
        _heightValue = State(initialValue: initialSize.heightMM)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Custom Paper Size") {
                    LabeledContent("Name") {
                        TextField("Name", text: $name)
                            .multilineTextAlignment(.trailing)
                    }

                    Picker("Unit", selection: $unit) {
                        ForEach(Unit.allCases) { u in
                            Text(u.rawValue).tag(u)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: unit) { oldUnit, newUnit in
                        guard oldUnit != newUnit else { return }
                        if newUnit == .inches {
                            widthValue = (widthValue / 25.4 * 100).rounded() / 100
                            heightValue = (heightValue / 25.4 * 100).rounded() / 100
                        } else {
                            widthValue = (widthValue * 25.4 * 10).rounded() / 10
                            heightValue = (heightValue * 25.4 * 10).rounded() / 10
                        }
                    }

                    LabeledContent("Width (\(unit.rawValue))") {
                        TextField("Width", value: $widthValue, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("Height (\(unit.rawValue))") {
                        TextField("Height", value: $heightValue, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle("Custom Paper Size")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let widthMM = unit == .mm ? widthValue : widthValue * 25.4
                        let heightMM = unit == .mm ? heightValue : heightValue * 25.4
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let size = PaperSize(
                            name: trimmedName.isEmpty ? "Custom" : trimmedName,
                            widthMM: max(10, widthMM),
                            heightMM: max(10, heightMM),
                            ippMediaName: nil
                        )
                        onSave(size)
                        dismiss()
                    }
                }
            }
        }
    }
}

import SwiftUI

struct AdvancedPane: View {
    @Bindable var session: PrintSession

    private var isRollPaper: Bool {
        session.settings.paperSource == .rollPaper
    }

    var body: some View {
        Form {
            Section {
                Picker("Auto Cut", selection: $session.settings.advanced.autoCut) {
                    ForEach(AutoCut.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Auto Rotate", isOn: $session.settings.advanced.autoRotate)
                Toggle("Print Page Line", isOn: $session.settings.advanced.printPageLine)
                Toggle("Save Roll Paper", isOn: $session.settings.advanced.saveRollPaper)
            } header: {
                Text("Roll Paper Option")
            } footer: {
                if !isRollPaper {
                    Text("Roll paper controls are only available when Paper Source is set to Roll Paper.")
                }
            }
            .disabled(!isRollPaper)

            Section("Density") {
                densitySliderRow(
                    title: "Black",
                    value: $session.settings.advanced.densityBlack
                )
                densitySliderRow(
                    title: "Color",
                    value: $session.settings.advanced.densityColor
                )
            }
        }
        .navigationTitle("Advanced")
        .onChange(of: session.settings) { _, _ in
            session.save()
        }
    }

    private func densitySliderRow(title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 60, alignment: .leading)
            Slider(value: value, in: AdvancedSettings.densityRange, step: 1)
            Text("\(Int(value.wrappedValue.rounded())) %")
                .font(.body.monospacedDigit())
                .frame(width: 56, alignment: .trailing)
        }
    }
}

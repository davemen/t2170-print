import SwiftUI

struct ColorMatchingPane: View {
    @Bindable var session: PrintSession

    var body: some View {
        Form {
            Section("Color Matching") {
                Picker("Color Matching", selection: $session.settings.colorMatching) {
                    ForEach(ColorMatching.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                ForEach(ColorMatching.allCases) { option in
                    Button {
                        session.settings.colorMatching = option
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(
                                systemName: session.settings.colorMatching == option
                                    ? "largecircle.fill.circle"
                                    : "circle"
                            )
                            .foregroundStyle(
                                session.settings.colorMatching == option
                                    ? Color.accentColor
                                    : Color.secondary
                            )
                            .font(.title3)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.label)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Text(explanation(for: option))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Color Matching")
        .onChange(of: session.settings) { _, _ in
            session.save()
        }
    }

    private func explanation(for option: ColorMatching) -> String {
        switch option {
        case .colorSync:
            "Performs color matching using the host ColorSync color management system."
        case .epsonColorControls:
            "Performs color matching using the EPSON printer driver's color controls and modes."
        }
    }
}

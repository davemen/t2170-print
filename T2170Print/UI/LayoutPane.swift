import SwiftUI

struct LayoutPane: View {
    @Bindable var session: PrintSession

    var body: some View {
        Form {
            Section("Layout") {
                Picker("Pages per Sheet", selection: $session.settings.layout.pagesPerSheet) {
                    ForEach(PagesPerSheet.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.menu)

                VStack(alignment: .leading, spacing: 10) {
                    Picker("Layout Direction", selection: $session.settings.layout.layoutDirection) {
                        ForEach(LayoutDirection.allCases) { direction in
                            Text(direction.label).tag(direction)
                        }
                    }
                    .pickerStyle(.menu)

                    HStack(spacing: 12) {
                        ForEach(LayoutDirection.allCases) { direction in
                            let isSelected = session.settings.layout.layoutDirection == direction
                            Button {
                                session.settings.layout.layoutDirection = direction
                            } label: {
                                VStack(spacing: 4) {
                                    LayoutDirectionGlyph(direction: direction, isSelected: isSelected)
                                    Text(direction.label)
                                        .font(.caption2)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .disabled(session.settings.layout.pagesPerSheet == .one)

                Picker("Border", selection: $session.settings.layout.border) {
                    ForEach(PageBorder.allCases) { border in
                        Text(border.label).tag(border)
                    }
                }
                .pickerStyle(.menu)

                Toggle("Reverse page orientation", isOn: $session.settings.layout.reversePageOrientation)
                Toggle("Flip horizontally", isOn: $session.settings.layout.flipHorizontally)
            }

            Section("Page Layout (Windows driver)") {
                Picker("Poster", selection: $session.settings.layout.poster) {
                    ForEach(PosterSplit.allCases) { split in
                        Text(split.label).tag(split)
                    }
                }
                .pickerStyle(.segmented)

                if session.settings.layout.poster != .off {
                    LabeledContent("Overlap (mm)") {
                        TextField(
                            "Overlap (mm)",
                            value: $session.settings.layout.posterOverlapMM,
                            format: .number
                        )
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 96)
                    }
                }

            }
        }
        .navigationTitle("Layout")
        .onChange(of: session.settings) { _, _ in
            session.save()
        }
    }
}

private struct LayoutDirectionGlyph: View {
    let direction: LayoutDirection
    let isSelected: Bool

    private var gridNumbers: [[Int]] {
        switch direction {
        case .leftRightTopBottom:
            [[1, 2], [3, 4]]
        case .rightLeftTopBottom:
            [[2, 1], [4, 3]]
        case .topBottomLeftRight:
            [[1, 3], [2, 4]]
        case .topBottomRightLeft:
            [[3, 1], [4, 2]]
        }
    }

    var body: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(0..<2, id: \.self) { col in
                        Text("\(gridNumbers[row][col])")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .frame(width: 16, height: 18)
                            .background(
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 0.75)
                            )
                    }
                }
            }
        }
    }
}

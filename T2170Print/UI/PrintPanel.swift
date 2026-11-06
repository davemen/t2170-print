import SwiftUI

struct PrintPanel: View {
    enum Pane: String, CaseIterable, Identifiable {
        case printer
        case basic
        case advanced
        case layout
        case paperHandling
        case colorMatching
        case preview

        var id: String { rawValue }

        var title: String {
            switch self {
            case .printer: "Printer"
            case .basic: "Basic"
            case .advanced: "Advanced"
            case .layout: "Layout"
            case .paperHandling: "Paper Handling"
            case .colorMatching: "Color Matching"
            case .preview: "Preview"
            }
        }

        var systemImage: String {
            switch self {
            case .printer: "printer"
            case .basic: "slider.horizontal.3"
            case .advanced: "gearshape.2"
            case .layout: "rectangle.grid.2x2"
            case .paperHandling: "doc.on.doc"
            case .colorMatching: "paintpalette"
            case .preview: "eye"
            }
        }
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var session: PrintSession
    @State private var selectedPane: Pane = .basic

    init(session: PrintSession? = nil) {
        _session = State(initialValue: session ?? PrintSession())
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                TabView(selection: $selectedPane) {
                    ForEach(Pane.allCases) { pane in
                        NavigationStack {
                            paneView(for: pane)
                        }
                        .tabItem {
                            Label(pane.title, systemImage: pane.systemImage)
                        }
                        .tag(pane)
                    }
                }
            } else {
                NavigationSplitView {
                    List(Pane.allCases, selection: Binding<Pane?>(
                        get: { selectedPane },
                        set: { if let pane = $0 { selectedPane = pane } }
                    )) { pane in
                        Label(pane.title, systemImage: pane.systemImage)
                            .tag(pane)
                    }
                    .navigationTitle("T2170 Print")
                } detail: {
                    NavigationStack {
                        paneView(for: selectedPane)
                    }
                }
            }
        }
        .onChange(of: session.settings) { _, _ in
            session.save()
            session.refreshPreview()
        }
        .onChange(of: session.presets) { _, _ in
            session.save()
        }
    }

    @ViewBuilder
    private func paneView(for pane: Pane) -> some View {
        switch pane {
        case .printer:
            PrinterPane(session: session)
        case .basic:
            BasicPane(session: session)
        case .advanced:
            AdvancedPane(session: session)
        case .layout:
            LayoutPane(session: session)
        case .paperHandling:
            PaperHandlingPane(session: session)
        case .colorMatching:
            ColorMatchingPane(session: session)
        case .preview:
            PreviewPane(session: session)
        }
    }
}

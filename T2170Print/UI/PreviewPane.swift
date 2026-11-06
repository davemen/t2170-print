import SwiftUI
import UniformTypeIdentifiers

struct PreviewPane: View {
    @Bindable var session: PrintSession

    @State private var currentPage: Int = 0
    @State private var steadyZoom: CGFloat = 1.0
    @GestureState private var gestureZoom: CGFloat = 1.0
    @State private var showingFileImporter = false

    private var hasDocument: Bool {
        session.documentName != nil || !session.previewImages.isEmpty
    }

    private var hasPrinter: Bool {
        guard let name = session.printerName else { return false }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var effectiveZoom: CGFloat {
        min(6.0, max(0.5, steadyZoom * gestureZoom))
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { session.lastError != nil },
            set: { isPresented in
                if !isPresented {
                    session.lastError = nil
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if session.previewImages.isEmpty {
                ContentUnavailableView(
                    "Open a document to preview",
                    systemImage: "doc.richtext",
                    description: Text(session.documentName ?? "Tap Open to load a PDF or image file.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TabView(selection: $currentPage) {
                    ForEach(Array(session.previewImages.enumerated()), id: \.offset) { index, image in
                        ScrollView([.horizontal, .vertical], showsIndicators: true) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .scaleEffect(effectiveZoom)
                                .padding()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .gesture(
                            MagnifyGesture()
                                .updating($gestureZoom) { value, state, _ in
                                    state = value.magnification
                                }
                                .onEnded { value in
                                    steadyZoom = min(6.0, max(0.5, steadyZoom * value.magnification))
                                }
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))

                Divider()

                HStack {
                    if let docName = session.documentName {
                        Text(docName)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    let totalPages = max(session.pageCount, session.previewImages.count)
                    let displayedPage = min(currentPage + 1, max(1, totalPages))
                    Text("Page \(displayedPage) of \(totalPages)")
                        .font(.footnote.monospacedDigit())
                    Spacer()
                    if abs(steadyZoom - 1.0) > 0.01 {
                        Button("100%") {
                            steadyZoom = 1.0
                        }
                        .font(.footnote)
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
        .navigationTitle("Preview")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingFileImporter = true
                } label: {
                    Label("Open", systemImage: "folder")
                }
                .disabled(session.isPrinting)

                if session.isPrinting {
                    ProgressView()
                }

                Button {
                    Task {
                        await session.print()
                    }
                } label: {
                    Label("Print", systemImage: "printer.fill")
                }
                .disabled(!hasDocument || !hasPrinter || session.isPrinting)
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.pdf, .image, .jpeg, .png, .heic, .tiff],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let firstURL = urls.first {
                    currentPage = 0
                    steadyZoom = 1.0
                    session.loadDocument(url: firstURL)
                }
            case .failure(let error):
                session.lastError = error.localizedDescription
            }
        }
        .alert("Print Error", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) {
                session.lastError = nil
            }
        } message: {
            Text(session.lastError ?? "")
        }
    }
}

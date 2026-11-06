import SwiftUI

struct PaperHandlingPane: View {
    @Bindable var session: PrintSession

    private var destinationPaperBinding: Binding<PaperSize> {
        Binding(
            get: {
                session.settings.paperHandling.destinationPaperSize ?? session.settings.effectivePaperSize
            },
            set: { newSize in
                session.settings.paperHandling.destinationPaperSize = newSize
            }
        )
    }

    var body: some View {
        Form {
            Section("Paper Handling") {
                Toggle("Collate sheets", isOn: $session.settings.paperHandling.collate)

                Picker("Pages to Print", selection: $session.settings.paperHandling.pagesToPrint) {
                    ForEach(PagesToPrint.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Page Order", selection: $session.settings.paperHandling.pageOrder) {
                    ForEach(PageOrder.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Destination Paper Size") {
                Toggle("Scale to fit paper size", isOn: $session.settings.paperHandling.scaleToFitPaperSize)
                    .onChange(of: session.settings.paperHandling.scaleToFitPaperSize) { _, enabled in
                        if enabled && session.settings.paperHandling.destinationPaperSize == nil {
                            session.settings.paperHandling.destinationPaperSize = session.settings.effectivePaperSize
                        }
                    }

                Picker("Destination Paper Size", selection: destinationPaperBinding) {
                    ForEach(PaperSize.standard) { size in
                        Text(size.name).tag(size)
                    }
                    if let custom = session.settings.customPaperSize,
                       !PaperSize.standard.contains(custom) {
                        Text(custom.name).tag(custom)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!session.settings.paperHandling.scaleToFitPaperSize)

                Toggle("Scale down only", isOn: $session.settings.paperHandling.scaleDownOnly)
                    .disabled(!session.settings.paperHandling.scaleToFitPaperSize)
            }
        }
        .navigationTitle("Paper Handling")
        .onChange(of: session.settings) { _, _ in
            session.save()
        }
    }
}

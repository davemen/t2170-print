import Foundation
import CoreGraphics
import Testing
@testable import T2170Print

@Suite("JobAttributesBuilder Tests")
struct JobAttributesBuilderTests {
    @Test("Default PrintSettings yields copies 1, media-col A4 21000x29700, media-source roll-1, and finishings [11]")
    func defaultSettingsAttributes() {
        let settings = PrintSettings()
        let (attributes, unsupported) = JobAttributesBuilder.attributes(
            for: settings,
            capabilities: nil,
            documentFormat: "application/pdf"
        )

        #expect(unsupported.isEmpty)

        let copiesAttr = attributes.first { $0.name == "copies" }
        #expect(copiesAttr?.intValue == 1)

        let mediaColAttr = attributes.first { $0.name == "media-col" }
        let mediaCol = mediaColAttr?.collectionValue
        #expect(mediaCol != nil)

        let mediaSize = mediaCol?.firstValue(for: "media-size")?.collectionValue
        #expect(mediaSize?.firstValue(for: "x-dimension")?.intValue == 21000)
        #expect(mediaSize?.firstValue(for: "y-dimension")?.intValue == 29700)
        #expect(mediaCol?.firstValue(for: "media-source")?.stringValue == "roll-1")

        let finishingsAttr = attributes.first { $0.name == "finishings" }
        #expect(finishingsAttr?.integers == [11])
    }

    @Test("Auto-cut falls back to the trim variant the printer lists")
    func autoCutUsesListedTrimVariant() {
        let capabilities = PrinterCapabilities(attributes: [
            IPPAttribute(name: "media-source-supported", values: [.keyword("roll-1")]),
            IPPAttribute(name: "finishings-supported", values: [.enumValue(3), .enumValue(60)])
        ])
        let (attributes, unsupported) = JobAttributesBuilder.attributes(
            for: PrintSettings(),
            capabilities: capabilities,
            documentFormat: "application/pdf"
        )
        #expect(attributes.first { $0.name == "finishings" }?.integers == [60])
        #expect(!unsupported.contains("finishings"))
    }

    @Test("Capabilities lacking finishings-supported 11 drops finishings and records it in unsupported")
    func capabilitiesLackingFinishings11DropsFinishing() {
        let settings = PrintSettings()
        let capabilities = PrinterCapabilities(attributes: [
            IPPAttribute(name: "media-source-supported", values: [.keyword("roll-1"), .keyword("manual")]),
            IPPAttribute(name: "finishings-supported", values: [.enumValue(3)])
        ])

        let (attributes, unsupported) = JobAttributesBuilder.attributes(
            for: settings,
            capabilities: capabilities,
            documentFormat: "application/pdf"
        )

        #expect(attributes.first { $0.name == "finishings" } == nil)
        #expect(unsupported.contains("finishings"))
    }

    @Test("sheetSizeMM overrides media-col dimensions; number-up is 1; no orientation or number-up-layout")
    func sheetSizeOverridesMediaColAndSuppressesImposition() {
        let (attributes, unsupported) = JobAttributesBuilder.attributes(
            for: PrintSettings(),
            capabilities: nil,
            documentFormat: "application/pdf",
            sheetSizeMM: CGSize(width: 609.6, height: 914.4)
        )

        #expect(unsupported.isEmpty)

        let mediaSize = attributes.first { $0.name == "media-col" }?
            .collectionValue?.firstValue(for: "media-size")?.collectionValue
        #expect(mediaSize?.firstValue(for: "x-dimension")?.intValue == 60960)
        #expect(mediaSize?.firstValue(for: "y-dimension")?.intValue == 91440)

        #expect(attributes.first { $0.name == "number-up" }?.intValue == 1)
        #expect(attributes.first { $0.name == "orientation-requested" } == nil)
        #expect(attributes.first { $0.name == "number-up-layout" } == nil)
        #expect(attributes.first { $0.name == "print-scaling" }?.stringValue == "none")
    }

    @Test("page-ranges is never emitted even when settings have a page range")
    func pageRangesNeverEmitted() {
        var ranged = PrintSettings()
        ranged.pageRange = .range(from: 2, to: 5)
        let (rangedAttrs, rangedUnsupported) = JobAttributesBuilder.attributes(for: ranged)
        #expect(rangedAttrs.first { $0.name == "page-ranges" } == nil)
        #expect(!rangedUnsupported.contains("page-ranges"))

        var selected = PrintSettings()
        selected.pageRange = .selection([1, 3, 5])
        let capabilities = PrinterCapabilities(attributes: [
            IPPAttribute(name: "page-ranges-supported", values: [.boolean(false)])
        ])
        let (selectedAttrs, selectedUnsupported) = JobAttributesBuilder.attributes(
            for: selected,
            capabilities: capabilities
        )
        #expect(selectedAttrs.first { $0.name == "page-ranges" } == nil)
        #expect(!selectedUnsupported.contains("page-ranges"))
    }
}

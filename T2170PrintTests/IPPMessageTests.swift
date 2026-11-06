import Foundation
import Testing
@testable import T2170Print

@Suite("IPPMessage Wire Encoder and Decoder Tests")
struct IPPMessageTests {
    @Test("Encode Get-Printer-Attributes request header and leading bytes")
    func encodeGetPrinterAttributesLeadingBytes() throws {
        let message = IPPMessage(
            version: (2, 0),
            operation: .getPrinterAttributes,
            requestID: 0x0000_002A,
            groups: [
                (
                    tag: .operationAttributes,
                    attributes: [
                        .charset("attributes-charset", "utf-8"),
                        .naturalLanguage("attributes-natural-language", "en"),
                        .uri("printer-uri", "ipp://192.168.1.50:631/ipp/print")
                    ]
                )
            ]
        )

        let wire = try message.encode()
        #expect(wire.count > 8)

        let headerBytes = Array(wire.prefix(9))
        // Version 2.0 (0x02, 0x00), op 0x000B (0x00, 0x0B), requestID 42 (0x00, 0x00, 0x00, 0x2A), operation group tag (0x01)
        #expect(headerBytes == [0x02, 0x00, 0x00, 0x0B, 0x00, 0x00, 0x00, 0x2A, 0x01])
        #expect(wire.last == IPPTag.endOfAttributes.rawValue)
    }

    @Test("Round-trip complex IPPMessage with primitives, multi-valued keywords, and nested media-col collection")
    func roundTripComplexMessage() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let fixedDate = calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: .gmt,
                year: 2026,
                month: 11,
                day: 5,
                hour: 22,
                minute: 0,
                second: 0,
                nanosecond: 0
            )
        ) ?? Date(timeIntervalSince1970: 1_700_000_000)

        let mediaSize = IPPCollection([
            (name: "x-dimension", values: [.integer(21000)]),
            (name: "y-dimension", values: [.integer(29700)])
        ])
        let mediaCol = IPPCollection([
            (name: "media-size", values: [.collection(mediaSize)]),
            (name: "media-source", values: [.keyword("roll-1")]),
            (name: "media-type", values: [.keyword("stationery")])
        ])

        let original = IPPMessage(
            version: (2, 0),
            operation: .printJob,
            requestID: 7,
            groups: [
                (
                    tag: .operationAttributes,
                    attributes: [
                        .charset("attributes-charset", "utf-8"),
                        .naturalLanguage("attributes-natural-language", "en"),
                        .uri("printer-uri", "ipp://epson.local:631/ipp/print")
                    ]
                ),
                (
                    tag: .jobAttributes,
                    attributes: [
                        IPPAttribute(name: "copies", value: .integer(2)),
                        IPPAttribute(name: "ipp-attribute-fidelity", value: .boolean(true)),
                        IPPAttribute(name: "print-color-mode", value: .keyword("color")),
                        IPPAttribute(name: "page-ranges", value: .range(1...5)),
                        IPPAttribute(name: "printer-resolution", value: .resolution(x: 600, y: 600, units: 3)),
                        IPPAttribute(name: "date-time-at-creation", value: .dateTime(fixedDate)),
                        IPPAttribute(
                            name: "media-supported",
                            values: [
                                .keyword("iso_a4_210x297mm"),
                                .keyword("iso_a3_297x420mm"),
                                .keyword("na_arch-d_24x36in")
                            ]
                        ),
                        IPPAttribute(name: "media-col", value: .collection(mediaCol))
                    ]
                )
            ],
            data: Data([0x25, 0x50, 0x44, 0x46]) // "%PDF"
        )

        let encoded = try original.encode()
        let decoded = try IPPMessage.decode(encoded)

        #expect(decoded.version.0 == 2)
        #expect(decoded.version.1 == 0)
        #expect(decoded.operationOrStatus == IPPOperation.printJob.rawValue)
        #expect(decoded.requestID == 7)
        #expect(decoded.data == Data([0x25, 0x50, 0x44, 0x46]))
        #expect(decoded.groups.count == 2)

        #expect(decoded.attribute(named: "copies")?.int32Value == 2)
        #expect(decoded.attribute(named: "ipp-attribute-fidelity")?.boolValue == true)
        #expect(decoded.attribute(named: "print-color-mode")?.stringValue == "color")
        #expect(decoded.attribute(named: "printer-uri")?.stringValue == "ipp://epson.local:631/ipp/print")
        #expect(decoded.attribute(named: "page-ranges")?.rangeValue == (1...5))

        let resolution = decoded.attribute(named: "printer-resolution")?.resolutions.first
        #expect(resolution?.x == 600)
        #expect(resolution?.y == 600)
        #expect(resolution?.units == 3)

        #expect(decoded.attribute(named: "date-time-at-creation")?.dateValue == fixedDate)
        #expect(
            decoded.attribute(named: "media-supported")?.keywords == [
                "iso_a4_210x297mm",
                "iso_a3_297x420mm",
                "na_arch-d_24x36in"
            ]
        )

        let decodedMediaCol = decoded.attribute(named: "media-col")?.collectionValue
        #expect(decodedMediaCol != nil)
        #expect(decodedMediaCol?.firstValue(for: "media-source")?.stringValue == "roll-1")
        #expect(decodedMediaCol?.firstValue(for: "media-type")?.stringValue == "stationery")

        let decodedMediaSize = decodedMediaCol?.firstValue(for: "media-size")?.collectionValue
        #expect(decodedMediaSize?.firstValue(for: "x-dimension")?.int32Value == 21000)
        #expect(decodedMediaSize?.firstValue(for: "y-dimension")?.int32Value == 29700)
    }

    @Test("Decode a hand-built response with status 0x0000 and printer-attributes group")
    func decodeHandBuiltResponse() throws {
        var raw = Data()
        // Header: version 2.0, status 0x0000 (successful-ok), request-id 1
        raw.append(contentsOf: [0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])

        // Operation attributes group (0x01)
        raw.append(0x01)
        // charset "attributes-charset" = "utf-8"
        raw.append(0x47)
        let charsetName = Array("attributes-charset".utf8)
        raw.append(contentsOf: [0x00, UInt8(charsetName.count)])
        raw.append(contentsOf: charsetName)
        let charsetVal = Array("utf-8".utf8)
        raw.append(contentsOf: [0x00, UInt8(charsetVal.count)])
        raw.append(contentsOf: charsetVal)

        // Printer attributes group (0x04)
        raw.append(0x04)
        // nameWithoutLanguage (0x42) "printer-name" = "Epson-T2170"
        raw.append(0x42)
        let nameKey = Array("printer-name".utf8)
        raw.append(contentsOf: [0x00, UInt8(nameKey.count)])
        raw.append(contentsOf: nameKey)
        let nameVal = Array("Epson-T2170".utf8)
        raw.append(contentsOf: [0x00, UInt8(nameVal.count)])
        raw.append(contentsOf: nameVal)

        // enum (0x23) "printer-state" = 3 (idle)
        raw.append(0x23)
        let stateKey = Array("printer-state".utf8)
        raw.append(contentsOf: [0x00, UInt8(stateKey.count)])
        raw.append(contentsOf: stateKey)
        raw.append(contentsOf: [0x00, 0x04, 0x00, 0x00, 0x00, 0x03])

        // End of attributes (0x03)
        raw.append(0x03)

        let decoded = try IPPMessage.decode(raw)
        #expect(decoded.version.0 == 2)
        #expect(decoded.version.1 == 0)
        #expect(decoded.operationOrStatus == IPPStatus.successfulOk.rawValue)
        #expect(decoded.requestID == 1)

        let printerAttrs = decoded.attributes(in: .printerAttributes)
        #expect(printerAttrs.count == 2)
        #expect(decoded.attribute(named: "printer-name", in: .printerAttributes)?.stringValue == "Epson-T2170")
        #expect(decoded.attribute(named: "printer-state", in: .printerAttributes)?.intValue == 3)
    }

    /// One integer of the wrong length used to fail the whole response.
    @Test("A value of the wrong length stays opaque and the rest still decodes")
    func wrongLengthValueStaysOpaque() throws {
        var data = Data([0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x04])
        data.append(contentsOf: [0x21, 0x00, 0x03])
        data.append(contentsOf: Array("odd".utf8))
        data.append(contentsOf: [0x00, 0x02, 0x01, 0x02])
        data.append(contentsOf: [0x21, 0x00, 0x04])
        data.append(contentsOf: Array("good".utf8))
        data.append(contentsOf: [0x00, 0x04, 0x00, 0x00, 0x00, 0x07])
        data.append(0x03)
        let message = try IPPMessage.decode(data)
        let attributes = message.groups.flatMap(\.attributes)
        #expect(attributes.first { $0.name == "good" }?.values == [.integer(7)])
        #expect(attributes.first { $0.name == "odd" }?.values == [.octetString(Data([1, 2]))])
    }

    @Test("Decoding a response missing the end-of-attributes tag throws truncated")
    func decodeWithoutEndOfAttributesThrows() throws {
        let message = IPPMessage(
            operationOrStatus: IPPStatus.successfulOk.rawValue,
            requestID: 1,
            groups: [
                (tag: .operationAttributes, attributes: [.charset("attributes-charset", "utf-8")])
            ]
        )
        var wire = try message.encode()
        #expect(wire.last == IPPTag.endOfAttributes.rawValue)
        wire.removeLast()

        #expect(throws: IPPDecodeError.truncated) {
            try IPPMessage.decode(wire)
        }
    }

    @Test("Encoding a value longer than 65535 bytes throws")
    func encodeOversizedValueThrows() {
        let message = IPPMessage(
            operation: .printJob,
            groups: [
                (tag: .operationAttributes, attributes: [.name("job-name", String(repeating: "a", count: 70_000))])
            ]
        )
        #expect(throws: IPPEncodeError.self) {
            try message.encode()
        }
    }
}

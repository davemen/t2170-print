import Foundation

/// A Get-Printer-Attributes response read straight from the wire. `IPPMessage.decode` keeps what
/// printing needs and throws on a bad record; this keeps everything: value tags, languages, duplicate
/// names, wire order, unknown tags, and whatever came before a fault.
struct IPPWireDump {
    struct Value: Equatable {
        var tag: UInt8
        var text: String
    }

    struct Attribute: Equatable {
        var name: String
        var values: [Value]

        /// `1setOf keyword`, in the style of `ipptool -v`.
        var typeDescription: String {
            var names: [String] = []
            for value in values {
                let name = IPPWireDump.tagName(value.tag)
                if !names.contains(name) { names.append(name) }
            }
            let joined = names.joined(separator: "|")
            return values.count > 1 ? "1setOf \(joined)" : joined
        }

        var line: String {
            "\(name) (\(typeDescription)) = \(values.map(\.text).joined(separator: ","))"
        }
    }

    struct Group: Equatable {
        var tag: UInt8
        var attributes: [Attribute] = []
    }

    struct Fault: Equatable, Error {
        var offset: Int
        var reason: String
    }

    var version: (major: UInt8, minor: UInt8)?
    var status: UInt16?
    var requestID: UInt32?
    var groups: [Group] = []
    var fault: Fault?
    var sawEnd = false
    var trailingBytes = 0

    /// Every attribute name in the printer groups, with no repeats.
    var printerAttributeNames: Set<String> {
        var names = Set<String>()
        for group in groups where group.tag == 0x04 {
            names.formUnion(group.attributes.map(\.name))
        }
        return names
    }

    init(_ data: Data) {
        var reader = Reader(bytes: [UInt8](data))
        guard reader.bytes.count >= 8 else {
            fault = Fault(offset: 0, reason: "only \(reader.bytes.count) bytes, an IPP header needs 8")
            return
        }
        version = (reader.bytes[0], reader.bytes[1])
        status = UInt16(reader.bytes[2]) << 8 | UInt16(reader.bytes[3])
        requestID = reader.bytes[4...7].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        reader.offset = 8

        do {
            while true {
                guard let tag = reader.peek else {
                    throw Fault(offset: reader.offset, reason: "ended without an end-of-attributes tag")
                }
                if tag == 0x03 {
                    sawEnd = true
                    trailingBytes = reader.bytes.count - reader.offset - 1
                    return
                }
                if tag <= 0x0F {
                    reader.offset += 1
                    groups.append(Group(tag: tag))
                    continue
                }
                guard !groups.isEmpty else {
                    throw Fault(offset: reader.offset, reason: "value tag 0x\(Self.hex(tag)) before any group")
                }
                try readAttributeRecord(&reader)
            }
        } catch let error as Fault {
            fault = error
        } catch {
            fault = Fault(offset: reader.offset, reason: String(describing: error))
        }
    }

    private mutating func readAttributeRecord(_ reader: inout Reader) throws {
        let record = try reader.record()
        let value = try Self.value(of: record, reader: &reader, depth: 0)
        let last = groups.count - 1
        if record.name.isEmpty {
            if groups[last].attributes.isEmpty {
                groups[last].attributes.append(Attribute(name: "(value with no attribute name)", values: [value]))
            } else {
                groups[last].attributes[groups[last].attributes.count - 1].values.append(value)
            }
        } else {
            groups[last].attributes.append(Attribute(name: record.name, values: [value]))
        }
    }

    /// A collection reads on past its own record, which is why this takes the reader.
    private static func value(of record: Record, reader: inout Reader, depth: Int) throws -> Value {
        guard record.tag == 0x34 else {
            return Value(tag: record.tag, text: text(tag: record.tag, value: record.value))
        }
        guard depth < 16 else {
            throw Fault(offset: record.offset, reason: "collections nested more than 16 deep")
        }
        var members: [String] = []
        var memberName: String?
        var memberValues: [String] = []

        func finishMember() {
            guard let memberName else { return }
            members.append("\(memberName)=\(memberValues.joined(separator: ","))")
        }

        while true {
            guard reader.peek != nil else {
                throw Fault(offset: reader.offset, reason: "ended inside a collection")
            }
            let member = try reader.record()
            switch member.tag {
            case 0x37:
                finishMember()
                return Value(tag: 0x34, text: "{\(members.joined(separator: " "))}")
            case 0x4A:
                finishMember()
                memberName = String(decoding: member.value, as: UTF8.self)
                memberValues = []
            default:
                guard memberName != nil else {
                    throw Fault(offset: member.offset, reason: "collection value before a member name")
                }
                memberValues.append(try value(of: member, reader: &reader, depth: depth + 1).text)
            }
        }
    }

    // MARK: - Values

    static func text(tag: UInt8, value: [UInt8]) -> String {
        func wrongLength() -> String { "<wrong length \(value.count) hex=\(hex(value))>" }
        func int32(_ at: Int) -> Int32 {
            Int32(bitPattern: value[at..<(at + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        }

        switch tag {
        case 0x10...0x17:
            return value.isEmpty ? tagName(tag) : "\(tagName(tag)) hex=\(hex(value))"
        case 0x21, 0x23:
            return value.count == 4 ? String(int32(0)) : wrongLength()
        case 0x22:
            return value.count == 1 ? (value[0] == 0 ? "false" : "true") : wrongLength()
        case 0x30:
            return octets(value)
        case 0x31:
            return value.count == 11 ? dateTime(value) : wrongLength()
        case 0x32:
            guard value.count == 9 else { return wrongLength() }
            let units = value[8] == 3 ? "dpi" : value[8] == 4 ? "dpcm" : " units=\(value[8])"
            return "\(int32(0))x\(int32(4))\(units)"
        case 0x33:
            return value.count == 8 ? "\(int32(0))-\(int32(4))" : wrongLength()
        case 0x35, 0x36:
            return withLanguage(value) ?? wrongLength()
        case 0x41...0x49:
            return String(bytes: value, encoding: .utf8) ?? "<not UTF-8 hex=\(hex(value))>"
        default:
            return "tag 0x\(hex(tag)) hex=\(hex(value))"
        }
    }

    private static func octets(_ value: [UInt8]) -> String {
        if !value.isEmpty, value.allSatisfy({ (0x20...0x7E).contains($0) }) {
            return "\"\(String(decoding: value, as: UTF8.self))\""
        }
        return "hex=\(hex(value))"
    }

    private static func dateTime(_ v: [UInt8]) -> String {
        let year = Int(v[0]) << 8 | Int(v[1])
        func two(_ n: UInt8) -> String { n < 10 ? "0\(n)" : "\(n)" }
        let sign = String(UnicodeScalar(v[8]))
        return "\(year)-\(two(v[2]))-\(two(v[3]))T\(two(v[4])):\(two(v[5])):\(two(v[6])).\(v[7])\(sign)\(two(v[9]))\(two(v[10]))"
    }

    /// textWithLanguage and nameWithLanguage: a language and a string, each with its own length.
    private static func withLanguage(_ value: [UInt8]) -> String? {
        guard value.count >= 2 else { return nil }
        let languageLength = Int(value[0]) << 8 | Int(value[1])
        let textLengthAt = 2 + languageLength
        guard value.count >= textLengthAt + 2 else { return nil }
        let textLength = Int(value[textLengthAt]) << 8 | Int(value[textLengthAt + 1])
        guard value.count == textLengthAt + 2 + textLength else { return nil }
        let language = String(decoding: value[2..<textLengthAt], as: UTF8.self)
        let text = String(decoding: value[(textLengthAt + 2)...], as: UTF8.self)
        return "\(text) [language=\(language)]"
    }

    static func hex(_ byte: UInt8) -> String {
        let digits = String(byte, radix: 16)
        return byte < 16 ? "0\(digits)" : digits
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { hex($0) }.joined()
    }

    static func tagName(_ tag: UInt8) -> String {
        switch tag {
        case 0x10: "unsupported"
        case 0x11: "default"
        case 0x12: "unknown"
        case 0x13: "no-value"
        case 0x15: "not-settable"
        case 0x16: "delete-attribute"
        case 0x17: "admin-define"
        case 0x21: "integer"
        case 0x22: "boolean"
        case 0x23: "enum"
        case 0x30: "octetString"
        case 0x31: "dateTime"
        case 0x32: "resolution"
        case 0x33: "rangeOfInteger"
        case 0x34: "collection"
        case 0x35: "textWithLanguage"
        case 0x36: "nameWithLanguage"
        case 0x41: "textWithoutLanguage"
        case 0x42: "nameWithoutLanguage"
        case 0x44: "keyword"
        case 0x45: "uri"
        case 0x46: "uriScheme"
        case 0x47: "charset"
        case 0x48: "naturalLanguage"
        case 0x49: "mimeMediaType"
        default: "tag-0x\(hex(tag))"
        }
    }

    static func groupName(_ tag: UInt8) -> String {
        switch tag {
        case 0x01: "operation-attributes-tag"
        case 0x02: "job-attributes-tag"
        case 0x04: "printer-attributes-tag"
        case 0x05: "unsupported-attributes-tag"
        case 0x0A: "system-attributes-tag"
        default: "group-0x\(hex(tag))"
        }
    }

    // MARK: - Reader

    private struct Record {
        var offset: Int
        var tag: UInt8
        var name: String
        var value: [UInt8]
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        var peek: UInt8? { offset < bytes.count ? bytes[offset] : nil }

        /// Reads tag, name and value. Leaves the offset on the record's first byte if it is cut short.
        mutating func record() throws -> Record {
            let start = offset
            var at = offset + 1
            func length() throws -> Int {
                guard at + 2 <= bytes.count else {
                    throw Fault(offset: start, reason: "record cut short in a length field")
                }
                return Int(bytes[at]) << 8 | Int(bytes[at + 1])
            }
            let nameLength = try length()
            at += 2
            guard at + nameLength <= bytes.count else {
                throw Fault(offset: start, reason: "name of \(nameLength) bytes runs past the end")
            }
            let name = String(decoding: bytes[at..<(at + nameLength)], as: UTF8.self)
            at += nameLength
            let valueLength = try length()
            at += 2
            guard at + valueLength <= bytes.count else {
                throw Fault(offset: start, reason: "value of \(valueLength) bytes runs past the end")
            }
            let value = Array(bytes[at..<(at + valueLength)])
            offset = at + valueLength
            return Record(offset: start, tag: bytes[start], name: name, value: value)
        }
    }
}

/// Everything the printer told us, as one text file a person can send back. The readable part is a
/// convenience; the base64 under each request is the exact reply, so a bug in this file can't lose data.
struct IPPAttributeReport: Sendable {
    /// Where the capture came from, for the header.
    struct Context: Sendable {
        var appVersion: String
        var printerURI: String
        var endpoint: String
        /// How the printer was found: Bonjour fields and TXT record lines, if any.
        var discovery: [String] = []
        var date = Date()
    }

    let context: Context
    let responses: [IPPRawResponse]

    /// Separate requests, so a refusal of one loses only that one: the list the app uses,
    /// a plain request, then `media-col-database` alone when the first reply left it out. Stops after
    /// a connection failure, since each further try would wait out the same timeout.
    static func capture(from client: IPPClient) async -> [IPPRawResponse] {
        let first = await client.rawPrinterAttributes(requested: PrinterCapabilities.requestedAttributes)
        guard first.transportError == nil else { return [first] }
        var responses = [first]
        responses.append(await client.rawPrinterAttributes())
        if !IPPWireDump(first.body).printerAttributeNames.contains("media-col-database") {
            responses.append(await client.rawPrinterAttributes(requested: ["media-col-database"]))
        }
        return responses
    }

    /// Distinct printer attributes across all the replies.
    var attributeCount: Int {
        responses.reduce(into: Set<String>()) { $0.formUnion(IPPWireDump($1.body).printerAttributeNames) }.count
    }

    var text: String {
        var lines = [
            "T2170 Print attribute report",
            "App: \(context.appVersion)",
            "Captured: \(ISO8601DateFormatter().string(from: context.date))",
            "Printer URI: \(context.printerURI)",
            "Endpoint: \(context.endpoint)",
            "Printer attributes found: \(attributeCount)",
        ]
        if !context.discovery.isEmpty {
            lines.append("")
            lines.append("Bonjour:")
            lines += context.discovery.map { "  \($0)" }
        }
        for (index, response) in responses.enumerated() {
            lines.append("")
            lines += Self.section(response, number: index + 1, of: responses.count)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func section(_ response: IPPRawResponse, number: Int, of total: Int) -> [String] {
        let asked = response.requested.map { "requested-attributes = \($0.joined(separator: ","))" }
            ?? "no requested-attributes"
        var lines = ["=== Request \(number) of \(total): \(asked) ==="]
        lines.append("Sent as IPP \(response.versionSent), took \(String(format: "%.2f", response.elapsed)) s")
        if let error = response.transportError {
            lines.append("Transport error: \(error)")
            return lines
        }
        let http = response.httpStatus.map(String.init) ?? "none"
        lines.append("HTTP \(http), Content-Type \(response.contentType ?? "(none)"), \(response.body.count) bytes")

        if let first = response.body.first, first == 1 || first == 2 {
            lines += dumpLines(IPPWireDump(response.body))
        } else if response.body.isEmpty {
            lines.append("[empty body]")
        } else {
            lines.append("[body is not IPP]")
            lines.append(String(decoding: response.body.prefix(2000), as: UTF8.self))
        }

        if !response.body.isEmpty {
            lines.append("--- raw response, base64, \(response.body.count) bytes ---")
            lines.append(response.body.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]))
            lines.append("--- end raw response ---")
        }
        return lines
    }

    private static func dumpLines(_ dump: IPPWireDump) -> [String] {
        var lines: [String] = []
        if let version = dump.version, let status = dump.status, let requestID = dump.requestID {
            let code = String(status, radix: 16)
            let padded = String(repeating: "0", count: max(0, 4 - code.count)) + code
            lines.append("IPP reply: version \(version.major).\(version.minor), status 0x\(padded), request-id \(requestID)")
        }
        for group in dump.groups {
            lines.append("GROUP \(IPPWireDump.groupName(group.tag))")
            lines += group.attributes.map(\.line)
        }
        if let fault = dump.fault {
            lines.append("[stopped at byte \(fault.offset): \(fault.reason)]")
        } else if dump.trailingBytes > 0 {
            lines.append("[\(dump.trailingBytes) bytes after end-of-attributes]")
        }
        return lines
    }
}

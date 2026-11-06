import Foundation

/// IPP delimiter (group) tags and value tags as defined in RFC 8010 Section 3.5.
enum IPPTag: UInt8, Sendable, Hashable, Codable {
    // MARK: - Delimiter Tags (0x01...0x0F)
    case operationAttributes = 0x01
    case jobAttributes = 0x02
    case endOfAttributes = 0x03
    case printerAttributes = 0x04
    case unsupportedAttributes = 0x05
    case subscriptionAttributes = 0x06
    case eventNotificationAttributes = 0x07
    case resourceAttributes = 0x08
    case documentAttributes = 0x09
    case systemAttributes = 0x0A

    // MARK: - Out-of-Band Value Tags (0x10...0x13)
    case unsupported = 0x10
    case defaultValue = 0x11
    case unknown = 0x12
    case noValue = 0x13

    // MARK: - Integer & Boolean Value Tags (0x20...0x2F)
    case integer = 0x21
    case boolean = 0x22
    case `enum` = 0x23

    // MARK: - Octet-String & Structured Value Tags (0x30...0x3F)
    case octetString = 0x30
    case dateTime = 0x31
    case resolution = 0x32
    case rangeOfInteger = 0x33
    case begCollection = 0x34
    case textWithLanguage = 0x35
    case nameWithLanguage = 0x36
    case endCollection = 0x37

    // MARK: - Character-String Value Tags (0x40...0x4F)
    case textWithoutLanguage = 0x41
    case nameWithoutLanguage = 0x42
    case keyword = 0x44
    case uri = 0x45
    case uriScheme = 0x46
    case charset = 0x47
    case naturalLanguage = 0x48
    case mimeMediaType = 0x49
    case memberAttrName = 0x4A

    /// Alias for `.enum` tag (`0x23`).
    static let enumValue: IPPTag = .enum
    /// Alias for `.operationAttributes` tag (`0x01`).
    static let operation: IPPTag = .operationAttributes
    /// Alias for `.jobAttributes` tag (`0x02`).
    static let job: IPPTag = .jobAttributes
    /// Alias for `.printerAttributes` tag (`0x04`).
    static let printer: IPPTag = .printerAttributes

    /// Returns `true` if this tag is a group/section delimiter (`0x01...0x0F`).
    var isDelimiter: Bool {
        rawValue >= 0x01 && rawValue <= 0x0F
    }
}

/// Standard IPP operation codes (RFC 8011 / PWG 5100.13).
enum IPPOperation: UInt16, Sendable, Hashable, Codable {
    case printJob = 0x0002
    case validateJob = 0x0004
    case createJob = 0x0005
    case sendDocument = 0x0006
    case cancelJob = 0x0008
    case getJobAttributes = 0x0009
    case getJobs = 0x000A
    case getPrinterAttributes = 0x000B
    case identifyPrinter = 0x003C
}

/// Standard IPP response status codes (RFC 8011 Section 4.1.8).
enum IPPStatus: UInt16, Sendable, Hashable, Codable, CustomStringConvertible {
    // MARK: - Successful (0x0000...0x0007)
    case successfulOk = 0x0000
    case successfulOkIgnoredOrSubstitutedAttributes = 0x0001
    case successfulOkConflictingAttributes = 0x0002
    case successfulOkIgnoredSubscriptions = 0x0003
    case successfulOkIgnoredNotifications = 0x0004
    case successfulOkTooManyEvents = 0x0005
    case successfulOkButCancelSubscription = 0x0006
    case successfulOkEventsComplete = 0x0007

    // MARK: - Client Error (0x0400...0x0415)
    case clientErrorBadRequest = 0x0400
    case clientErrorForbidden = 0x0401
    case clientErrorNotAuthenticated = 0x0402
    case clientErrorNotAuthorized = 0x0403
    case clientErrorNotPossible = 0x0404
    case clientErrorTimeout = 0x0405
    case clientErrorNotFound = 0x0406
    case clientErrorGone = 0x0407
    case clientErrorRequestEntityTooLarge = 0x0408
    case clientErrorRequestValueTooLong = 0x0409
    case clientErrorDocumentFormatNotSupported = 0x040A
    case clientErrorAttributesOrValuesNotSupported = 0x040B
    case clientErrorUriSchemeNotSupported = 0x040C
    case clientErrorCharsetNotSupported = 0x040D
    case clientErrorConflictingAttributes = 0x040E
    case clientErrorCompressionNotSupported = 0x040F
    case clientErrorCompressionError = 0x0410
    case clientErrorDocumentFormatError = 0x0411
    case clientErrorDocumentAccessError = 0x0412
    case clientErrorAttributesNotSettable = 0x0413
    case clientErrorIgnoredAllSubscriptions = 0x0414
    case clientErrorTooManySubscriptions = 0x0415

    // MARK: - Server Error (0x0500...0x050A)
    case serverErrorInternalError = 0x0500
    case serverErrorOperationNotSupported = 0x0501
    case serverErrorServiceUnavailable = 0x0502
    case serverErrorVersionNotSupported = 0x0503
    case serverErrorDeviceError = 0x0504
    case serverErrorTemporaryError = 0x0505
    case serverErrorNotAcceptingJobs = 0x0506
    case serverErrorBusy = 0x0507
    case serverErrorJobCanceled = 0x0508
    case serverErrorMultipleDocumentJobsNotSupported = 0x0509
    case serverErrorPrinterIsDeactivated = 0x050A

    /// Whether this status indicates success (`< 0x0400`).
    var isSuccess: Bool {
        rawValue < 0x0400
    }

    /// Human-readable RFC 8011 status description.
    var description: String {
        switch self {
        case .successfulOk: "successful-ok"
        case .successfulOkIgnoredOrSubstitutedAttributes: "successful-ok-ignored-or-substituted-attributes"
        case .successfulOkConflictingAttributes: "successful-ok-conflicting-attributes"
        case .successfulOkIgnoredSubscriptions: "successful-ok-ignored-subscriptions"
        case .successfulOkIgnoredNotifications: "successful-ok-ignored-notifications"
        case .successfulOkTooManyEvents: "successful-ok-too-many-events"
        case .successfulOkButCancelSubscription: "successful-ok-but-cancel-subscription"
        case .successfulOkEventsComplete: "successful-ok-events-complete"
        case .clientErrorBadRequest: "client-error-bad-request"
        case .clientErrorForbidden: "client-error-forbidden"
        case .clientErrorNotAuthenticated: "client-error-not-authenticated"
        case .clientErrorNotAuthorized: "client-error-not-authorized"
        case .clientErrorNotPossible: "client-error-not-possible"
        case .clientErrorTimeout: "client-error-timeout"
        case .clientErrorNotFound: "client-error-not-found"
        case .clientErrorGone: "client-error-gone"
        case .clientErrorRequestEntityTooLarge: "client-error-request-entity-too-large"
        case .clientErrorRequestValueTooLong: "client-error-request-value-too-long"
        case .clientErrorDocumentFormatNotSupported: "client-error-document-format-not-supported"
        case .clientErrorAttributesOrValuesNotSupported: "client-error-attributes-or-values-not-supported"
        case .clientErrorUriSchemeNotSupported: "client-error-uri-scheme-not-supported"
        case .clientErrorCharsetNotSupported: "client-error-charset-not-supported"
        case .clientErrorConflictingAttributes: "client-error-conflicting-attributes"
        case .clientErrorCompressionNotSupported: "client-error-compression-not-supported"
        case .clientErrorCompressionError: "client-error-compression-error"
        case .clientErrorDocumentFormatError: "client-error-document-format-error"
        case .clientErrorDocumentAccessError: "client-error-document-access-error"
        case .clientErrorAttributesNotSettable: "client-error-attributes-not-settable"
        case .clientErrorIgnoredAllSubscriptions: "client-error-ignored-all-subscriptions"
        case .clientErrorTooManySubscriptions: "client-error-too-many-subscriptions"
        case .serverErrorInternalError: "server-error-internal-error"
        case .serverErrorOperationNotSupported: "server-error-operation-not-supported"
        case .serverErrorServiceUnavailable: "server-error-service-unavailable"
        case .serverErrorVersionNotSupported: "server-error-version-not-supported"
        case .serverErrorDeviceError: "server-error-device-error"
        case .serverErrorTemporaryError: "server-error-temporary-error"
        case .serverErrorNotAcceptingJobs: "server-error-not-accepting-jobs"
        case .serverErrorBusy: "server-error-busy"
        case .serverErrorJobCanceled: "server-error-job-canceled"
        case .serverErrorMultipleDocumentJobsNotSupported: "server-error-multiple-document-jobs-not-supported"
        case .serverErrorPrinterIsDeactivated: "server-error-printer-is-deactivated"
        }
    }

    /// Formats any raw 16-bit IPP status code into a human-readable string.
    static func description(for rawCode: UInt16) -> String {
        if let known = IPPStatus(rawValue: rawCode) {
            return known.description
        }
        if rawCode < 0x0400 {
            return String(format: "successful-0x%04x", rawCode)
        } else if rawCode < 0x0500 {
            return String(format: "client-error-0x%04x", rawCode)
        } else {
            return String(format: "server-error-0x%04x", rawCode)
        }
    }
}

/// Ordered IPP collection (`begCollection` ... `endCollection`) storing `(name, [IPPValue])` pairs.
struct IPPCollection: Hashable, Sendable, ExpressibleByDictionaryLiteral {
    /// A single named member entry inside an `IPPCollection`.
    struct Member: Hashable, Sendable {
        var name: String
        var values: [IPPValue]

        init(name: String, values: [IPPValue]) {
            self.name = name
            self.values = values
        }

        init(name: String, value: IPPValue) {
            self.name = name
            self.values = [value]
        }
    }

    /// Ordered member pairs.
    var members: [Member]

    /// Creates a collection from ordered `Member` entries.
    init(members: [Member] = []) {
        self.members = members
    }

    /// Creates a collection from an ordered array of `(name, [IPPValue])` tuples.
    init(_ pairs: [(name: String, values: [IPPValue])]) {
        self.members = pairs.map { Member(name: $0.name, values: $0.values) }
    }

    /// Creates a collection from an ordered array of `(String, IPPValue)` tuples.
    init(_ pairs: [(String, IPPValue)]) {
        self.members = pairs.map { Member(name: $0.0, values: [$0.1]) }
    }

    /// Creates a collection from an array of `IPPAttribute` values.
    init(_ attributes: [IPPAttribute]) {
        self.members = attributes.map { Member(name: $0.name, values: $0.values) }
    }

    /// Creates a collection from a dictionary (keys sorted alphabetically for deterministic order).
    init(_ dictionary: [String: [IPPValue]]) {
        self.members = dictionary.keys.sorted().compactMap { key in
            dictionary[key].map { Member(name: key, values: $0) }
        }
    }

    init(dictionaryLiteral elements: (String, [IPPValue])...) {
        self.members = elements.map { Member(name: $0.0, values: $0.1) }
    }

    /// Accesses the values for the first member with the given name.
    subscript(name: String) -> [IPPValue]? {
        get {
            members.first(where: { $0.name == name })?.values
        }
        set {
            if let index = members.firstIndex(where: { $0.name == name }) {
                if let newValue {
                    members[index].values = newValue
                } else {
                    members.remove(at: index)
                }
            } else if let newValue {
                members.append(Member(name: name, values: newValue))
            }
        }
    }

    /// Returns the first `IPPValue` for the given member name.
    func firstValue(for name: String) -> IPPValue? {
        self[name]?.first
    }

    /// Converts members to `[IPPAttribute]`.
    var attributes: [IPPAttribute] {
        members.map { IPPAttribute(name: $0.name, values: $0.values) }
    }
}

/// Typed IPP attribute value (RFC 8010).
enum IPPValue: Hashable, Sendable {
    case integer(Int32)
    case boolean(Bool)
    case enumValue(Int32)
    case octetString(Data)
    case dateTime(Date)
    case resolution(x: Int32, y: Int32, units: Int8)
    case range(ClosedRange<Int32>)
    case collection(IPPCollection)
    case text(String)
    case name(String)
    case keyword(String)
    case uri(String)
    case uriScheme(String)
    case charset(String)
    case naturalLanguage(String)
    case mimeType(String)
    case unknown
    case noValue
    case unsupported

    /// Convenience factory for building a collection from ordered `(name, [IPPValue])` pairs.
    static func collection(_ pairs: [(name: String, values: [IPPValue])]) -> IPPValue {
        .collection(IPPCollection(pairs))
    }

    /// Convenience factory for building a collection from a dictionary.
    static func collection(_ dictionary: [String: [IPPValue]]) -> IPPValue {
        .collection(IPPCollection(dictionary))
    }

    /// Extracts the underlying string if this value is any text/name/keyword/URI/charset/language/MIME variant.
    var stringValue: String? {
        switch self {
        case .text(let s),
             .name(let s),
             .keyword(let s),
             .uri(let s),
             .uriScheme(let s),
             .charset(let s),
             .naturalLanguage(let s),
             .mimeType(let s):
            return s
        default:
            return nil
        }
    }

    /// Extracts an `Int` if this value is `.integer` or `.enumValue`.
    var intValue: Int? {
        switch self {
        case .integer(let v), .enumValue(let v):
            return Int(v)
        default:
            return nil
        }
    }

    /// Extracts an `Int32` if this value is `.integer` or `.enumValue`.
    var int32Value: Int32? {
        switch self {
        case .integer(let v), .enumValue(let v):
            return v
        default:
            return nil
        }
    }

    /// Extracts a `Bool` if this value is `.boolean`.
    var boolValue: Bool? {
        if case .boolean(let b) = self { return b }
        return nil
    }

    /// Extracts a `ClosedRange<Int32>` if this value is `.range`.
    var rangeValue: ClosedRange<Int32>? {
        if case .range(let r) = self { return r }
        return nil
    }

    /// Extracts resolution components if this value is `.resolution`.
    var resolutionValue: (x: Int32, y: Int32, units: Int8)? {
        if case .resolution(let x, let y, let units) = self {
            return (x, y, units)
        }
        return nil
    }

    /// Extracts an `IPPCollection` if this value is `.collection`.
    var collectionValue: IPPCollection? {
        if case .collection(let c) = self { return c }
        return nil
    }

    /// Extracts `Data` if this value is `.octetString`.
    var dataValue: Data? {
        if case .octetString(let d) = self { return d }
        return nil
    }

    /// Extracts `Date` if this value is `.dateTime`.
    var dateValue: Date? {
        if case .dateTime(let d) = self { return d }
        return nil
    }

    /// Human-readable representation used for capability dumps and debugging.
    var displayString: String {
        switch self {
        case .integer(let v):
            return "\(v)"
        case .boolean(let b):
            return b ? "true" : "false"
        case .enumValue(let v):
            return "\(v)"
        case .octetString(let d):
            return String(data: d, encoding: .utf8) ?? d.map { String(format: "%02x", $0) }.joined()
        case .dateTime(let date):
            return ISO8601DateFormatter().string(from: date)
        case .resolution(let x, let y, let units):
            let unitLabel = units == 3 ? "dpi" : (units == 4 ? "dpcm" : "u\(units)")
            return "\(x)x\(y)\(unitLabel)"
        case .range(let r):
            return "\(r.lowerBound)-\(r.upperBound)"
        case .collection(let col):
            let body = col.members.map { member in
                let vals = member.values.map(\.displayString).joined(separator: ",")
                return "\(member.name)=\(vals)"
            }.joined(separator: "; ")
            return "{\(body)}"
        case .text(let s),
             .name(let s),
             .keyword(let s),
             .uri(let s),
             .uriScheme(let s),
             .charset(let s),
             .naturalLanguage(let s),
             .mimeType(let s):
            return s
        case .unknown:
            return "unknown"
        case .noValue:
            return "no-value"
        case .unsupported:
            return "unsupported"
        }
    }
}

/// A named IPP attribute carrying one or more values.
struct IPPAttribute: Hashable, Sendable {
    var name: String
    var values: [IPPValue]

    init(name: String, values: [IPPValue]) {
        self.name = name
        self.values = values
    }

    init(name: String, value: IPPValue) {
        self.name = name
        self.values = [value]
    }

    // MARK: - Convenience Accessors

    /// The first value's string representation, if any.
    var stringValue: String? {
        values.first?.stringValue
    }

    /// All string values in this attribute.
    var strings: [String] {
        values.compactMap(\.stringValue)
    }

    /// All keyword/string values in this attribute.
    var keywords: [String] {
        values.compactMap(\.stringValue)
    }

    /// The first value's `Int` representation, if any.
    var intValue: Int? {
        values.first?.intValue
    }

    /// The first value's `Int32` representation, if any.
    var int32Value: Int32? {
        values.first?.int32Value
    }

    /// All integer/enum values in this attribute as `Int`.
    var integers: [Int] {
        values.compactMap(\.intValue)
    }

    /// The first value's `Bool` representation, if any.
    var boolValue: Bool? {
        values.first?.boolValue
    }

    /// The first value's `ClosedRange<Int32>`, if any.
    var rangeValue: ClosedRange<Int32>? {
        values.first?.rangeValue
    }

    /// All integer range values in this attribute.
    var ranges: [ClosedRange<Int32>] {
        values.compactMap(\.rangeValue)
    }

    /// All resolution values in this attribute.
    var resolutions: [(x: Int32, y: Int32, units: Int8)] {
        values.compactMap(\.resolutionValue)
    }

    /// The first value's `IPPCollection`, if any.
    var collectionValue: IPPCollection? {
        values.first?.collectionValue
    }

    /// All collection values in this attribute.
    var collections: [IPPCollection] {
        values.compactMap(\.collectionValue)
    }

    /// The first value's `Date`, if any.
    var dateValue: Date? {
        values.first?.dateValue
    }

    /// The first value's `Data`, if any.
    var dataValue: Data? {
        values.first?.dataValue
    }

    // MARK: - Convenience Builders

    static func charset(_ name: String = "attributes-charset", _ value: String = "utf-8") -> IPPAttribute {
        IPPAttribute(name: name, value: .charset(value))
    }

    static func naturalLanguage(_ name: String = "attributes-natural-language", _ value: String = "en") -> IPPAttribute {
        IPPAttribute(name: name, value: .naturalLanguage(value))
    }

    static func uri(_ name: String, _ value: String) -> IPPAttribute {
        IPPAttribute(name: name, value: .uri(value))
    }

    static func keyword(_ name: String, _ value: String) -> IPPAttribute {
        IPPAttribute(name: name, value: .keyword(value))
    }

    static func keywords(_ name: String, _ values: [String]) -> IPPAttribute {
        IPPAttribute(name: name, values: values.map(IPPValue.keyword))
    }

    static func name(_ name: String, _ value: String) -> IPPAttribute {
        IPPAttribute(name: name, value: .name(value))
    }

    static func text(_ name: String, _ value: String) -> IPPAttribute {
        IPPAttribute(name: name, value: .text(value))
    }

    static func mimeType(_ name: String, _ value: String) -> IPPAttribute {
        IPPAttribute(name: name, value: .mimeType(value))
    }

    static func integer(_ name: String, _ value: Int32) -> IPPAttribute {
        IPPAttribute(name: name, value: .integer(value))
    }

    static func integer(_ name: String, _ value: Int) -> IPPAttribute {
        IPPAttribute(name: name, value: .integer(Int32(clamping: value)))
    }

    static func boolean(_ name: String, _ value: Bool) -> IPPAttribute {
        IPPAttribute(name: name, value: .boolean(value))
    }

    static func enumValue(_ name: String, _ value: Int32) -> IPPAttribute {
        IPPAttribute(name: name, value: .enumValue(value))
    }

    static func enumValue(_ name: String, _ value: Int) -> IPPAttribute {
        IPPAttribute(name: name, value: .enumValue(Int32(clamping: value)))
    }

    static func collection(_ name: String, _ collection: IPPCollection) -> IPPAttribute {
        IPPAttribute(name: name, value: .collection(collection))
    }
}

/// Errors thrown while decoding an IPP wire message.
enum IPPDecodeError: Error, LocalizedError, Sendable, Equatable {
    case truncatedHeader
    case truncatedAttribute
    case invalidValueLength(tag: UInt8, length: Int)
    case unterminatedCollection
    /// The body ended before the end-of-attributes tag (0x03).
    case truncated

    var errorDescription: String? {
        switch self {
        case .truncated:
            "IPP message ended before the end-of-attributes tag (0x03)."

        case .truncatedHeader:
            "IPP message is shorter than the 8-byte header."
        case .truncatedAttribute:
            "IPP attribute record is truncated."
        case .invalidValueLength(let tag, let length):
            String(format: "Invalid length %d for IPP value tag 0x%02X.", length, tag)
        case .unterminatedCollection:
            "IPP collection is missing an endCollection (0x37) tag."
        }
    }
}

/// Errors thrown while encoding an IPP wire message.
enum IPPEncodeError: Error, LocalizedError, Sendable, Equatable {
    case fieldTooLong(what: String, length: Int)

    var errorDescription: String? {
        switch self {
        case .fieldTooLong(let what, let length):
            "IPP \(what) is \(length) bytes, which exceeds the 65535-byte limit."
        }
    }
}

/// A complete IPP request or response message (RFC 8010).
struct IPPMessage: Sendable {
    var version: (UInt8, UInt8)
    var operationOrStatus: UInt16
    var requestID: UInt32
    var groups: [(tag: IPPTag, attributes: [IPPAttribute])]
    var data: Data

    init(
        version: (UInt8, UInt8) = (2, 0),
        operationOrStatus: UInt16,
        requestID: UInt32 = 1,
        groups: [(tag: IPPTag, attributes: [IPPAttribute])] = [],
        data: Data = Data()
    ) {
        self.version = version
        self.operationOrStatus = operationOrStatus
        self.requestID = requestID
        self.groups = groups
        self.data = data
    }

    init(
        version: (UInt8, UInt8) = (2, 0),
        operation: IPPOperation,
        requestID: UInt32 = 1,
        groups: [(tag: IPPTag, attributes: [IPPAttribute])] = [],
        data: Data = Data()
    ) {
        self.version = version
        self.operationOrStatus = operation.rawValue
        self.requestID = requestID
        self.groups = groups
        self.data = data
    }

    /// Returns all attributes matching the given group tag.
    func attributes(in groupTag: IPPTag) -> [IPPAttribute] {
        groups.filter { $0.tag == groupTag }.flatMap(\.attributes)
    }

    /// Returns all attributes across all groups in order.
    var allAttributes: [IPPAttribute] {
        groups.flatMap(\.attributes)
    }

    /// Looks up the first attribute with the given name, optionally restricted to a specific group.
    func attribute(named name: String, in groupTag: IPPTag? = nil) -> IPPAttribute? {
        let pool = groupTag.map { attributes(in: $0) } ?? allAttributes
        return pool.first { $0.name == name }
    }

    /// Status message from the operation attributes group, if present.
    var statusMessage: String? {
        attribute(named: "status-message")?.stringValue
    }

    // MARK: - Wire Encoding

    /// Encodes the IPP message into RFC 8010 wire format.
    func encode() throws -> Data {
        var out = Data()
        out.append(version.0)
        out.append(version.1)
        Self.appendUInt16(operationOrStatus, to: &out)
        Self.appendUInt32(requestID, to: &out)

        for group in groups {
            out.append(group.tag.rawValue)
            for attribute in group.attributes {
                for (index, value) in attribute.values.enumerated() {
                    let attrName = index == 0 ? attribute.name : ""
                    try Self.encodeAttributeValue(name: attrName, value: value, to: &out)
                }
            }
        }

        out.append(IPPTag.endOfAttributes.rawValue)
        if !data.isEmpty {
            out.append(data)
        }
        return out
    }

    private static func checkedLength(_ count: Int, _ what: String) throws -> UInt16 {
        guard count <= Int(UInt16.max) else {
            throw IPPEncodeError.fieldTooLong(what: what, length: count)
        }
        return UInt16(count)
    }

    private static func encodeAttributeValue(name: String, value: IPPValue, to out: inout Data) throws {
        let nameBytes = Data(name.utf8)

        switch value {
        case .collection(let col):
            // begCollection record: tag 0x34, name, value-length 0
            out.append(IPPTag.begCollection.rawValue)
            appendUInt16(try checkedLength(nameBytes.count, "attribute name"), to: &out)
            out.append(nameBytes)
            appendUInt16(0, to: &out)

            // Each member: memberAttrName (0x4A) followed by 1+ nameless value records
            for member in col.members {
                let memberNameBytes = Data(member.name.utf8)
                out.append(IPPTag.memberAttrName.rawValue)
                appendUInt16(0, to: &out)
                appendUInt16(try checkedLength(memberNameBytes.count, "member name"), to: &out)
                out.append(memberNameBytes)

                for memberValue in member.values {
                    try encodeAttributeValue(name: "", value: memberValue, to: &out)
                }
            }

            // endCollection record: tag 0x37, name-length 0, value-length 0
            out.append(IPPTag.endCollection.rawValue)
            appendUInt16(0, to: &out)
            appendUInt16(0, to: &out)

        default:
            let (tag, valueBytes) = encodePrimitiveValue(value)
            out.append(tag.rawValue)
            appendUInt16(try checkedLength(nameBytes.count, "attribute name"), to: &out)
            out.append(nameBytes)
            appendUInt16(try checkedLength(valueBytes.count, "attribute value"), to: &out)
            out.append(valueBytes)
        }
    }

    private static func encodePrimitiveValue(_ value: IPPValue) -> (IPPTag, Data) {
        switch value {
        case .integer(let v):
            var d = Data()
            appendInt32(v, to: &d)
            return (.integer, d)
        case .boolean(let b):
            return (.boolean, Data([b ? 0x01 : 0x00]))
        case .enumValue(let v):
            var d = Data()
            appendInt32(v, to: &d)
            return (.enum, d)
        case .octetString(let bytes):
            return (.octetString, bytes)
        case .dateTime(let date):
            return (.dateTime, encodeDateTime(date))
        case .resolution(let x, let y, let units):
            var d = Data()
            appendInt32(x, to: &d)
            appendInt32(y, to: &d)
            d.append(UInt8(bitPattern: units))
            return (.resolution, d)
        case .range(let r):
            var d = Data()
            appendInt32(r.lowerBound, to: &d)
            appendInt32(r.upperBound, to: &d)
            return (.rangeOfInteger, d)
        case .text(let s):
            return (.textWithoutLanguage, Data(s.utf8))
        case .name(let s):
            return (.nameWithoutLanguage, Data(s.utf8))
        case .keyword(let s):
            return (.keyword, Data(s.utf8))
        case .uri(let s):
            return (.uri, Data(s.utf8))
        case .uriScheme(let s):
            return (.uriScheme, Data(s.utf8))
        case .charset(let s):
            return (.charset, Data(s.utf8))
        case .naturalLanguage(let s):
            return (.naturalLanguage, Data(s.utf8))
        case .mimeType(let s):
            return (.mimeMediaType, Data(s.utf8))
        case .unknown:
            return (.unknown, Data())
        case .noValue:
            return (.noValue, Data())
        case .unsupported:
            return (.unsupported, Data())
        case .collection:
            return (.begCollection, Data())
        }
    }

    private static func encodeDateTime(_ date: Date) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let comps = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date
        )
        let year = UInt16(clamping: comps.year ?? 1970)
        let month = UInt8(clamping: comps.month ?? 1)
        let day = UInt8(clamping: comps.day ?? 1)
        let hour = UInt8(clamping: comps.hour ?? 0)
        let minute = UInt8(clamping: comps.minute ?? 0)
        let second = UInt8(clamping: comps.second ?? 0)
        let nanos = comps.nanosecond ?? 0
        let deciSeconds = UInt8(clamping: (nanos / 100_000_000) % 10)

        var d = Data()
        appendUInt16(year, to: &d)
        d.append(month)
        d.append(day)
        d.append(hour)
        d.append(minute)
        d.append(second)
        d.append(deciSeconds)
        d.append(0x2B) // '+'
        d.append(0)    // UTC hours offset
        d.append(0)    // UTC minutes offset
        return d
    }

    // MARK: - Wire Decoding

    /// Decodes an IPP message from RFC 8010 wire format.
    static func decode(_ data: Data) throws -> IPPMessage {
        var cursor = ByteCursor(data: data)
        guard cursor.remaining >= 8 else {
            throw IPPDecodeError.truncatedHeader
        }

        let major = try cursor.readUInt8()
        let minor = try cursor.readUInt8()
        let opOrStatus = try cursor.readUInt16()
        let requestID = try cursor.readUInt32()

        var groups: [(tag: IPPTag, attributes: [IPPAttribute])] = []
        var currentGroupTag: IPPTag?
        var currentAttributes: [IPPAttribute] = []
        var sawEndOfAttributes = false

        func flushGroup() {
            if let tag = currentGroupTag {
                groups.append((tag: tag, attributes: currentAttributes))
                currentAttributes = []
                currentGroupTag = nil
            }
        }

        while cursor.remaining > 0 {
            let tagByte = try cursor.readUInt8()

            if tagByte == IPPTag.endOfAttributes.rawValue {
                flushGroup()
                sawEndOfAttributes = true
                break
            }

            if tagByte >= 0x01 && tagByte <= 0x0F {
                flushGroup()
                currentGroupTag = IPPTag(rawValue: tagByte) ?? .operationAttributes
                continue
            }

            if currentGroupTag == nil {
                currentGroupTag = .operationAttributes
            }

            let nameLength = Int(try cursor.readUInt16())
            let nameData = try cursor.readBytes(count: nameLength)
            let name = String(decoding: nameData, as: UTF8.self)

            let valueLength = Int(try cursor.readUInt16())
            let valueData = try cursor.readBytes(count: valueLength)

            let decodedValue: IPPValue
            if tagByte == IPPTag.begCollection.rawValue {
                let collection = try decodeCollection(cursor: &cursor)
                decodedValue = .collection(collection)
            } else {
                decodedValue = try decodeSingleValue(tagByte: tagByte, bytes: valueData)
            }

            if !name.isEmpty || currentAttributes.isEmpty {
                currentAttributes.append(IPPAttribute(name: name, values: [decodedValue]))
            } else {
                currentAttributes[currentAttributes.count - 1].values.append(decodedValue)
            }
        }

        guard sawEndOfAttributes else {
            throw IPPDecodeError.truncated
        }
        flushGroup()
        let payload = cursor.readRemainingData()

        return IPPMessage(
            version: (major, minor),
            operationOrStatus: opOrStatus,
            requestID: requestID,
            groups: groups,
            data: payload
        )
    }

    private static func decodeCollection(cursor: inout ByteCursor) throws -> IPPCollection {
        var members: [IPPCollection.Member] = []

        while cursor.remaining > 0 {
            let tagByte = try cursor.readUInt8()
            let nameLength = Int(try cursor.readUInt16())
            let nameData = try cursor.readBytes(count: nameLength)
            let name = String(decoding: nameData, as: UTF8.self)

            let valueLength = Int(try cursor.readUInt16())
            let valueData = try cursor.readBytes(count: valueLength)

            if tagByte == IPPTag.endCollection.rawValue {
                return IPPCollection(members: members)
            }

            if tagByte == IPPTag.memberAttrName.rawValue {
                let memberName = String(decoding: valueData, as: UTF8.self)
                members.append(IPPCollection.Member(name: memberName, values: []))
                continue
            }

            let value: IPPValue
            if tagByte == IPPTag.begCollection.rawValue {
                let nested = try decodeCollection(cursor: &cursor)
                value = .collection(nested)
            } else {
                value = try decodeSingleValue(tagByte: tagByte, bytes: valueData)
            }

            if !name.isEmpty || members.isEmpty {
                members.append(IPPCollection.Member(name: name, values: [value]))
            } else {
                members[members.count - 1].values.append(value)
            }
        }

        throw IPPDecodeError.unterminatedCollection
    }

    // A value of the wrong length stays opaque: one attribute the app may never read must not
    // cost the whole response. Only the framing (name and value lengths) is fatal.
    private static func decodeSingleValue(tagByte: UInt8, bytes: Data) throws -> IPPValue {
        guard let tag = IPPTag(rawValue: tagByte) else {
            return .octetString(bytes)
        }

        switch tag {
        case .integer:
            guard bytes.count == 4 else {
                return .octetString(bytes)
            }
            return .integer(readInt32(from: bytes, offset: 0))

        case .boolean:
            guard bytes.count >= 1 else {
                return .octetString(bytes)
            }
            return .boolean(bytes[bytes.startIndex] != 0)

        case .enum:
            guard bytes.count == 4 else {
                return .octetString(bytes)
            }
            return .enumValue(readInt32(from: bytes, offset: 0))

        case .octetString:
            return .octetString(bytes)

        case .dateTime:
            guard bytes.count == 11 else {
                return .octetString(bytes)
            }
            return .dateTime(decodeDateTime(from: bytes))

        case .resolution:
            guard bytes.count == 9 else {
                return .octetString(bytes)
            }
            let x = readInt32(from: bytes, offset: 0)
            let y = readInt32(from: bytes, offset: 4)
            let units = Int8(bitPattern: bytes[bytes.startIndex + 8])
            return .resolution(x: x, y: y, units: units)

        case .rangeOfInteger:
            guard bytes.count == 8 else {
                return .octetString(bytes)
            }
            let lower = readInt32(from: bytes, offset: 0)
            let upper = readInt32(from: bytes, offset: 4)
            return .range(min(lower, upper)...max(lower, upper))

        case .textWithLanguage:
            return .text(extractWithLanguageString(from: bytes))

        case .nameWithLanguage:
            return .name(extractWithLanguageString(from: bytes))

        case .textWithoutLanguage:
            return .text(String(decoding: bytes, as: UTF8.self))

        case .nameWithoutLanguage:
            return .name(String(decoding: bytes, as: UTF8.self))

        case .keyword:
            return .keyword(String(decoding: bytes, as: UTF8.self))

        case .uri:
            return .uri(String(decoding: bytes, as: UTF8.self))

        case .uriScheme:
            return .uriScheme(String(decoding: bytes, as: UTF8.self))

        case .charset:
            return .charset(String(decoding: bytes, as: UTF8.self))

        case .naturalLanguage:
            return .naturalLanguage(String(decoding: bytes, as: UTF8.self))

        case .mimeMediaType:
            return .mimeType(String(decoding: bytes, as: UTF8.self))

        case .unknown:
            return .unknown

        case .noValue, .defaultValue:
            return .noValue

        case .unsupported:
            return .unsupported

        default:
            return .octetString(bytes)
        }
    }

    private static func extractWithLanguageString(from bytes: Data) -> String {
        guard bytes.count >= 4 else {
            return String(decoding: bytes, as: UTF8.self)
        }
        let s = bytes.startIndex
        let langLen = Int((UInt16(bytes[s]) << 8) | UInt16(bytes[s + 1]))
        let textLenOffset = s + 2 + langLen
        guard textLenOffset + 2 <= bytes.endIndex else {
            return String(decoding: bytes, as: UTF8.self)
        }
        let textLen = Int((UInt16(bytes[textLenOffset]) << 8) | UInt16(bytes[textLenOffset + 1]))
        let textStart = textLenOffset + 2
        let textEnd = textStart + textLen
        guard textEnd <= bytes.endIndex else {
            return String(decoding: bytes, as: UTF8.self)
        }
        return String(decoding: bytes[textStart..<textEnd], as: UTF8.self)
    }

    private static func decodeDateTime(from bytes: Data) -> Date {
        let s = bytes.startIndex
        let year = Int((UInt16(bytes[s]) << 8) | UInt16(bytes[s + 1]))
        let month = Int(bytes[s + 2])
        let day = Int(bytes[s + 3])
        let hour = Int(bytes[s + 4])
        let minute = Int(bytes[s + 5])
        let second = Int(bytes[s + 6])
        let deciSeconds = Int(bytes[s + 7])
        let direction = bytes[s + 8]
        let tzHours = Int(bytes[s + 9])
        let tzMinutes = Int(bytes[s + 10])

        let sign = direction == 0x2D ? -1 : 1
        let offsetSeconds = sign * (tzHours * 3600 + tzMinutes * 60)
        let tz = TimeZone(secondsFromGMT: offsetSeconds) ?? .gmt

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = tz
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = deciSeconds * 100_000_000

        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    // MARK: - Binary Helpers

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendInt32(_ value: Int32, to data: inout Data) {
        appendUInt32(UInt32(bitPattern: value), to: &data)
    }

    private static func readInt32(from data: Data, offset: Int) -> Int32 {
        let base = data.startIndex + offset
        let b0 = UInt32(data[base]) << 24
        let b1 = UInt32(data[base + 1]) << 16
        let b2 = UInt32(data[base + 2]) << 8
        let b3 = UInt32(data[base + 3])
        return Int32(bitPattern: b0 | b1 | b2 | b3)
    }
}

private struct ByteCursor: Sendable {
    let data: Data
    var index: Data.Index

    init(data: Data) {
        self.data = data
        self.index = data.startIndex
    }

    var remaining: Int {
        data.endIndex - index
    }

    mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else {
            throw IPPDecodeError.truncatedAttribute
        }
        let byte = data[index]
        index += 1
        return byte
    }

    mutating func readUInt16() throws -> UInt16 {
        guard remaining >= 2 else {
            throw IPPDecodeError.truncatedAttribute
        }
        let hi = UInt16(data[index]) << 8
        let lo = UInt16(data[index + 1])
        index += 2
        return hi | lo
    }

    mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else {
            throw IPPDecodeError.truncatedAttribute
        }
        let b0 = UInt32(data[index]) << 24
        let b1 = UInt32(data[index + 1]) << 16
        let b2 = UInt32(data[index + 2]) << 8
        let b3 = UInt32(data[index + 3])
        index += 4
        return b0 | b1 | b2 | b3
    }

    mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0, remaining >= count else {
            throw IPPDecodeError.truncatedAttribute
        }
        let slice = data[index..<(index + count)]
        index += count
        return Data(slice)
    }

    mutating func readRemainingData() -> Data {
        guard remaining > 0 else { return Data() }
        let slice = data[index..<data.endIndex]
        index = data.endIndex
        return Data(slice)
    }
}

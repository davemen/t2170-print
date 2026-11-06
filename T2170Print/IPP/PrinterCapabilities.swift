import Foundation

/// A single entry from the printer's `media-col-database` or `media-col-ready` attribute.
struct MediaColEntry: Codable, Hashable, Sendable, Identifiable {
    var mediaSizeName: String?
    var xDimension: Int
    /// Set when the printer gave `x-dimension` as a range, so `xDimension` is only its lower bound.
    var xDimensionMax: Int?
    var yDimension: Int
    var yDimensionMax: Int?
    var source: String?
    var type: String?
    var isRoll: Bool

    var id: String {
        "\(mediaSizeName ?? "custom")-\(xDimension)x\(yDimension)-\(source ?? "any")-\(type ?? "any")-\(isRoll)"
    }

    init(
        mediaSizeName: String? = nil,
        xDimension: Int = 0,
        xDimensionMax: Int? = nil,
        yDimension: Int = 0,
        yDimensionMax: Int? = nil,
        source: String? = nil,
        type: String? = nil,
        isRoll: Bool = false
    ) {
        self.mediaSizeName = mediaSizeName
        self.xDimension = xDimension
        self.xDimensionMax = xDimensionMax
        self.yDimension = yDimension
        self.yDimensionMax = yDimensionMax
        self.source = source
        self.type = type
        self.isRoll = isRoll
    }
}

/// A supported printer resolution (`x` by `y`, with `units`: 3 = dpi, 4 = dpcm).
struct PrinterResolution: Codable, Hashable, Sendable {
    var x: Int
    var y: Int
    var units: Int

    init(x: Int, y: Int, units: Int = 3) {
        self.x = x
        self.y = y
        self.units = units
    }
}

/// Parsed printer capabilities and status from an IPP `Get-Printer-Attributes` response.
struct PrinterCapabilities: Codable, Hashable, Sendable {
    typealias MediaColEntry = T2170Print.MediaColEntry
    typealias Resolution = PrinterResolution

    var printerName: String
    var makeAndModel: String
    var uuid: String?
    var state: Int
    var stateReasons: [String]
    var stateMessage: String?
    /// Optional because saved capabilities from an older build do not have it.
    var isAcceptingJobs: Bool?

    var mediaSupported: [String]
    var mediaReady: [String]
    var mediaDefault: String?
    var mediaSourceSupported: [String]
    var mediaTypeSupported: [String]
    var mediaColDatabase: [MediaColEntry]
    /// What is loaded right now, when the printer says. Optional for the same reason as `isAcceptingJobs`.
    var mediaColReady: [MediaColEntry]?

    var printQualitySupported: [Int]
    var printColorModeSupported: [String]
    var finishingsSupported: [Int]
    var numberUpSupported: [Int]
    var sidesSupported: [String]
    var documentFormatSupported: [String]
    var printScalingSupported: [String]
    var orientationSupported: [Int]
    var copiesSupported: ClosedRange<Int>
    var pageRangesSupported: Bool
    var printerResolutionSupported: [PrinterResolution]
    /// `urf-supported`: AirPrint raster capability tokens such as `RS300`, `SRGB24`, `W8`.
    var urfSupported: [String]
    /// `pwg-raster-document-type-supported`, such as `srgb_8`, `sgray_8`.
    var pwgRasterTypesSupported: [String]
    /// `pwg-raster-document-resolution-supported`.
    var pwgRasterResolutions: [PrinterResolution]

    var markerNames: [String]
    var markerLevels: [Int]
    var markerColors: [String]
    var markerTypes: [String]
    var identifyActionsSupported: [String]

    /// Every attribute whose name is not in the standard IPP printer-attributes list.
    var vendor: [String: [String]]
    /// Every attribute returned by the printer rendered as strings.
    var rawDump: [String: [String]]

    /// Get-Printer-Attributes request list. `all` leaves out `media-col-database` by definition, and the
    /// raster attributes are named as well because some printers only return them when asked by name.
    static let requestedAttributes = [
        "all",
        "media-col-database",
        "urf-supported",
        "pwg-raster-document-type-supported",
        "pwg-raster-document-resolution-supported"
    ]

    /// Standard IPP attribute names recognized directly by `PrinterCapabilities`.
    static let standardAttributeNames: Set<String> = [
        "attributes-charset",
        "attributes-natural-language",
        "charset-configured",
        "charset-supported",
        "color-supported",
        "compression-supported",
        "copies-default",
        "copies-supported",
        "document-format-default",
        "document-format-supported",
        "finishings-default",
        "finishings-supported",
        "generated-natural-language-supported",
        "identify-actions-default",
        "identify-actions-supported",
        "ipp-versions-supported",
        "job-creation-attributes-supported",
        "marker-colors",
        "marker-high-levels",
        "marker-levels",
        "marker-low-levels",
        "marker-names",
        "marker-types",
        "media-col-database",
        "media-col-default",
        "media-col-ready",
        "media-col-supported",
        "media-default",
        "media-ready",
        "media-size-supported",
        "media-source-supported",
        "media-supported",
        "media-type-supported",
        "pwg-raster-document-resolution-supported",
        "pwg-raster-document-type-supported",
        "urf-supported",
        "multiple-document-jobs-supported",
        "natural-language-configured",
        "number-up-default",
        "number-up-supported",
        "operations-supported",
        "orientation-requested-default",
        "orientation-requested-supported",
        "output-bin-default",
        "output-bin-supported",
        "page-ranges-supported",
        "pages-per-minute",
        "pages-per-minute-color",
        "pdl-override-supported",
        "print-color-mode-default",
        "print-color-mode-supported",
        "print-quality-default",
        "print-quality-supported",
        "print-scaling-default",
        "print-scaling-supported",
        "printer-current-time",
        "printer-device-id",
        "printer-dns-sd-name",
        "printer-icons",
        "printer-info",
        "printer-is-accepting-jobs",
        "printer-location",
        "printer-make-and-model",
        "printer-more-info",
        "printer-name",
        "printer-organization",
        "printer-organizational-unit",
        "printer-resolution-default",
        "printer-resolution-supported",
        "printer-state",
        "printer-state-change-date-time",
        "printer-state-change-time",
        "printer-state-message",
        "printer-state-reasons",
        "printer-supply-info-uri",
        "printer-up-time",
        "printer-uri-supported",
        "printer-uuid",
        "queued-job-count",
        "sides-default",
        "sides-supported",
        "uri-authentication-supported",
        "uri-security-supported"
    ]

    /// Parses printer capabilities from the attributes returned by `Get-Printer-Attributes`.
    init(attributes: [IPPAttribute]) {
        var byName: [String: IPPAttribute] = [:]
        var dump: [String: [String]] = [:]
        var vendorAttrs: [String: [String]] = [:]

        for attr in attributes {
            byName[attr.name] = attr
            let stringValues = attr.values.map(\.displayString)
            dump[attr.name] = stringValues
            if !Self.standardAttributeNames.contains(attr.name) {
                vendorAttrs[attr.name] = stringValues
            }
        }

        self.printerName = byName["printer-name"]?.stringValue ?? ""
        self.makeAndModel = byName["printer-make-and-model"]?.stringValue ?? ""
        self.uuid = byName["printer-uuid"]?.stringValue
        self.state = byName["printer-state"]?.intValue ?? 3
        self.stateReasons = byName["printer-state-reasons"]?.keywords ?? []
        self.stateMessage = byName["printer-state-message"]?.stringValue
        self.isAcceptingJobs = byName["printer-is-accepting-jobs"]?.boolValue

        self.mediaSupported = byName["media-supported"]?.keywords ?? []
        self.mediaReady = byName["media-ready"]?.keywords ?? []
        self.mediaDefault = byName["media-default"]?.stringValue
        self.mediaSourceSupported = byName["media-source-supported"]?.keywords ?? []
        self.mediaTypeSupported = byName["media-type-supported"]?.keywords ?? []

        let dbCollections = byName["media-col-database"]?.collections
            ?? byName["media-col-ready"]?.collections
            ?? []
        self.mediaColDatabase = dbCollections.map(Self.parseMediaColEntry)
        self.mediaColReady = byName["media-col-ready"]?.collections.map(Self.parseMediaColEntry)

        self.printQualitySupported = byName["print-quality-supported"]?.integers ?? []
        self.printColorModeSupported = byName["print-color-mode-supported"]?.keywords ?? []
        self.finishingsSupported = byName["finishings-supported"]?.integers ?? []
        self.numberUpSupported = Self.parseNumberUpSupported(byName["number-up-supported"])
        self.sidesSupported = byName["sides-supported"]?.keywords ?? []
        self.documentFormatSupported = byName["document-format-supported"]?.keywords ?? []
        self.printScalingSupported = byName["print-scaling-supported"]?.keywords ?? []
        self.orientationSupported = byName["orientation-requested-supported"]?.integers ?? []
        self.copiesSupported = Self.parseCopiesSupported(byName["copies-supported"])
        self.pageRangesSupported = byName["page-ranges-supported"]?.boolValue ?? false

        self.printerResolutionSupported = (byName["printer-resolution-supported"]?.resolutions ?? []).map {
            PrinterResolution(x: Int($0.x), y: Int($0.y), units: Int($0.units))
        }
        self.urfSupported = byName["urf-supported"]?.keywords ?? []
        self.pwgRasterTypesSupported = byName["pwg-raster-document-type-supported"]?.keywords ?? []
        self.pwgRasterResolutions = (byName["pwg-raster-document-resolution-supported"]?.resolutions ?? []).map {
            PrinterResolution(x: Int($0.x), y: Int($0.y), units: Int($0.units))
        }

        // Drop markers whose level is a negative sentinel (-1 unknown, -2 unavailable, -3 low)
        // from all four parallel arrays together so they stay index-aligned.
        let rawNames = byName["marker-names"]?.strings ?? []
        let rawLevels = byName["marker-levels"]?.integers ?? []
        let rawColors = byName["marker-colors"]?.strings ?? []
        let rawTypes = byName["marker-types"]?.strings ?? []
        var mNames: [String] = [], mLevels: [Int] = [], mColors: [String] = [], mTypes: [String] = []
        for (i, level) in rawLevels.enumerated() where level >= 0 {
            if i < rawNames.count { mNames.append(rawNames[i]) } else { continue }
            mLevels.append(level)
            if i < rawColors.count { mColors.append(rawColors[i]) }
            if i < rawTypes.count { mTypes.append(rawTypes[i]) }
        }
        self.markerNames = mNames
        self.markerLevels = mLevels
        self.markerColors = rawColors.count == rawLevels.count ? mColors : rawColors
        self.markerTypes = rawTypes.count == rawLevels.count ? mTypes : rawTypes
        self.identifyActionsSupported = byName["identify-actions-supported"]?.keywords ?? []

        self.vendor = vendorAttrs
        self.rawDump = dump
    }

    // MARK: - Derived Properties & Queries

    /// Unique roll widths in millimetres derived from roll entries in `mediaColDatabase`.
    var rollWidthsMM: [Double] {
        let widths = mediaColDatabase
            .filter { $0.isRoll && $0.xDimension > 0 }
            .map { Double($0.xDimension) / 100.0 }
        return Array(Set(widths)).sorted()
    }

    /// Returns `true` if the printer lists the given `media-source` keyword as supported.
    func supports(mediaSource: String) -> Bool {
        if mediaSourceSupported.contains(mediaSource) {
            return true
        }
        return mediaColDatabase.contains { $0.source == mediaSource }
    }

    /// Returns `true` if the printer lists the given `media-type` keyword as supported.
    func supports(mediaType: String) -> Bool {
        if mediaTypeSupported.contains(mediaType) {
            return true
        }
        return mediaColDatabase.contains { $0.type == mediaType }
    }

    /// Returns `true` if the printer lists the given `finishings` enum value as supported.
    func supports(finishing: Int) -> Bool {
        finishingsSupported.contains(finishing)
    }

    // MARK: - Persistence

    /// Saves the capabilities to a JSON file at `url`.
    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    /// Loads `PrinterCapabilities` from a JSON file at `url`.
    static func load(from url: URL) throws -> PrinterCapabilities {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PrinterCapabilities.self, from: data)
    }

    // MARK: - Helpers

    private static func parseMediaColEntry(_ col: IPPCollection) -> MediaColEntry {
        let mediaSizeCol = col.firstValue(for: "media-size")?.collectionValue
        let sizeName = col.firstValue(for: "media-size-name")?.stringValue
            ?? mediaSizeCol?.firstValue(for: "media-size-name")?.stringValue

        var xDim = 0
        var xMax: Int?
        if let xVal = mediaSizeCol?.firstValue(for: "x-dimension") {
            if let intVal = xVal.intValue {
                xDim = intVal
            } else if let rangeVal = xVal.rangeValue {
                xDim = Int(rangeVal.lowerBound)
                xMax = Int(rangeVal.upperBound)
            }
        }

        var yDim = 0
        var yMax: Int?
        var yIsRange = false
        if let yVal = mediaSizeCol?.firstValue(for: "y-dimension") {
            if let intVal = yVal.intValue {
                yDim = intVal
            } else if let rangeVal = yVal.rangeValue {
                yDim = Int(rangeVal.lowerBound)
                yMax = Int(rangeVal.upperBound)
                yIsRange = true
            }
        }

        let source = col.firstValue(for: "media-source")?.stringValue
        let type = col.firstValue(for: "media-type")?.stringValue
        let sourceIsRoll = source?.lowercased().contains("roll") == true

        return MediaColEntry(
            mediaSizeName: sizeName,
            xDimension: xDim,
            xDimensionMax: xMax,
            yDimension: yDim,
            yDimensionMax: yMax,
            source: source,
            type: type,
            isRoll: yIsRange || sourceIsRoll
        )
    }

    private static func parseCopiesSupported(_ attr: IPPAttribute?) -> ClosedRange<Int> {
        guard let attr else { return 1...999 }
        if let range = attr.rangeValue {
            let lower = max(1, Int(range.lowerBound))
            let upper = max(lower, Int(range.upperBound))
            return lower...upper
        }
        if let maxCopies = attr.intValue, maxCopies >= 1 {
            return 1...maxCopies
        }
        return 1...999
    }

    private static func parseNumberUpSupported(_ attr: IPPAttribute?) -> [Int] {
        guard let attr else { return [] }
        var result: [Int] = []
        for value in attr.values {
            if let intVal = value.intValue {
                result.append(intVal)
            } else if let range = value.rangeValue {
                let lower = max(1, Int(range.lowerBound))
                let upper = min(Int(range.upperBound), 16)
                if lower <= upper {
                    result.append(contentsOf: lower...upper)
                }
            }
        }
        return result
    }
}

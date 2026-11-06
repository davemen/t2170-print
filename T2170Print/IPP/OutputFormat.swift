import Foundation

/// The user's "Send as" preference. `.automatic` tries each format the printer lists, best first.
enum SendFormatChoice: String, CaseIterable, Codable, Sendable, Identifiable {
    case automatic, urf, pwgRaster, pdf

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .urf: "Apple Raster (URF)"
        case .pwgRaster: "PWG Raster"
        case .pdf: "PDF"
        }
    }

    var mimeType: String? {
        switch self {
        case .automatic: nil
        case .urf: RasterFormat.urf.mimeType
        case .pwgRaster: RasterFormat.pwg.mimeType
        case .pdf: "application/pdf"
        }
    }
}

/// One concrete way of sending a job: the document format plus how to render it.
struct PrintPayload: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case pdf
        case raster(RasterFormat)
    }

    var kind: Kind
    var dpi: Int
    var gray: Bool

    var mimeType: String {
        switch kind {
        case .pdf: "application/pdf"
        case .raster(let format): format.mimeType
        }
    }

    /// Short text for the Last job section.
    var summary: String {
        switch kind {
        case .pdf: "PDF"
        case .raster(let format):
            "\(format == .urf ? "URF" : "PWG Raster"), \(dpi) dpi, \(gray ? "grey" : "colour")"
        }
    }
}

/// Errors raised while choosing how to send a job.
enum OutputFormatError: Error, LocalizedError, Sendable, Equatable {
    case noUsableFormat(choice: SendFormatChoice, printerFormats: [String])

    var errorDescription: String? {
        switch self {
        case .noUsableFormat(let choice, let formats):
            let list = formats.isEmpty ? "none reported" : formats.joined(separator: ", ")
            if choice == .automatic {
                return "This app cannot make any format the printer accepts. Printer lists: \(list)"
            }
            return "The printer does not accept \(choice.label). Printer lists: \(list)"
        }
    }
}

/// Picks document formats from what the printer actually advertises.
enum OutputFormatSelector {
    /// Automatic order. Raster comes first because AirPrint requires URF and IPP Everywhere requires
    /// PWG Raster, while PDF is optional and the Epson Mac driver never sends it to this printer.
    static let automaticOrder: [SendFormatChoice] = [.urf, .pwgRaster, .pdf]

    /// Square resolutions from `urf-supported` tokens such as `RS300`, `RS300-600`, `RS360-720`.
    static func urfResolutions(_ tokens: [String]) -> [Int] {
        var result = Set<Int>()
        for token in tokens where token.uppercased().hasPrefix("RS") {
            for part in token.dropFirst(2).split(separator: "-") {
                if let dpi = Int(part), dpi > 0 { result.insert(dpi) }
            }
        }
        return result.sorted()
    }

    /// Square resolutions in dots per inch; units 3 is dpi and 4 is dots per centimetre.
    static func pwgResolutions(_ resolutions: [PrinterResolution]) -> [Int] {
        var result = Set<Int>()
        for resolution in resolutions where resolution.x == resolution.y && resolution.x > 0 {
            switch resolution.units {
            case 3: result.insert(resolution.x)
            case 4: result.insert(Int((Double(resolution.x) * 2.54).rounded()))
            default: break
            }
        }
        return result.sorted()
    }

    /// Draft and normal use the lowest resolution of at least 300 dpi. High quality uses the highest
    /// up to 720 dpi, which bounds file size on long rolls.
    static func chooseDPI(available: [Int], highQuality: Bool) -> Int? {
        let sorted = available.sorted()
        guard let lowest = sorted.first, let highest = sorted.last else { return nil }
        if highQuality {
            return sorted.last { $0 <= 720 } ?? lowest
        }
        return sorted.first { $0 >= 300 } ?? highest
    }

    /// The payload for one format, or nil when the printer does not offer what that format needs.
    static func payload(
        for choice: SendFormatChoice,
        capabilities: PrinterCapabilities,
        printQuality: Int,
        colorMode: String
    ) -> PrintPayload? {
        let listed = Set(capabilities.documentFormatSupported.map { $0.lowercased() })
        guard let mime = choice.mimeType, listed.contains(mime) else { return nil }
        let highQuality = printQuality >= 5
        let wantsGray = colorMode != "color"

        switch choice {
        case .automatic:
            return nil
        case .pdf:
            return PrintPayload(kind: .pdf, dpi: 300, gray: false)
        case .urf:
            let tokens = Set(capabilities.urfSupported.map { $0.uppercased() })
            let hasColor = tokens.contains("SRGB24")
            let hasGray = tokens.contains("W8")
            guard hasColor || (wantsGray && hasGray),
                  let dpi = chooseDPI(available: urfResolutions(capabilities.urfSupported), highQuality: highQuality)
            else { return nil }
            return PrintPayload(kind: .raster(.urf), dpi: dpi, gray: wantsGray && hasGray)
        case .pwgRaster:
            let types = Set(capabilities.pwgRasterTypesSupported.map { $0.lowercased() })
            let hasColor = types.contains("srgb_8")
            let hasGray = types.contains("sgray_8")
            guard hasColor || (wantsGray && hasGray),
                  let dpi = chooseDPI(available: pwgResolutions(capabilities.pwgRasterResolutions), highQuality: highQuality)
            else { return nil }
            return PrintPayload(kind: .raster(.pwg), dpi: dpi, gray: wantsGray && hasGray)
        }
    }

    /// Formats to try, in order. A specific choice yields at most one entry and never falls back.
    static func candidates(
        capabilities: PrinterCapabilities,
        choice: SendFormatChoice,
        printQuality: Int,
        colorMode: String
    ) -> [PrintPayload] {
        let order = choice == .automatic ? automaticOrder : [choice]
        return order.compactMap {
            payload(for: $0, capabilities: capabilities, printQuality: printQuality, colorMode: colorMode)
        }
    }

    /// Choices to show in the "Send as" picker: Automatic plus every format usable with this printer.
    static func availableChoices(capabilities: PrinterCapabilities?) -> [SendFormatChoice] {
        guard let capabilities else { return [.automatic] }
        return [.automatic] + automaticOrder.filter {
            payload(for: $0, capabilities: capabilities, printQuality: 4, colorMode: "color") != nil
                || payload(for: $0, capabilities: capabilities, printQuality: 4, colorMode: "monochrome") != nil
        }
    }
}

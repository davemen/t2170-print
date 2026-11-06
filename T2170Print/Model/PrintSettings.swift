import Foundation

// Mirrors every pane of the Epson SureColor T2170 macOS driver
// (Basic, Advanced, Layout, Paper Handling, Color Matching, Preferences)
// plus the Windows-only page options (N-up, Poster, Banner, Folded Double-Side).
// Source: Epson's online User's Guide for the SC-T2170/T3170/T5170 Mac driver.
//
// Each option carries the IPP keyword the printer is expected to accept.
// These are defaults: the printer's own Get-Printer-Attributes answer overrides
// them at runtime (see PrinterCapabilities). Options with no IPP keyword are
// applied by the renderer, since we rasterise pages ourselves.

// MARK: - Basic

enum PaperSource: String, CaseIterable, Codable, Identifiable {
    case rollPaper, autoSheetFeeder, sheet
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rollPaper: "Roll Paper"
        case .autoSheetFeeder: "Auto Sheet Feeder"
        case .sheet: "Sheet"
        }
    }
    /// IPP `media-source` keyword (PWG 5100.7).
    var ippMediaSource: String {
        switch self {
        case .rollPaper: "roll-1"
        case .autoSheetFeeder: "auto"
        case .sheet: "manual"
        }
    }
}

/// Roll widths from the Mac driver PPD (EPIJ_RoWd), widest first.
enum RollWidth: String, CaseIterable, Codable, Identifiable {
    case w24in, w600mm, a1, w22in, b2, w500mm, w18in, w17in, a2
    case w16in, w400mm, w14in, w13in, w12in, w300mm, a3, w10in
    var id: String { rawValue }
    var label: String {
        switch self {
        case .w24in: "24 in (610 mm)"
        case .w600mm: "600 mm"
        case .a1: "A1 (594 mm)"
        case .w22in: "22 in (559 mm)"
        case .b2: "B2 (515 mm)"
        case .w500mm: "500 mm"
        case .w18in: "18 in (457 mm)"
        case .w17in: "17 in (432 mm)"
        case .a2: "A2 (420 mm)"
        case .w16in: "16 in (406 mm)"
        case .w400mm: "400 mm"
        case .w14in: "14 in (356 mm)"
        case .w13in: "13 in (330 mm)"
        case .w12in: "12 in (305 mm)"
        case .w300mm: "300 mm"
        case .a3: "A3 (297 mm)"
        case .w10in: "10 in (254 mm)"
        }
    }
    var widthMM: Double {
        switch self {
        case .w24in: 609.6
        case .w600mm: 600
        case .a1: 594
        case .w22in: 558.8
        case .b2: 515
        case .w500mm: 500
        case .w18in: 457.2
        case .w17in: 431.8
        case .a2: 420
        case .w16in: 406.4
        case .w400mm: 400
        case .w14in: 355.6
        case .w13in: 330.2
        case .w12in: 304.8
        case .w300mm: 300
        case .a3: 297
        case .w10in: 254
        }
    }
}

enum OutputSizeMode: String, CaseIterable, Codable, Identifiable {
    case sameAsPaperSize, fitToRollPaperWidth, outputSize, specifySize, retainScale, banner
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sameAsPaperSize: "Same as Paper Size"
        case .fitToRollPaperWidth: "Fit to Roll Paper Width"
        case .outputSize: "Output Size"
        case .specifySize: "Specify Size"
        case .retainScale: "Retain Scale"
        case .banner: "Banner"
        }
    }
}

/// Paper sizes in millimetres, portrait. Custom sizes are user-entered.
struct PaperSize: Codable, Hashable, Identifiable {
    var name: String
    var widthMM: Double
    var heightMM: Double
    /// IPP `media` / `media-size-name` keyword (PWG 5101.1), nil for custom.
    var ippMediaName: String?
    var id: String { name }

    var widthPt: Double { widthMM / 25.4 * 72 }
    var heightPt: Double { heightMM / 25.4 * 72 }

    static let standard: [PaperSize] = [
        PaperSize(name: "A4", widthMM: 210, heightMM: 297, ippMediaName: "iso_a4_210x297mm"),
        PaperSize(name: "A3", widthMM: 297, heightMM: 420, ippMediaName: "iso_a3_297x420mm"),
        PaperSize(name: "A2", widthMM: 420, heightMM: 594, ippMediaName: "iso_a2_420x594mm"),
        PaperSize(name: "A1", widthMM: 594, heightMM: 841, ippMediaName: "iso_a1_594x841mm"),
        PaperSize(name: "US Letter", widthMM: 215.9, heightMM: 279.4, ippMediaName: "na_letter_8.5x11in"),
        PaperSize(name: "US Legal", widthMM: 215.9, heightMM: 355.6, ippMediaName: "na_legal_8.5x14in"),
        PaperSize(name: "Tabloid (11×17)", widthMM: 279.4, heightMM: 431.8, ippMediaName: "na_ledger_11x17in"),
        PaperSize(name: "ARCH A (9×12)", widthMM: 228.6, heightMM: 304.8, ippMediaName: "na_arch-a_9x12in"),
        PaperSize(name: "ARCH B (12×18)", widthMM: 304.8, heightMM: 457.2, ippMediaName: "na_arch-b_12x18in"),
        PaperSize(name: "ARCH C (18×24)", widthMM: 457.2, heightMM: 609.6, ippMediaName: "na_arch-c_18x24in"),
        PaperSize(name: "ARCH D (24×36)", widthMM: 609.6, heightMM: 914.4, ippMediaName: "na_arch-d_24x36in"),
        PaperSize(name: "ANSI C (17×22)", widthMM: 431.8, heightMM: 558.8, ippMediaName: "na_c_17x22in"),
        PaperSize(name: "ANSI D (22×34)", widthMM: 558.8, heightMM: 863.6, ippMediaName: "na_d_22x34in"),
        PaperSize(name: "Super B (13×19)", widthMM: 330.2, heightMM: 482.6, ippMediaName: "na_super-b_13x19in"),
    ]
}

enum Orientation: String, CaseIterable, Codable, Identifiable {
    case portrait, landscape
    var id: String { rawValue }
    var label: String { self == .portrait ? "Portrait" : "Landscape" }
    var ippKeyword: String { rawValue }
    /// IPP `orientation-requested` enum.
    var ippEnum: Int { self == .portrait ? 3 : 4 }
}

enum MediaType: String, CaseIterable, Codable, Identifiable {
    case usePrinterSettings
    case plainPaper, plainPaperLineDrawing
    case singleweightMatte, singleweightMatteLineDrawing, doubleweightMatte, enhancedMatte
    case ultraPremiumPresentationMatte, presentationPaperMatte
    case coatedPaperGeneric, coatedPaperGenericLineDrawing
    case premiumGlossyPhoto170, premiumSemiglossPhoto170
    case premiumGlossyPhoto, photoPaperGlossy, premiumSemiglossPhoto, premiumLusterPhoto, photoPaperGeneric
    case tracingPaper, tracingPaperLowDuty, matteFilm
    case enhancedAdhesiveSynthetic, enhancedLowAdhesiveSynthetic, heavyWeightPolyesterBanner
    case blueprintPaper
    var id: String { rawValue }
    var label: String {
        switch self {
        case .usePrinterSettings: "Use Printer Settings"
        case .plainPaper: "Plain Paper"
        case .plainPaperLineDrawing: "Plain Paper (line drawing)"
        case .singleweightMatte: "Singleweight Matte"
        case .singleweightMatteLineDrawing: "Singleweight Matte (line drawing)"
        case .doubleweightMatte: "Doubleweight Matte"
        case .enhancedMatte: "Enhanced Matte"
        case .ultraPremiumPresentationMatte: "Ultra Premium Presentation Paper Matte"
        case .presentationPaperMatte: "Presentation Paper Matte"
        case .coatedPaperGeneric: "Coated Paper (Generic)"
        case .coatedPaperGenericLineDrawing: "Coated Paper (Generic) (line drawing)"
        case .premiumGlossyPhoto170: "Premium Glossy Photo Paper (170)"
        case .premiumSemiglossPhoto170: "Premium Semigloss Photo Paper (170)"
        case .premiumGlossyPhoto: "Premium Glossy Photo Paper"
        case .photoPaperGlossy: "Photo Paper Glossy"
        case .premiumSemiglossPhoto: "Premium Semigloss Photo Paper"
        case .premiumLusterPhoto: "Premium Luster Photo Paper"
        case .photoPaperGeneric: "Photo Paper (Generic)"
        case .tracingPaper: "Tracing Paper"
        case .tracingPaperLowDuty: "Tracing Paper <Low Duty>"
        case .matteFilm: "Matte Film"
        case .enhancedAdhesiveSynthetic: "Enhanced Adhesive Synthetic Paper"
        case .enhancedLowAdhesiveSynthetic: "Enhanced Low Adhesive Synthetic Paper"
        case .heavyWeightPolyesterBanner: "Heavy Weight Polyester Banner"
        case .blueprintPaper: "Blueprint Paper"
        }
    }
    /// Closest IPP `media-type` keyword (PWG 5101.1). Epson's own names, if the
    /// printer lists them in `media-type-supported`, override these at runtime.
    /// The PPD lists 24 types (EPIJ_Medi); line-drawing variants are driver-side ink modes.
    var ippMediaType: String? {
        switch self {
        case .usePrinterSettings: nil
        case .plainPaper, .plainPaperLineDrawing, .blueprintPaper: "stationery"
        case .singleweightMatte, .singleweightMatteLineDrawing, .doubleweightMatte, .enhancedMatte: "photographic-matte"
        case .ultraPremiumPresentationMatte, .presentationPaperMatte, .coatedPaperGeneric, .coatedPaperGenericLineDrawing: "stationery-coated"
        case .premiumGlossyPhoto170, .premiumGlossyPhoto, .photoPaperGlossy: "photographic-glossy"
        case .premiumSemiglossPhoto170, .premiumSemiglossPhoto: "photographic-semi-gloss"
        case .premiumLusterPhoto: "photographic-satin"
        case .photoPaperGeneric: "photographic"
        case .tracingPaper, .tracingPaperLowDuty: "tracing-paper"
        case .matteFilm: "film-opaque"
        case .enhancedAdhesiveSynthetic, .enhancedLowAdhesiveSynthetic: "self-adhesive"
        case .heavyWeightPolyesterBanner: "fabric"
        }
    }
}

enum SelectTarget: String, CaseIterable, Codable, Identifiable {
    case cadLineDrawing, gis, poster, photo, businessDocument, plainDocument
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cadLineDrawing: "CAD / Line Drawing"
        case .gis: "GIS"
        case .poster: "Poster"
        case .photo: "Photo"
        case .businessDocument: "Business Document"
        case .plainDocument: "Plain Document"
        }
    }
}

enum PrintMode: String, CaseIterable, Codable, Identifiable {
    case color, black, blackBiLevel, coloredPaperYellow
    var id: String { rawValue }
    var label: String {
        switch self {
        case .color: "Color"
        case .black: "Black"
        case .blackBiLevel: "Black (Bi-Level)"
        case .coloredPaperYellow: "Colored Paper (Yellow)"
        }
    }
    /// IPP `print-color-mode`.
    var ippPrintColorMode: String {
        switch self {
        case .color, .coloredPaperYellow: "color"
        case .black: "monochrome"
        case .blackBiLevel: "bi-level"
        }
    }
}

enum ColorMode: String, CaseIterable, Codable, Identifiable {
    case epsonStandardSRGB, businessGraphics, lineDrawing, gis, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .epsonStandardSRGB: "EPSON Standard (sRGB)"
        case .businessGraphics: "Business Graphics"
        case .lineDrawing: "Line Drawing"
        case .gis: "GIS"
        case .off: "Off (No Color Adjustment)"
        }
    }
}

enum QualityLevel: String, CaseIterable, Codable, Identifiable {
    case speed, quality, maxQuality
    var id: String { rawValue }
    var label: String {
        switch self {
        case .speed: "Speed"
        case .quality: "Quality"
        case .maxQuality: "Max Quality"
        }
    }
    /// IPP `print-quality` enum: 3 draft, 4 normal, 5 high.
    var ippPrintQuality: Int {
        switch self {
        case .speed: 3
        case .quality: 4
        case .maxQuality: 5
        }
    }
}

enum GammaSetting: String, CaseIterable, Codable, Identifiable {
    case g1_8, g2_2
    var id: String { rawValue }
    var label: String { self == .g1_8 ? "1.8" : "2.2" }
    var value: Double { self == .g1_8 ? 1.8 : 2.2 }
}

enum ColorAdjustStyle: String, CaseIterable, Codable, Identifiable {
    case colorCircle, slideBar
    var id: String { rawValue }
    var label: String { self == .colorCircle ? "Color Circle" : "Slide Bar" }
}

/// Mac driver "Color Controls": applied by the renderer before rasterising.
struct ColorControls: Codable, Hashable {
    var brightness: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var cyan: Double = 0
    var magenta: Double = 0
    var yellow: Double = 0
    var gamma: GammaSetting = .g2_2
    var style: ColorAdjustStyle = .slideBar
    static let range: ClosedRange<Double> = -25...25
}

// MARK: - Advanced

enum AutoCut: String, CaseIterable, Codable, Identifiable {
    case off, normalCut
    var id: String { rawValue }
    var label: String { self == .off ? "Off" : "Normal Cut" }
    /// IPP `finishings` values in preference order: 3 none; 11 trim, then 60 after pages,
    /// 62 after copies, 61 after documents, 63 after job. The first the printer lists is sent.
    var ippFinishings: [Int] { self == .off ? [3] : [11, 60, 62, 61, 63] }
}

struct AdvancedSettings: Codable, Hashable {
    var autoCut: AutoCut = .normalCut
    var autoRotate: Bool = true
    var printPageLine: Bool = false
    var saveRollPaper: Bool = false
    var densityBlack: Double = 0
    var densityColor: Double = 0
    static let densityRange: ClosedRange<Double> = -50...50
}

// MARK: - Layout (macOS Layout pane + Windows page layout)

enum PagesPerSheet: Int, CaseIterable, Codable, Identifiable {
    case one = 1, two = 2, four = 4, six = 6, nine = 9, sixteen = 16
    var id: Int { rawValue }
    var label: String { "\(rawValue)" }
    var ippNumberUp: Int { rawValue }
}

enum LayoutDirection: String, CaseIterable, Codable, Identifiable {
    case leftRightTopBottom, rightLeftTopBottom, topBottomLeftRight, topBottomRightLeft
    var id: String { rawValue }
    var label: String {
        switch self {
        case .leftRightTopBottom: "Left→Right, Top→Bottom"
        case .rightLeftTopBottom: "Right→Left, Top→Bottom"
        case .topBottomLeftRight: "Top→Bottom, Left→Right"
        case .topBottomRightLeft: "Top→Bottom, Right→Left"
        }
    }
    var ippNumberUpLayout: String {
        switch self {
        case .leftRightTopBottom: "lrtb"
        case .rightLeftTopBottom: "rltb"
        case .topBottomLeftRight: "tblr"
        case .topBottomRightLeft: "tbrl"
        }
    }
}

enum PageBorder: String, CaseIterable, Codable, Identifiable {
    case none, singleHairline, singleThin, doubleHairline, doubleThin
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "None"
        case .singleHairline: "Single Hairline"
        case .singleThin: "Single Thin Line"
        case .doubleHairline: "Double Hairline"
        case .doubleThin: "Double Thin Line"
        }
    }
}

enum PosterSplit: Int, CaseIterable, Codable, Identifiable {
    case off = 1, twoByTwo = 2, threeByThree = 3, fourByFour = 4
    var id: Int { rawValue }
    var label: String { self == .off ? "Off" : "\(rawValue)×\(rawValue)" }
}

struct LayoutSettings: Codable, Hashable {
    var pagesPerSheet: PagesPerSheet = .one
    var layoutDirection: LayoutDirection = .leftRightTopBottom
    var border: PageBorder = .none
    var reversePageOrientation: Bool = false
    var flipHorizontally: Bool = false
    // Windows-only extras
    var poster: PosterSplit = .off
    var posterOverlapMM: Double = 0
}

// MARK: - Paper Handling

enum PagesToPrint: String, CaseIterable, Codable, Identifiable {
    case all, oddOnly, evenOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All pages"
        case .oddOnly: "Odd only"
        case .evenOnly: "Even only"
        }
    }
}

enum PageOrder: String, CaseIterable, Codable, Identifiable {
    case automatic, normal, reverse
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .normal: "Normal"
        case .reverse: "Reverse"
        }
    }
}

struct PaperHandlingSettings: Codable, Hashable {
    var collate: Bool = true
    var pagesToPrint: PagesToPrint = .all
    var pageOrder: PageOrder = .automatic
    var scaleToFitPaperSize: Bool = false
    var destinationPaperSize: PaperSize? = nil
    var scaleDownOnly: Bool = false
}

// MARK: - Color Matching

enum ColorMatching: String, CaseIterable, Codable, Identifiable {
    case colorSync, epsonColorControls
    var id: String { rawValue }
    var label: String { self == .colorSync ? "ColorSync" : "EPSON Color Controls" }
}

// MARK: - Page range

enum PageRange: Codable, Hashable {
    case all
    case range(from: Int, to: Int)
    case selection([Int])

    /// IPP `page-ranges` (rangeOfInteger list); nil means all pages.
    var ippPageRanges: [ClosedRange<Int>]? {
        switch self {
        case .all: nil
        case .range(let f, let t): [min(f, t)...max(f, t)]
        case .selection(let pages): pages.sorted().map { $0...$0 }
        }
    }
}

// MARK: - Aggregate

struct PrintSettings: Codable, Hashable {
    // Basic
    var copies: Int = 1
    var pageRange: PageRange = .all
    var paperSize: PaperSize = PaperSize.standard[0]
    var customPaperSize: PaperSize? = nil
    var orientation: Orientation = .portrait
    var outputSize: OutputSizeMode = .sameAsPaperSize
    var specifiedOutputSize: PaperSize? = nil
    var retainScalePercent: Double = 100
    var bannerLengthMM: Double = 1000
    var paperSource: PaperSource = .rollPaper
    var rollWidth: RollWidth = .w24in
    var mediaType: MediaType = .usePrinterSettings
    var selectTarget: SelectTarget = .plainDocument
    var simpleSettings: Bool = true
    var printWithHighQuality: Bool = false
    // Shown when Simple Settings is off
    var printMode: PrintMode = .color
    var colorMode: ColorMode = .epsonStandardSRGB
    var colorControls = ColorControls()
    var level: QualityLevel = .quality
    var emphasizeThinLines: Bool = false
    // Other panes
    var advanced = AdvancedSettings()
    var layout = LayoutSettings()
    var paperHandling = PaperHandlingSettings()
    var colorMatching: ColorMatching = .epsonColorControls

    /// Paper size after any custom override.
    var effectivePaperSize: PaperSize { customPaperSize ?? paperSize }
}

/// Mac driver "Presets" menu entry.
struct SettingsPreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var settings: PrintSettings
}

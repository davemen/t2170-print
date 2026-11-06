import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Errors that can occur when loading a `PageSource` from disk.
enum PageSourceError: Error, LocalizedError, Sendable, Equatable {
    case unreadableFile(URL)
    case invalidPDF(URL)
    case invalidImageSource(URL)
    case emptyDocument(URL)
    case locked(URL)

    var errorDescription: String? {
        switch self {
        case .unreadableFile(let url):
            "Unable to read file at \(url.lastPathComponent)."
        case .invalidPDF(let url):
            "Invalid PDF document at \(url.lastPathComponent)."
        case .invalidImageSource(let url):
            "Unsupported or corrupted image file at \(url.lastPathComponent)."
        case .emptyDocument(let url):
            "Document at \(url.lastPathComponent) contains no pages."
        case .locked(let url):
            "Document at \(url.lastPathComponent) is password protected."
        }
    }
}

/// Thread-safe, `Sendable` wrapper around `PDFDocument` that serialises PDFKit access with a lock.
final class PDFDocumentBox: @unchecked Sendable {
    private let document: PDFDocument
    private let lock = NSLock()

    /// Wraps an existing `PDFDocument`.
    init(document: PDFDocument) {
        self.document = document
    }

    /// Loads a `PDFDocument` from `url`.
    convenience init(url: URL) throws {
        guard let doc = PDFDocument(url: url) else {
            throw PageSourceError.invalidPDF(url)
        }
        if doc.isLocked {
            throw PageSourceError.locked(url)
        }
        guard doc.pageCount > 0 else {
            throw PageSourceError.emptyDocument(url)
        }
        self.init(document: doc)
    }

    /// Number of pages in the PDF document.
    var pageCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return document.pageCount
    }

    /// Media-box size in points for the page at `index`, accounting for `/Rotate`.
    func pageSizePt(_ index: Int) -> CGSize {
        lock.lock()
        defer { lock.unlock() }
        guard index >= 0, index < document.pageCount, let page = document.page(at: index) else {
            return .zero
        }
        let mediaBox = page.bounds(for: .mediaBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        if rotation == 90 || rotation == 270 {
            return CGSize(width: mediaBox.height, height: mediaBox.width)
        }
        return CGSize(width: mediaBox.width, height: mediaBox.height)
    }

    /// Rasterises the PDF page at `index` at `scale` (pixels per point) onto a white background, respecting `/Rotate`.
    func render(page index: Int, scale: CGFloat) -> CGImage? {
        render(page: index, scale: scale, sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Rasterises only `sourceRect` (normalised, top-left origin) of the page at `scale` pixels per point of the full page.
    func render(page index: Int, scale: CGFloat, sourceRect: CGRect) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        guard scale > 0, index >= 0, index < document.pageCount, let page = document.page(at: index) else {
            return nil
        }
        let pageSize = rotatedPageSize(of: page)
        guard pageSize.width > 0, pageSize.height > 0 else { return nil }

        let crop = sourceRect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !crop.isNull, crop.width > 0, crop.height > 0 else { return nil }

        let cropWidthPt = pageSize.width * crop.width
        let cropHeightPt = pageSize.height * crop.height
        let pixelWidth = max(1, Int((cropWidthPt * scale).rounded()))
        let pixelHeight = max(1, Int((cropHeightPt * scale).rounded()))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))

        context.saveGState()
        context.scaleBy(
            x: CGFloat(pixelWidth) / cropWidthPt,
            y: CGFloat(pixelHeight) / cropHeightPt
        )
        // Bitmap space is y-up; `crop` is top-left based, so the bottom edge sits at (1 - maxY).
        context.translateBy(x: -crop.minX * pageSize.width, y: -(1.0 - crop.maxY) * pageSize.height)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        return context.makeImage()
    }

    /// Draws the `sourceRect` (normalised, top-left origin) of page `index` as vectors into `rect`.
    /// `context` must be in a y-up coordinate space at the call site. Returns `false` if the page is unavailable.
    func draw(page index: Int, sourceRect: CGRect, in rect: CGRect, context: CGContext) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard index >= 0, index < document.pageCount, let page = document.page(at: index) else {
            return false
        }
        let pageSize = rotatedPageSize(of: page)
        let crop = sourceRect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard pageSize.width > 0, pageSize.height > 0,
              !crop.isNull, crop.width > 0, crop.height > 0,
              rect.width > 0, rect.height > 0 else {
            return false
        }
        let fullWidth = rect.width / crop.width
        let fullHeight = rect.height / crop.height

        context.saveGState()
        context.clip(to: rect)
        context.translateBy(
            x: rect.minX - crop.minX * fullWidth,
            y: rect.minY - (1.0 - crop.maxY) * fullHeight
        )
        context.scaleBy(x: fullWidth / pageSize.width, y: fullHeight / pageSize.height)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
        return true
    }

    private func rotatedPageSize(of page: PDFPage) -> CGSize {
        let mediaBox = page.bounds(for: .mediaBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        if rotation == 90 || rotation == 270 {
            return CGSize(width: mediaBox.height, height: mediaBox.width)
        }
        return CGSize(width: mediaBox.width, height: mediaBox.height)
    }
}

/// Thread-safe registry associating loaded `CGImage` instances with their source DPI metadata.
private final class ImageDPIRegistry: @unchecked Sendable {
    static let shared = ImageDPIRegistry()

    private final class Entry {
        let dpiX: CGFloat
        let dpiY: CGFloat
        init(dpiX: CGFloat, dpiY: CGFloat) {
            self.dpiX = dpiX
            self.dpiY = dpiY
        }
    }

    private let lock = NSLock()
    private let table = NSMapTable<AnyObject, Entry>(
        keyOptions: [.weakMemory, .objectPointerPersonality],
        valueOptions: [.strongMemory]
    )

    func setDPI(x: CGFloat, y: CGFloat, for image: CGImage) {
        lock.lock()
        defer { lock.unlock() }
        table.setObject(Entry(dpiX: x, dpiY: y), forKey: image)
    }

    func dpi(for image: CGImage) -> (x: CGFloat, y: CGFloat)? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = table.object(forKey: image) else { return nil }
        return (entry.dpiX, entry.dpiY)
    }
}

/// A multi-page printable source backed either by a PDF document or an array of raster images.
enum PageSource: Sendable {
    case pdf(PDFDocumentBox)
    case images([CGImage])

    /// Loads a `PageSource` from `url`, detecting PDF by `UTType` and falling back to `CGImageSource` (including multi-page HEIC/TIFF).
    static func load(url: URL) throws -> PageSource {
        let resourceType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        let extensionType = UTType(filenameExtension: url.pathExtension)
        let contentType = resourceType ?? extensionType

        if contentType?.conforms(to: .pdf) == true {
            return .pdf(try PDFDocumentBox(url: url))
        }

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PageSourceError.invalidImageSource(url)
        }
        let count = CGImageSourceGetCount(imageSource)
        guard count > 0 else {
            throw PageSourceError.emptyDocument(url)
        }

        var loadedImages: [CGImage] = []
        loadedImages.reserveCapacity(count)

        for index in 0..<count {
            guard var cgImage = CGImageSourceCreateImageAtIndex(imageSource, index, nil) else {
                continue
            }
            if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, index, nil) as? [CFString: Any] {
                // The decoder ignores the orientation tag, so an iPhone photo arrives on its side.
                let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
                var turned = false
                if (2...8).contains(orientation), let upright = uprightImage(cgImage, orientation: orientation) {
                    cgImage = upright
                    turned = orientation >= 5
                }
                let dpiWidth = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
                let dpiHeight = (properties[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue
                if let w = dpiWidth, let h = dpiHeight, w > 0, h > 0 {
                    ImageDPIRegistry.shared.setDPI(
                        x: CGFloat(turned ? h : w), y: CGFloat(turned ? w : h), for: cgImage)
                }
            }
            loadedImages.append(cgImage)
        }

        guard !loadedImages.isEmpty else {
            throw PageSourceError.invalidImageSource(url)
        }
        return .images(loadedImages)
    }

    /// Applies an EXIF orientation, keeping the image's RGB colour space when it has one.
    private static func uprightImage(_ image: CGImage, orientation: Int32) -> CGImage? {
        let upright = CIImage(cgImage: image).oriented(forExifOrientation: orientation)
        let space = image.colorSpace?.model == .rgb ? image.colorSpace : CGColorSpace(name: CGColorSpace.sRGB)
        guard let space else { return nil }
        return CIContext().createCGImage(upright, from: upright.extent, format: .RGBA8, colorSpace: space)
    }

    /// True for a PDF, whose pages can be rendered a region at a time.
    var isPDF: Bool {
        if case .pdf = self { return true }
        return false
    }

    /// Total number of pages in the source.
    var pageCount: Int {
        switch self {
        case .pdf(let box):
            box.pageCount
        case .images(let images):
            images.count
        }
    }

    /// Size of the page at `index` in points (72 pt/in).
    func pageSizePt(_ index: Int) -> CGSize {
        switch self {
        case .pdf(let box):
            return box.pageSizePt(index)
        case .images(let images):
            guard images.indices.contains(index) else { return .zero }
            let image = images[index]
            if let dpi = ImageDPIRegistry.shared.dpi(for: image), dpi.x > 0, dpi.y > 0 {
                return CGSize(
                    width: CGFloat(image.width) * 72.0 / dpi.x,
                    height: CGFloat(image.height) * 72.0 / dpi.y
                )
            }
            return CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        }
    }

    /// Renders the page at `index` at `scale` (pixels per point) for PDFs, or returns the underlying `CGImage` directly for image sources.
    func render(page index: Int, scale: CGFloat) -> CGImage? {
        switch self {
        case .pdf(let box):
            return box.render(page: index, scale: scale)
        case .images(let images):
            guard images.indices.contains(index) else { return nil }
            let image = images[index]
            guard scale > 0, scale < 1 else { return image }
            let size = pageSizePt(index)
            let targetMax = (max(size.width, size.height) * scale).rounded(.up)
            let nativeMax = CGFloat(max(image.width, image.height))
            guard targetMax >= 1, targetMax < nativeMax else { return image }
            return Self.downsample(image, maxPixel: targetMax) ?? image
        }
    }

    /// Renders only `sourceRect` (normalised, top-left origin) of the page at `scale` pixels per point of the full page.
    func render(page index: Int, scale: CGFloat, sourceRect: CGRect) -> CGImage? {
        switch self {
        case .pdf(let box):
            return box.render(page: index, scale: scale, sourceRect: sourceRect)
        case .images:
            guard let image = render(page: index, scale: scale) else { return nil }
            if sourceRect == CGRect(x: 0, y: 0, width: 1, height: 1) { return image }
            let imgW = CGFloat(image.width)
            let imgH = CGFloat(image.height)
            let cropRect = CGRect(
                x: sourceRect.minX * imgW,
                y: sourceRect.minY * imgH,
                width: sourceRect.width * imgW,
                height: sourceRect.height * imgH
            ).integral
            if cropRect.width > 0, cropRect.height > 0, let cropped = image.cropping(to: cropRect) {
                return cropped
            }
            return image
        }
    }

    /// Draws a PDF page (or part of it) as vectors into `rect` of a y-up `context`.
    /// Returns `false` for image sources or unavailable pages, so the caller can fall back to rasterising.
    func drawVector(page index: Int, sourceRect: CGRect, in rect: CGRect, context: CGContext) -> Bool {
        switch self {
        case .pdf(let box):
            return box.draw(page: index, sourceRect: sourceRect, in: rect, context: context)
        case .images:
            return false
        }
    }

    /// Downsamples `image` so its longest edge is `maxPixel`, drawing with high-quality interpolation.
    /// (ImageIO thumbnails need an image source, and the sources here are already decoded `CGImage`s;
    /// re-encoding each one per render would cost more than it saves.)
    private static func downsample(_ image: CGImage, maxPixel: CGFloat) -> CGImage? {
        let longest = CGFloat(max(image.width, image.height))
        let ratio = maxPixel / longest
        let width = max(1, Int((CGFloat(image.width) * ratio).rounded()))
        let height = max(1, Int((CGFloat(image.height) * ratio).rounded()))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

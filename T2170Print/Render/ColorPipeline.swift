import CoreGraphics
import CoreImage
import Foundation

/// Applies the Epson T2170 colour modes, colour controls, print modes, ink density, and thin-line enhancement in sRGB space.
struct ColorPipeline: Sendable {
    /// Applies all active colour and tone adjustments in `settings` to `image` using `context`, skipping filters at neutral values.
    static func apply(_ settings: PrintSettings, to image: CGImage, context: CIContext) -> CGImage {
        if isNeutral(settings) {
            return image
        }

        let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var current = CIImage(cgImage: image, options: [.colorSpace: image.colorSpace ?? sRGB])
        let extent = current.extent

        // 1. Color Mode preset + Color Controls (brightness, contrast, saturation)
        let (presetContrast, presetSaturation) = presetOffsets(for: settings.colorMode)
        let totalBrightness = settings.colorControls.brightness
        let totalContrast = settings.colorControls.contrast + presetContrast
        let totalSaturation = settings.colorControls.saturation + presetSaturation

        if totalBrightness != 0 || totalContrast != 0 || totalSaturation != 0 {
            if let filter = CIFilter(name: "CIColorControls") {
                filter.setValue(current, forKey: kCIInputImageKey)
                filter.setValue(NSNumber(value: totalBrightness / 100.0), forKey: kCIInputBrightnessKey)
                filter.setValue(NSNumber(value: max(0.0, 1.0 + totalContrast / 50.0)), forKey: kCIInputContrastKey)
                filter.setValue(NSNumber(value: max(0.0, 1.0 + totalSaturation / 25.0)), forKey: kCIInputSaturationKey)
                if let output = filter.outputImage {
                    current = output
                }
            }
        }

        if settings.colorMode == .lineDrawing {
            current = applyLineDrawingCrush(to: current)
        }

        // 2. Cyan / Magenta / Yellow via complementary RGB channel scaling in CIColorMatrix
        let cyan = settings.colorControls.cyan
        let magenta = settings.colorControls.magenta
        let yellow = settings.colorControls.yellow
        if cyan != 0 || magenta != 0 || yellow != 0 {
            let rScale = CGFloat(max(0.0, 1.0 - cyan / 50.0))
            let gScale = CGFloat(max(0.0, 1.0 - magenta / 50.0))
            let bScale = CGFloat(max(0.0, 1.0 - yellow / 50.0))
            if let matrix = CIFilter(name: "CIColorMatrix") {
                matrix.setValue(current, forKey: kCIInputImageKey)
                matrix.setValue(CIVector(x: rScale, y: 0, z: 0, w: 0), forKey: "inputRVector")
                matrix.setValue(CIVector(x: 0, y: gScale, z: 0, w: 0), forKey: "inputGVector")
                matrix.setValue(CIVector(x: 0, y: 0, z: bScale, w: 0), forKey: "inputBVector")
                matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
                matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
                if let output = matrix.outputImage {
                    current = applyClamp(to: output)
                }
            }
        }

        // 3. Gamma adjustment (2.2 is neutral; 1.8 uses power 1.8 / 2.2)
        if settings.colorControls.gamma == .g1_8 {
            if let gamma = CIFilter(name: "CIGammaAdjust") {
                gamma.setValue(current, forKey: kCIInputImageKey)
                gamma.setValue(NSNumber(value: 1.8 / 2.2), forKey: "inputPower")
                if let output = gamma.outputImage {
                    current = output
                }
            }
        }

        // 4. Ink density (black / color, -50...50%) via a power curve that keeps white fixed.
        //    Positive density darkens (power > 1), negative lightens (power < 1).
        let densityBlack = settings.advanced.densityBlack
        let densityColor = settings.advanced.densityColor
        if densityBlack != 0 || densityColor != 0 {
            let effectiveDensity: Double
            switch settings.printMode {
            case .black, .blackBiLevel:
                effectiveDensity = densityBlack
            case .color, .coloredPaperYellow:
                effectiveDensity = (densityBlack + densityColor) / 2.0
            }
            if effectiveDensity != 0, let gamma = CIFilter(name: "CIGammaAdjust") {
                let k = 0.02 // +/-25 -> power 1.5 or 0.67
                let magnitude = abs(effectiveDensity) * k
                let power = effectiveDensity > 0 ? 1.0 + magnitude : 1.0 / (1.0 + magnitude)
                gamma.setValue(current, forKey: kCIInputImageKey)
                gamma.setValue(NSNumber(value: power), forKey: "inputPower")
                if let output = gamma.outputImage {
                    current = output
                }
            }
        }

        // 5. Emphasize thin lines (CIMorphologyMinimum radius 1 on luminance, then composite)
        if settings.emphasizeThinLines {
            current = applyThinLineEmphasis(to: current, extent: extent)
        }

        // 6. Print Mode (color, black, blackBiLevel, coloredPaperYellow)
        switch settings.printMode {
        case .color:
            break
        case .black:
            current = applyMonochromeLuminance(to: current)
        case .blackBiLevel:
            let mono = applyMonochromeLuminance(to: current)
            current = applyThreshold50Percent(to: mono)
        case .coloredPaperYellow:
            if let matrix = CIFilter(name: "CIColorMatrix") {
                matrix.setValue(current, forKey: kCIInputImageKey)
                matrix.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
                matrix.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
                matrix.setValue(CIVector(x: 0, y: 0, z: 0.7, w: 0), forKey: "inputBVector")
                matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
                matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
                if let output = matrix.outputImage {
                    current = output
                }
            }
        }

        let cropped = current.cropped(to: extent)
        return context.createCGImage(cropped, from: extent, format: .RGBA8, colorSpace: sRGB) ?? image
    }

    // MARK: - Helpers

    static func isNeutral(_ settings: PrintSettings) -> Bool {
        let modeNeutral = settings.colorMode == .epsonStandardSRGB || settings.colorMode == .off
        let cc = settings.colorControls
        let controlsNeutral = cc.brightness == 0
            && cc.contrast == 0
            && cc.saturation == 0
            && cc.cyan == 0
            && cc.magenta == 0
            && cc.yellow == 0
            && cc.gamma == .g2_2
        let printModeNeutral = settings.printMode == .color
        let densityNeutral = settings.advanced.densityBlack == 0 && settings.advanced.densityColor == 0
        return modeNeutral && controlsNeutral && printModeNeutral && densityNeutral && !settings.emphasizeThinLines
    }

    private static func presetOffsets(for mode: ColorMode) -> (contrast: Double, saturation: Double) {
        switch mode {
        case .epsonStandardSRGB, .off:
            return (0, 0)
        case .businessGraphics:
            return (contrast: 5, saturation: 10)
        case .lineDrawing:
            return (contrast: 15, saturation: -10)
        case .gis:
            return (contrast: 0, saturation: 5)
        }
    }

    private static func applyLineDrawingCrush(to image: CIImage) -> CIImage {
        guard let matrix = CIFilter(name: "CIColorMatrix") else { return image }
        let slope: CGFloat = 1.35
        let bias: CGFloat = -0.2
        matrix.setValue(image, forKey: kCIInputImageKey)
        matrix.setValue(CIVector(x: slope, y: 0, z: 0, w: 0), forKey: "inputRVector")
        matrix.setValue(CIVector(x: 0, y: slope, z: 0, w: 0), forKey: "inputGVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: slope, w: 0), forKey: "inputBVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        matrix.setValue(CIVector(x: bias, y: bias, z: bias, w: 0), forKey: "inputBiasVector")
        guard let output = matrix.outputImage else { return image }
        return applyClamp(to: output)
    }

    private static func applyMonochromeLuminance(to image: CIImage) -> CIImage {
        // Not CIColorMonochrome: with a white tint it printed pure green as white and other colours
        // about twice too light.
        guard let matrix = CIFilter(name: "CIColorMatrix") else { return image }
        let luma = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        matrix.setValue(image, forKey: kCIInputImageKey)
        matrix.setValue(luma, forKey: "inputRVector")
        matrix.setValue(luma, forKey: "inputGVector")
        matrix.setValue(luma, forKey: "inputBVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
        return matrix.outputImage ?? image
    }

    private static func applyThreshold50Percent(to image: CIImage) -> CIImage {
        if let threshold = CIFilter(name: "CIColorThreshold") {
            threshold.setValue(image, forKey: kCIInputImageKey)
            threshold.setValue(NSNumber(value: 0.5), forKey: "inputThreshold")
            if let output = threshold.outputImage {
                return output
            }
        }
        guard let matrix = CIFilter(name: "CIColorMatrix") else { return image }
        let gain: CGFloat = 1000.0
        let bias: CGFloat = -500.0
        matrix.setValue(image, forKey: kCIInputImageKey)
        matrix.setValue(CIVector(x: gain, y: 0, z: 0, w: 0), forKey: "inputRVector")
        matrix.setValue(CIVector(x: 0, y: gain, z: 0, w: 0), forKey: "inputGVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: gain, w: 0), forKey: "inputBVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        matrix.setValue(CIVector(x: bias, y: bias, z: bias, w: 0), forKey: "inputBiasVector")
        guard let output = matrix.outputImage else { return image }
        return applyClamp(to: output)
    }

    private static func applyThinLineEmphasis(to image: CIImage, extent: CGRect) -> CIImage {
        let luminance = applyMonochromeLuminance(to: image)
        guard let morphology = CIFilter(name: "CIMorphologyMinimum") else { return image }
        morphology.setValue(luminance.clampedToExtent(), forKey: kCIInputImageKey)
        morphology.setValue(NSNumber(value: 1.0), forKey: kCIInputRadiusKey)
        guard let eroded = morphology.outputImage?.cropped(to: extent) else { return image }

        guard let darken = CIFilter(name: "CIDarkenBlendMode") else { return eroded }
        darken.setValue(eroded, forKey: kCIInputImageKey)
        darken.setValue(image, forKey: kCIInputBackgroundImageKey)
        return darken.outputImage?.cropped(to: extent) ?? image
    }

    private static func applyClamp(to image: CIImage) -> CIImage {
        guard let clamp = CIFilter(name: "CIColorClamp") else { return image }
        clamp.setValue(image, forKey: kCIInputImageKey)
        clamp.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputMinComponents")
        clamp.setValue(CIVector(x: 1, y: 1, z: 1, w: 1), forKey: "inputMaxComponents")
        return clamp.outputImage ?? image
    }
}

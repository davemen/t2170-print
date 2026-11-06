import SwiftUI

struct ColorControlsView: View {
    @Bindable var session: PrintSession

    private static let cyanAngle = 0.0
    private static let magentaAngle = 2.0 * Double.pi / 3.0
    private static let yellowAngle = 4.0 * Double.pi / 3.0
    private static let maxOffset = 25.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Color Adjustment", selection: $session.settings.colorControls.style) {
                ForEach(ColorAdjustStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)

            if session.settings.colorControls.style == .colorCircle {
                colorCircleSection
                toneSlidersSection
            } else {
                toneSlidersSection
                cmySlidersSection
            }

            LabeledContent("Gamma") {
                Picker("Gamma", selection: $session.settings.colorControls.gamma) {
                    ForEach(GammaSetting.allCases) { gamma in
                        Text(gamma.label).tag(gamma)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 180)
            }

            HStack {
                Spacer()
                Button("Reset") {
                    resetControls()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    private var toneSlidersSection: some View {
        VStack(spacing: 10) {
            sliderRow(title: "Brightness", value: $session.settings.colorControls.brightness)
            sliderRow(title: "Contrast", value: $session.settings.colorControls.contrast)
            sliderRow(title: "Saturation", value: $session.settings.colorControls.saturation)
        }
    }

    private var cmySlidersSection: some View {
        VStack(spacing: 10) {
            sliderRow(title: "Cyan", value: $session.settings.colorControls.cyan)
            sliderRow(title: "Magenta", value: $session.settings.colorControls.magenta)
            sliderRow(title: "Yellow", value: $session.settings.colorControls.yellow)
        }
    }

    private var colorCircleSection: some View {
        VStack(spacing: 8) {
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                let radius = max(1.0, (side - 36.0) / 2.0)
                let center = CGPoint(x: proxy.size.width / 2.0, y: proxy.size.height / 2.0)

                Canvas { context, size in
                    let canvasCenter = CGPoint(x: size.width / 2.0, y: size.height / 2.0)
                    drawHueWheel(context: &context, center: canvasCenter, radius: radius)
                    drawAxes(context: &context, center: canvasCenter, radius: radius)
                    drawHandle(context: &context, center: canvasCenter, radius: radius)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            updateCMYFromDrag(location: gesture.location, center: center, radius: radius)
                        }
                )
            }
            .frame(height: 220)

            HStack(spacing: 16) {
                Text("C: \(Int(session.settings.colorControls.cyan.rounded()))")
                Text("M: \(Int(session.settings.colorControls.magenta.rounded()))")
                Text("Y: \(Int(session.settings.colorControls.yellow.rounded()))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func sliderRow(title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 90, alignment: .leading)
            Slider(value: value, in: ColorControls.range, step: 1)
            Text("\(Int(value.wrappedValue.rounded()))")
                .font(.body.monospacedDigit())
                .frame(width: 36, alignment: .trailing)
        }
    }

    private func drawHueWheel(context: inout GraphicsContext, center: CGPoint, radius: Double) {
        let segments = 120
        for i in 0..<segments {
            let startAngle = Double(i) / Double(segments) * 2.0 * Double.pi
            let endAngle = Double(i + 1) / Double(segments) * 2.0 * Double.pi
            let midDegrees = (Double(i) + 0.5) / Double(segments) * 360.0
            let hue = ((midDegrees + 180.0).truncatingRemainder(dividingBy: 360.0)) / 360.0

            var wedge = Path()
            wedge.move(to: center)
            wedge.addArc(
                center: center,
                radius: radius,
                startAngle: .radians(startAngle),
                endAngle: .radians(endAngle),
                clockwise: false
            )
            wedge.closeSubpath()

            let gradient = Gradient(colors: [
                .white,
                Color(hue: hue, saturation: 0.85, brightness: 0.95)
            ])
            let midAngle = (startAngle + endAngle) / 2.0
            let outerPoint = CGPoint(
                x: center.x + cos(midAngle) * radius,
                y: center.y + sin(midAngle) * radius
            )
            context.fill(
                wedge,
                with: .linearGradient(gradient, startPoint: center, endPoint: outerPoint)
            )
        }

        let borderRect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2.0,
            height: radius * 2.0
        )
        context.stroke(
            Path(ellipseIn: borderRect),
            with: .color(.secondary.opacity(0.6)),
            lineWidth: 1.5
        )
    }

    private func drawAxes(context: inout GraphicsContext, center: CGPoint, radius: Double) {
        let axes: [(String, Double)] = [
            ("C", Self.cyanAngle),
            ("B", Double.pi / 3.0),
            ("M", Self.magentaAngle),
            ("R", Double.pi),
            ("Y", Self.yellowAngle),
            ("G", 5.0 * Double.pi / 3.0)
        ]

        for (label, angle) in axes {
            let end = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            var line = Path()
            line.move(to: center)
            line.addLine(to: end)
            context.stroke(
                line,
                with: .color(.primary.opacity(0.25)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )

            let labelPos = CGPoint(
                x: center.x + cos(angle) * (radius + 12.0),
                y: center.y + sin(angle) * (radius + 12.0)
            )
            context.draw(
                Text(label).font(.caption2.bold()).foregroundStyle(.secondary),
                at: labelPos
            )
        }
    }

    private func drawHandle(context: inout GraphicsContext, center: CGPoint, radius: Double) {
        let c = session.settings.colorControls.cyan
        let m = session.settings.colorControls.magenta
        let y = session.settings.colorControls.yellow

        let normX = (2.0 / 3.0) * (
            c * cos(Self.cyanAngle) +
            m * cos(Self.magentaAngle) +
            y * cos(Self.yellowAngle)
        ) / Self.maxOffset

        let normY = (2.0 / 3.0) * (
            c * sin(Self.cyanAngle) +
            m * sin(Self.magentaAngle) +
            y * sin(Self.yellowAngle)
        ) / Self.maxOffset

        let dist = hypot(normX, normY)
        let scale = dist > 1.0 ? (1.0 / dist) : 1.0
        let handleCenter = CGPoint(
            x: center.x + normX * scale * radius,
            y: center.y + normY * scale * radius
        )

        let handleRadius = 7.0
        let handleRect = CGRect(
            x: handleCenter.x - handleRadius,
            y: handleCenter.y - handleRadius,
            width: handleRadius * 2.0,
            height: handleRadius * 2.0
        )
        context.fill(Path(ellipseIn: handleRect), with: .color(.white))
        context.stroke(Path(ellipseIn: handleRect), with: .color(.black), lineWidth: 2)
    }

    private func updateCMYFromDrag(location: CGPoint, center: CGPoint, radius: Double) {
        let rawDX = (location.x - center.x) / radius
        let rawDY = (location.y - center.y) / radius
        let dist = hypot(rawDX, rawDY)
        let clampedScale = dist > 1.0 ? (1.0 / dist) : 1.0
        let vx = rawDX * clampedScale * Self.maxOffset
        let vy = rawDY * clampedScale * Self.maxOffset

        let c = vx * cos(Self.cyanAngle) + vy * sin(Self.cyanAngle)
        let m = vx * cos(Self.magentaAngle) + vy * sin(Self.magentaAngle)
        let y = vx * cos(Self.yellowAngle) + vy * sin(Self.yellowAngle)

        session.settings.colorControls.cyan = min(Self.maxOffset, max(-Self.maxOffset, c.rounded()))
        session.settings.colorControls.magenta = min(Self.maxOffset, max(-Self.maxOffset, m.rounded()))
        session.settings.colorControls.yellow = min(Self.maxOffset, max(-Self.maxOffset, y.rounded()))
    }

    private func resetControls() {
        let currentStyle = session.settings.colorControls.style
        var reset = ColorControls()
        reset.style = currentStyle
        session.settings.colorControls = reset
    }
}

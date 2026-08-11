import SwiftUI

/// The Loom web console's agent-activity ring, ported from `app.css`:
///
/// - `.is-working`  → a conic-gradient ring rotating around the row
///   (`@keyframes loom-ring-spin`, 1.8s linear infinite): a steady
///   "something is happening here" light.
/// - `.is-finished` → the same ring as a solid indigo→green gradient that
///   blinks (`@keyframes loom-ring-blink`, opacity 1 → 0.12, 1.1s):
///   the flicker that says "this one wants you now".
/// The web console's palette (`app.css` `:root`), so the desktop app and the
/// browser read as the same product.
enum LoomColors {
    private static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// `--accent`
    static let accent = hex(0x4F46E5)
    /// The green the rings resolve to.
    static let green = hex(0x22C55E)
    /// `--accent-soft`
    static let accentSoft = hex(0xEEF2FF)
    /// `--bg-base` — the warm cream the whole console sits on.
    static let bgBase = hex(0xF7F5EF)
    /// `--bg-elev-1`
    static let bgElev1 = Color.white
    /// `--bg-elev-2`
    static let bgElev2 = hex(0xF4F2EC)
    /// `--border`
    static let border = hex(0xE8E4DA)
    /// `--border-strong`
    static let borderStrong = hex(0xD6D1C3)
    static let amber = hex(0xF59E0B)
    static let red = hex(0xEF4444)
}

/// Rotating conic ring: transparent for the first 140°, then fading in
/// through soft indigo to full accent and green before cutting back to
/// transparent — the exact stop layout of the web gradient.
struct LoomSpinningRing<S: InsettableShape>: View {
    var shape: S
    var lineWidth: CGFloat = 2
    /// Matches the web animation's 1.8s per revolution.
    var lapDuration: Double = 1.8

    /// Driven by one Core Animation rotation rather than `TimelineView`.
    /// TimelineView re-evaluates the view body every frame, and a dock with a
    /// dozen working tasks then re-renders SwiftUI 120 times a second — the
    /// app felt sluggish everywhere, not just on the dock. A rotation runs on
    /// the render server and costs nothing per frame.
    @State private var spinning = false

    private static var gradientStops: [Gradient.Stop] {
        [
            .init(color: .clear, location: 0),
            .init(color: .clear, location: 140.0 / 360.0),
            .init(color: LoomColors.accent.opacity(0.22), location: 210.0 / 360.0),
            .init(color: LoomColors.accent, location: 300.0 / 360.0),
            .init(color: LoomColors.green, location: 348.0 / 360.0),
            .init(color: .clear, location: 1),
        ]
    }

    var body: some View {
        GeometryReader { geometry in
            // The gradient layer is rotated, not the shape, so a stretched
            // capsule keeps its outline. Oversized so its square corners
            // never rotate into view.
            let side = max(geometry.size.width, geometry.size.height) * 1.5
            AngularGradient(stops: Self.gradientStops, center: .center)
                .frame(width: side, height: side)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .mask(shape.strokeBorder(lineWidth: lineWidth))
        .onAppear {
            guard !spinning else { return }
            withAnimation(.linear(duration: lapDuration).repeatForever(autoreverses: false)) {
                spinning = true
            }
        }
    }
}

/// The same ring, frozen. Used past the dock's animation budget: thirty
/// simultaneously animating pills cost real CPU and read as noise, while a
/// static ring still marks the state.
struct LoomStaticRing<S: InsettableShape>: View {
    var shape: S
    var lineWidth: CGFloat = 2
    var finished = false

    var body: some View {
        shape.strokeBorder(
            finished
                ? AnyShapeStyle(LinearGradient(
                    colors: [LoomColors.accent, LoomColors.green],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                : AnyShapeStyle(AngularGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.39),
                        .init(color: LoomColors.accent.opacity(0.22), location: 0.58),
                        .init(color: LoomColors.accent, location: 0.83),
                        .init(color: LoomColors.green, location: 0.97),
                        .init(color: .clear, location: 1),
                    ],
                    center: .center
                )),
            lineWidth: lineWidth
        )
    }
}

/// Blinking finished ring: solid indigo→green gradient whose opacity pulses
/// between 1 and 0.12 on the web's 1.1s ease-in-out cycle.
struct LoomBlinkingRing<S: InsettableShape>: View {
    var shape: S
    var lineWidth: CGFloat = 2
    var blinkDuration: Double = 1.1

    @State private var dimmed = false

    var body: some View {
        shape
            .strokeBorder(
                LinearGradient(
                    colors: [LoomColors.accent, LoomColors.green],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: lineWidth
            )
            .opacity(dimmed ? 0.12 : 1)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: blinkDuration / 2).repeatForever(autoreverses: true)
                ) {
                    dimmed = true
                }
            }
    }
}

/// "This one is running", for a header or a status line — one or two on
/// screen at a time.
///
/// The pulse runs on a `CALayer`, not on SwiftUI state. A `repeatForever`
/// animation over `@State` makes SwiftUI re-evaluate and re-render the view
/// graph every single frame, and because this dot lives in the task header,
/// that meant the sidebar, the terminal and the plan preview were all being
/// re-rendered at display rate for as long as any agent was working — about a
/// quarter of a core, spent on one blinking dot. Core Animation runs the same
/// pulse on the render server for free.
struct LoomSpinnerDot: View {
    var size: CGFloat = 14

    var body: some View {
        PulsingDot(diameter: size * 0.62, color: NSColor(LoomColors.accent))
            .frame(width: size, height: size)
    }
}

private struct PulsingDot: NSViewRepresentable {
    let diameter: CGFloat
    let color: NSColor

    func makeNSView(context: Context) -> PulsingDotView {
        PulsingDotView(diameter: diameter, color: color)
    }

    func updateNSView(_ view: PulsingDotView, context: Context) {
        view.apply(diameter: diameter, color: color)
    }
}

/// Owns the pulsing layer. The animation is re-attached whenever the view
/// joins a window, because Core Animation drops animations from layers that
/// leave the hierarchy — switching tabs would otherwise freeze the dot.
final class PulsingDotView: NSView {
    private let dot = CALayer()
    private var diameter: CGFloat
    private var color: NSColor

    init(diameter: CGFloat, color: NSColor) {
        self.diameter = diameter
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        dot.backgroundColor = color.cgColor
        layer?.addSublayer(dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(diameter: CGFloat, color: NSColor) {
        guard diameter != self.diameter || color != self.color else { return }
        self.diameter = diameter
        self.color = color
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = CGRect(
            x: (bounds.width - diameter) / 2,
            y: (bounds.height - diameter) / 2,
            width: diameter,
            height: diameter
        )
        dot.cornerRadius = diameter / 2
        dot.backgroundColor = color.cgColor
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            dot.removeAnimation(forKey: "pulse")
        } else if dot.animation(forKey: "pulse") == nil {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.6
            scale.toValue = 1.0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.45
            fade.toValue = 1.0
            let pulse = CAAnimationGroup()
            pulse.animations = [scale, fade]
            pulse.duration = 0.75
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(pulse, forKey: "pulse")
        }
    }
}

/// The same signal without the animation, for rows in a long list.
struct LoomActivityDot: View {
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(LoomColors.accent)
            .frame(width: size * 0.7, height: size * 0.7)
            .overlay(
                Circle()
                    .strokeBorder(LoomColors.accent.opacity(0.30), lineWidth: size * 0.15)
                    .frame(width: size, height: size)
            )
            .frame(width: size, height: size)
    }
}

/// "Finished while you were looking elsewhere", for a row in a list.
///
/// Blinking used to be a SwiftUI animation driven by a shared timer, which
/// meant the sidebar re-rendered the whole window at display rate for as long
/// as anything was waiting to be seen. The pulse is a layer animation now, so
/// it costs nothing per frame; rows stay in unison because every animation is
/// anchored to the same point on the clock rather than to when its row
/// appeared.
struct LoomBlinkDot: View {
    var size: CGFloat = 11

    var body: some View {
        BlinkingSymbol(
            symbol: "exclamationmark.circle.fill",
            pointSize: size,
            color: NSColor(LoomColors.amber)
        )
        .frame(width: size * 1.2, height: size * 1.2)
    }
}

private struct BlinkingSymbol: NSViewRepresentable {
    let symbol: String
    let pointSize: CGFloat
    let color: NSColor

    func makeNSView(context: Context) -> BlinkingSymbolView {
        BlinkingSymbolView(symbol: symbol, pointSize: pointSize, color: color)
    }

    func updateNSView(_ view: BlinkingSymbolView, context: Context) {}
}

final class BlinkingSymbolView: NSView {
    /// Matches the web console's `loom-ring-blink` half-cycle.
    static let interval: CFTimeInterval = 0.62

    private let tint = CALayer()
    private let glyph = CALayer()
    private let symbol: String
    private let pointSize: CGFloat
    private let color: NSColor

    init(symbol: String, pointSize: CGFloat, color: NSColor) {
        self.symbol = symbol
        self.pointSize = pointSize
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        tint.backgroundColor = color.cgColor
        tint.mask = glyph
        layer?.addSublayer(tint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint.frame = bounds
        glyph.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        loadGlyph()
    }

    private func loadGlyph() {
        let scale = window?.backingScaleFactor ?? 2
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return }
        var rect = CGRect(origin: .zero, size: image.size)
        glyph.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        glyph.contentsGravity = .resizeAspect
        glyph.contentsScale = scale
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            tint.removeAnimation(forKey: "blink")
            return
        }
        loadGlyph()
        guard tint.animation(forKey: "blink") == nil else { return }
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1.0
        blink.toValue = 0.2
        blink.duration = Self.interval
        blink.autoreverses = true
        blink.repeatCount = .infinity
        blink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Anchor to the shared cycle so rows blink together, however long
        // after each other they appeared.
        let now = tint.convertTime(CACurrentMediaTime(), from: nil)
        let cycle = Self.interval * 2
        blink.beginTime = now - now.truncatingRemainder(dividingBy: cycle)
        tint.add(blink, forKey: "blink")
    }
}

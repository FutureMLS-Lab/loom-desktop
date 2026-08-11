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

/// A pill's activity ring, drawn by Core Animation.
///
/// Working is the web console's conic gradient rotating once every 1.8s;
/// finished is the solid indigo→green ring blinking on the 1.1s cycle. Both
/// run on the render server, so a dock of forty pills costs the app nothing
/// per frame — which is why there is no longer a cap on how many may animate.
struct PillRing: NSViewRepresentable {
    enum Mode {
        case working
        case finished
    }

    let mode: Mode
    var lineWidth: CGFloat = 2.2

    func makeNSView(context: Context) -> PillRingView {
        PillRingView(mode: mode, lineWidth: lineWidth)
    }

    func updateNSView(_ view: PillRingView, context: Context) {
        view.apply(mode: mode)
    }
}

final class PillRingView: NSView {
    private let gradient = CAGradientLayer()
    private let ring = CAShapeLayer()
    private var mode: PillRing.Mode
    private let lineWidth: CGFloat

    init(mode: PillRing.Mode, lineWidth: CGFloat) {
        self.mode = mode
        self.lineWidth = lineWidth
        super.init(frame: .zero)
        wantsLayer = true
        // The ring masks the whole view, so the gradient can spin underneath
        // without the mask spinning with it.
        ring.fillColor = nil
        ring.strokeColor = NSColor.white.cgColor
        ring.lineWidth = lineWidth
        layer?.mask = ring
        layer?.addSublayer(gradient)
        applyGradient()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(mode: PillRing.Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        applyGradient()
        restartAnimation()
    }

    private func applyGradient() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch mode {
        case .working:
            gradient.type = .conic
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            gradient.colors = [
                NSColor.clear.cgColor,
                NSColor.clear.cgColor,
                NSColor(LoomColors.accent).withAlphaComponent(0.22).cgColor,
                NSColor(LoomColors.accent).cgColor,
                NSColor(LoomColors.green).cgColor,
                NSColor.clear.cgColor,
            ]
            gradient.locations = [0, 140, 210, 300, 348, 360].map {
                NSNumber(value: $0 / 360.0)
            }
        case .finished:
            gradient.type = .axial
            gradient.startPoint = CGPoint(x: 0, y: 0)
            gradient.endPoint = CGPoint(x: 1, y: 1)
            gradient.colors = [
                NSColor(LoomColors.accent).cgColor,
                NSColor(LoomColors.green).cgColor,
            ]
            gradient.locations = [0, 1]
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.path = CGPath(
            rect: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
            transform: nil
        )
        ring.frame = bounds
        switch mode {
        case .working:
            // Oversized and centred, so the gradient's square corners never
            // rotate into the ring.
            let side = max(bounds.width, bounds.height) * 1.5
            gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        case .finished:
            gradient.frame = bounds
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            gradient.removeAllAnimations()
        } else {
            restartAnimation()
        }
    }

    private func restartAnimation() {
        guard window != nil else { return }
        gradient.removeAllAnimations()
        switch mode {
        case .working:
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = 2 * Double.pi
            spin.duration = 1.8
            spin.repeatCount = .infinity
            gradient.add(spin, forKey: "spin")
        case .finished:
            let blink = CABasicAnimation(keyPath: "opacity")
            blink.fromValue = 1.0
            blink.toValue = 0.12
            blink.duration = 1.1 / 2
            blink.autoreverses = true
            blink.repeatCount = .infinity
            blink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            let now = gradient.convertTime(CACurrentMediaTime(), from: nil)
            blink.beginTime = now - now.truncatingRemainder(dividingBy: 1.1)
            gradient.add(blink, forKey: "blink")
        }
    }
}

/// The pill's own background, pulsing between two opacities of one colour.
/// Same reasoning as the ring: a layer animation instead of SwiftUI state.
struct PulsingFill: NSViewRepresentable {
    let color: NSColor
    var from: Float = 0.45
    var to: Float = 0.85
    var halfCycle: CFTimeInterval = 0.55

    func makeNSView(context: Context) -> PulsingFillView {
        PulsingFillView(color: color, from: from, to: to, halfCycle: halfCycle)
    }

    func updateNSView(_ view: PulsingFillView, context: Context) {}
}

final class PulsingFillView: NSView {
    private let fill = CALayer()
    private let from: Float
    private let to: Float
    private let halfCycle: CFTimeInterval

    init(color: NSColor, from: Float, to: Float, halfCycle: CFTimeInterval) {
        self.from = from
        self.to = to
        self.halfCycle = halfCycle
        super.init(frame: .zero)
        wantsLayer = true
        fill.backgroundColor = color.cgColor
        // The resting value, for the moments a layer carries no animation —
        // off-window, or before it is attached.
        fill.opacity = to
        layer?.addSublayer(fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            fill.removeAnimation(forKey: "pulse")
            return
        }
        guard fill.animation(forKey: "pulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = from
        pulse.toValue = to
        pulse.duration = halfCycle
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let now = fill.convertTime(CACurrentMediaTime(), from: nil)
        pulse.beginTime = now - now.truncatingRemainder(dividingBy: halfCycle * 2)
        fill.add(pulse, forKey: "pulse")
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

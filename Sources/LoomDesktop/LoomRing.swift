import SwiftUI

/// The web console's agent-activity rings, ported from `app.css` and drawn by
/// Core Animation.

/// The cadence for a blinking "finished, unseen" dot, so the sidebar and
/// quick-open say the same thing in step rather than as two separate alarms.
///
/// Slower than the web console's 1.1s: one thing flashing hard reads as "look
/// here", and a dozen of them at that speed reads as a fault.
///
/// A dock pill that has finished breathes on this same cycle, so a finished
/// task says the same thing at the same moment wherever it appears.
enum LoomBlink {
    static let cycle: CFTimeInterval = 1.6
    static var half: CFTimeInterval { cycle / 2 }
}

/// A dock pill's rim: indigo→cyan→green while the agent works, green→cyan
/// once it has finished, and on a finished one the rim blinks.
///
/// Fills the pill. The pill's own face is laid over the middle of it, and what
/// is left showing is the rim — a rim drawn as a rim would have to be masked,
/// and a masked layer is redrawn offscreen on every frame it changes.
///
/// The blink lives here, on the rim, rather than on a tint over the pill. A
/// finished pill used to pulse a wash of green across its whole face, which
/// read as a slab flashing behind the title rather than as a pill asking to
/// be looked at.
struct PillBand: NSViewRepresentable {
    enum Mode { case working, finished }

    /// How much of the band the pill's face leaves showing.
    static let rimWidth: CGFloat = 2.4

    let mode: Mode

    func makeNSView(context: Context) -> PillBandView { PillBandView(mode: mode) }

    func updateNSView(_ view: PillBandView, context: Context) { view.apply(mode: mode) }

}

final class PillBandView: NSView {
    private let band = CAGradientLayer()
    private var mode: PillBand.Mode

    init(mode: PillBand.Mode) {
        self.mode = mode
        super.init(frame: .zero)
        wantsLayer = true
        band.startPoint = CGPoint(x: 0, y: 1)
        band.endPoint = CGPoint(x: 1, y: 0)
        layer?.addSublayer(band)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(mode: PillBand.Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        applyColors()
        refreshBlink()
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch mode {
        case .working:
            band.colors = [
                DockPalette.rimAccent.cgColor,
                DockPalette.rimCyan.cgColor,
                DockPalette.rimGreen.cgColor,
            ]
            band.locations = [0, 0.55, 1]
        case .finished:
            band.colors = [DockPalette.rimGreen.cgColor, DockPalette.rimCyan.cgColor]
            band.locations = [0, 1]
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.frame = bounds
        CATransaction.commit()
        refreshBlink()
    }

    /// A `cgColor` is whatever the appearance was when it was read, so the
    /// layer keeps the old palette when the card flips light or dark unless
    /// it is poured in again.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            band.removeAllAnimations()
            blinking = false
        } else {
            refreshBlink()
        }
    }

    private var blinking = false

    private func refreshBlink() {
        guard window != nil else { return }
        let wanted = mode == .finished
        guard wanted != blinking || (wanted && band.animation(forKey: "blink") == nil) else { return }
        blinking = wanted
        band.removeAnimation(forKey: "blink")
        guard wanted else { return }
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1.0
        blink.toValue = 0.28
        blink.duration = LoomBlink.half
        blink.autoreverses = true
        blink.repeatCount = .infinity
        blink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Phase-locked to the wall clock so every finished pill, here and in
        // the sidebar, is dark at the same moment. A dozen of these out of
        // step reads as a fault rather than as a queue.
        let now = band.convertTime(CACurrentMediaTime(), from: nil)
        blink.beginTime = now - now.truncatingRemainder(dividingBy: LoomBlink.cycle)
        band.add(blink, forKey: "blink")
    }
}

/// The mote of light that runs round the inside of a working pill.
///
/// Everything that animates on a working pill is this one small layer, so
/// there is a single place to look when the dock starts costing something.
/// What it costs is not something the drawing predicts: measured against the
/// same dock holding still, this mote and a full-pill rotating gradient came
/// to the same 26 points of WindowServer, because the price was being paid by
/// the card's drop shadow rather than by anything here (see `DockView`).
struct PillMote: NSViewRepresentable {
    func makeNSView(context: Context) -> PillMoteView { PillMoteView() }

    func updateNSView(_ view: PillMoteView, context: Context) {}
}

final class PillMoteView: NSView {
    private let light = CAGradientLayer()
    /// What the orbit was last built for. Rebuilding restarts it from the top,
    /// and SwiftUI lays this view out often enough that the mote never made it
    /// past the first corner.
    private var builtFor: CGSize?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        light.type = .radial
        light.startPoint = CGPoint(x: 0.5, y: 0.5)
        light.endPoint = CGPoint(x: 1, y: 1)
        light.locations = [0, 0.38, 1]
        layer?.addSublayer(light)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        light.colors = [
            DockPalette.moteCore.cgColor,
            DockPalette.moteHalo.cgColor,
            DockPalette.moteEdge.cgColor,
        ]
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        light.bounds = CGRect(x: 0, y: 0, width: Self.moteSize, height: Self.moteSize)
        light.position = CGPoint(x: bounds.minX + Self.moteSize / 2, y: bounds.midY)
        CATransaction.commit()
        refreshOrbit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            light.removeAllAnimations()
            builtFor = nil
        } else {
            refreshOrbit()
        }
    }

    private func refreshOrbit() {
        guard window != nil, bounds.width > 1, bounds.height > 1 else { return }
        if builtFor == bounds.size, light.animation(forKey: "orbit") != nil { return }
        builtFor = bounds.size
        light.removeAllAnimations()
        let orbit = CAKeyframeAnimation(keyPath: "position")
        orbit.values = orbitStops()
        orbit.duration = 2.8
        orbit.repeatCount = .infinity
        orbit.calculationMode = .paced
        light.add(orbit, forKey: "orbit")
    }

    /// Evenly spaced stops around the pill, inset by the mote's own radius so
    /// it grazes the rim from the inside and never overhangs the card.
    private func orbitStops() -> [CGPoint] {
        let inset = Self.moteSize / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        guard rect.width > 1, rect.height > 1 else { return [CGPoint(x: bounds.midX, y: bounds.midY)] }
        let perimeter = 2 * (rect.width + rect.height)
        return (0..<Self.orbitStopCount).map { step in
            var along = perimeter * CGFloat(step) / CGFloat(Self.orbitStopCount)
            if along < rect.width { return CGPoint(x: rect.minX + along, y: rect.minY) }
            along -= rect.width
            if along < rect.height { return CGPoint(x: rect.maxX, y: rect.minY + along) }
            along -= rect.height
            if along < rect.width { return CGPoint(x: rect.maxX - along, y: rect.maxY) }
            along -= rect.width
            return CGPoint(x: rect.minX, y: rect.maxY - along)
        }
    }

    private static let orbitStopCount = 36
    private static let moteSize: CGFloat = 15
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
            color: NSColor(LoomColors.attention)
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
    /// The dock pill's cadence, so the same task blinks in step in both places.
    static let interval: CFTimeInterval = LoomBlink.half

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

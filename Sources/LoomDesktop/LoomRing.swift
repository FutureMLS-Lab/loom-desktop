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

/// The still colour of a dock pill's rim: indigo→cyan→green while the agent
/// works, green→cyan once it has finished.
///
/// Fills the pill. The pill's own face is laid over the middle of it, and what
/// is left showing is the rim — a rim drawn as a rim would have to be masked,
/// and a masked layer is redrawn offscreen on every frame it changes.
struct PillBand: NSViewRepresentable {
    let mode: PillGlow.Mode

    func makeNSView(context: Context) -> PillBandView { PillBandView(mode: mode) }

    func updateNSView(_ view: PillBandView, context: Context) { view.apply(mode: mode) }
}

final class PillBandView: NSView {
    private let band = CAGradientLayer()
    private var mode: PillGlow.Mode

    init(mode: PillGlow.Mode) {
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

    func apply(mode: PillGlow.Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        applyColors()
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch mode {
        case .working:
            band.colors = [
                PillGlow.accent.cgColor, PillGlow.cyan.cgColor, PillGlow.green.cgColor,
            ]
            band.locations = [0, 0.55, 1]
        case .finished:
            band.colors = [PillGlow.green.cgColor, PillGlow.cyan.cgColor]
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
    }
}

/// The part that moves: a mote of light running round the inside of a working
/// pill, or a slow swell of colour over a finished one.
///
/// Everything that animates in the dock lives in this one view, so there is a
/// single place to look when the dock starts costing something. What it costs
/// is not something the drawing predicts: measured against the same dock
/// holding still, this mote and a full-pill rotating gradient came to the same
/// 26 points of WindowServer, because the price was being paid by the card's
/// drop shadow rather than by anything here (see `DockView`). With that fixed
/// the same animation costs 9, about 4 of which is the card's frosted material
/// re-blurring underneath it.
struct PillGlow: NSViewRepresentable {
    enum Mode { case working, finished }

    /// How much of the band the pill's face leaves showing. Lives here because
    /// the mote has to know where the rim is.
    static let rimWidth: CGFloat = 2.4

    let mode: Mode

    func makeNSView(context: Context) -> PillGlowView { PillGlowView(mode: mode) }

    func updateNSView(_ view: PillGlowView, context: Context) { view.apply(mode: mode) }

    // Resolved once: reading these off `LoomColors` per use allocates an
    // NSColor each time, which showed up in a profile.
    static let accent = NSColor(calibratedRed: 0.35, green: 0.34, blue: 0.78, alpha: 1)
    static let green = NSColor(calibratedRed: 0.26, green: 0.68, blue: 0.48, alpha: 1)
    static let cyan = NSColor(calibratedRed: 0.26, green: 0.66, blue: 0.75, alpha: 1)
}

final class PillGlowView: NSView {
    private let light = CAGradientLayer()
    private var mode: PillGlow.Mode
    /// What the animation was last built for. Rebuilding restarts it from the
    /// top, and SwiftUI lays this view out often enough that the mote never
    /// made it past the first corner.
    private var builtFor: (mode: PillGlow.Mode, size: CGSize)?

    init(mode: PillGlow.Mode) {
        self.mode = mode
        super.init(frame: .zero)
        wantsLayer = true
        light.type = .radial
        light.startPoint = CGPoint(x: 0.5, y: 0.5)
        light.endPoint = CGPoint(x: 1, y: 1)
        layer?.addSublayer(light)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(mode: PillGlow.Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        applyColors()
        layoutLight()
        refreshAnimation()
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch mode {
        case .working:
            light.type = .radial
            light.colors = [
                NSColor.white.withAlphaComponent(0.55).cgColor,
                PillGlow.cyan.withAlphaComponent(0.28).cgColor,
                PillGlow.cyan.withAlphaComponent(0).cgColor,
            ]
            light.locations = [0, 0.38, 1]
        case .finished:
            light.type = .axial
            light.startPoint = CGPoint(x: 0, y: 0.5)
            light.endPoint = CGPoint(x: 1, y: 0.5)
            light.colors = [
                PillGlow.green.withAlphaComponent(0.20).cgColor,
                PillGlow.cyan.withAlphaComponent(0.14).cgColor,
            ]
            light.locations = [0, 1]
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        layoutLight()
        refreshAnimation()
    }

    private func layoutLight() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch mode {
        case .working:
            light.bounds = CGRect(x: 0, y: 0, width: Self.moteSize, height: Self.moteSize)
            light.position = CGPoint(x: bounds.minX + Self.moteSize / 2, y: bounds.midY)
        case .finished:
            light.frame = bounds
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            light.removeAllAnimations()
            builtFor = nil
        } else {
            refreshAnimation()
        }
    }

    private func refreshAnimation() {
        guard window != nil, bounds.width > 1, bounds.height > 1 else { return }
        let key = mode == .working ? "orbit" : "breathe"
        if let builtFor, builtFor == (mode, bounds.size), light.animation(forKey: key) != nil {
            return
        }
        builtFor = (mode, bounds.size)
        light.removeAllAnimations()
        switch mode {
        case .working:
            let orbit = CAKeyframeAnimation(keyPath: "position")
            orbit.values = orbitStops()
            orbit.duration = 2.8
            orbit.repeatCount = .infinity
            orbit.calculationMode = .paced
            light.add(orbit, forKey: key)
        case .finished:
            // Breathing, not flashing, and on opacity — the compositor
            // re-blends a layer it already holds rather than asking for new
            // pixels.
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 0.9
            breathe.toValue = 0.25
            breathe.duration = LoomBlink.half
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            let now = light.convertTime(CACurrentMediaTime(), from: nil)
            breathe.beginTime = now - now.truncatingRemainder(dividingBy: LoomBlink.cycle)
            light.add(breathe, forKey: key)
        }
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

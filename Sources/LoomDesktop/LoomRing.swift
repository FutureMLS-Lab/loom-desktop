import SwiftUI

/// The web console's agent-activity rings, ported from `app.css` and drawn by
/// Core Animation.

/// The cadence for a blinking "finished, unseen" dot, so the sidebar and
/// quick-open say the same thing in step rather than as two separate alarms.
///
/// Slower than the web console's 1.1s: one thing flashing hard reads as "look
/// here", and a dozen of them at that speed reads as a fault.
///
/// The dock's pills no longer blink at all — see `PillRing`.
enum LoomBlink {
    static let cycle: CFTimeInterval = 1.6
    static var half: CFTimeInterval { cycle / 2 }
}

/// A pill's activity ring, drawn by Core Animation.
///
/// Working is the web console's conic gradient rotating once every 1.8s.
/// Finished is the same indigo→green ring, held still: these are drawn on a
/// panel that floats above every window on every space, where each animated
/// frame costs the compositor a rebuild of the desktop underneath it, and a
/// dock of a dozen finished pills was enough to slow the whole machine.
/// Motion is spent on the one state that is actually changing.
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
    /// Positions per revolution of the working ring.
    static let spinSteps = 12

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
            // Stepped, not swept. A smooth rotation asks the compositor for a
            // new frame at the display's rate, and this ring sits on a
            // transparent panel above every window on every space, so each of
            // those frames is a re-blend of the desktop underneath it —
            // enough, with three tasks working, to take WindowServer to 77%
            // and make the whole machine feel slow.
            //
            // Twelve positions a revolution costs a twelfth of the frames and
            // reads as a spinner regardless: the classic ones tick.
            //
            // Worth a quarter, not a miracle: measured against the same three
            // working tasks, showing the dock costs 29 points of WindowServer
            // where it used to cost 36-39. The rest is the mask — a ring
            // masking a gradient composites offscreen on every frame it
            // changes — and getting that back would mean a spinner drawn some
            // other way.
            let steps = Self.spinSteps
            let spin = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            spin.values = (0...steps).map { Double($0) / Double(steps) * 2 * .pi }
            spin.calculationMode = .discrete
            spin.duration = 1.8
            spin.repeatCount = .infinity
            gradient.add(spin, forKey: "spin")
        case .finished:
            // Deliberately still. This ring used to blink, and the dock
            // routinely carries a dozen of them at once: the panel floats
            // above every window on every space, so each frame of each
            // animation makes the compositor rebuild the whole desktop
            // beneath it. Measured, a dock of thirteen finished pills held
            // WindowServer at 82% against 46% with the panel hidden — the
            // machine, not the app, was what went slow.
            //
            // The colour says "finished" on its own, and the count in the
            // header says how many. Motion is kept for work in progress,
            // which is the state that is actually changing.
            break
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

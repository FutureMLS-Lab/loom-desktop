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
/// Motion is rationed on purpose. SwiftUI drives a `repeatForever` animation
/// by re-evaluating the view graph every frame rather than handing it to the
/// compositor, so a sidebar of thirteen animated dots kept the whole app
/// re-rendering at display rate and made everything feel sluggish. Lists get
/// `LoomActivityDot` (static); only the dock and the task header move.
struct LoomSpinnerDot: View {
    var size: CGFloat = 14

    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(LoomColors.accent)
            .frame(width: size * 0.62, height: size * 0.62)
            .scaleEffect(pulsing ? 1.0 : 0.6)
            .opacity(pulsing ? 1 : 0.45)
            .frame(width: size, height: size)
            .onAppear {
                guard !pulsing else { return }
                withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
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

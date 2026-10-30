import SwiftUI

// MARK: - BrandMark — the XYLO logo mark (nikhil/custom)
//
// The app's identity glyph, rendered natively for use as a hero on onboarding,
// "about", and empty states. It mirrors the XYLO app icon:
//
//   • a circular dark tile with a faint top sheen and a hairline rim,
//   • a faint full-circle track, and over it
//   • an open "halo" ring, a ~300° arc from 2 o'clock clockwise round to 10
//     o'clock, shading from Halo Cyan into Halo Blue, round-capped, and
//   • a small white dot riding the blue end of the ring.
//
// Everything is driven off a single `size`, so the mark stays crisp from a 28pt
// list avatar up to a 120pt onboarding hero.

public struct BrandMark: View {

    /// Edge length of the square mark; everything scales from this.
    public var size: CGFloat

    public init(size: CGFloat = 120) {
        self.size = size
    }

    // The ring starts at the cyan end (about 2 o'clock) and sweeps clockwise to the
    // blue end (about 10 o'clock), leaving the gap at the top like the icon.
    private let startDegrees: Double = -60
    private let spanDegrees: Double = 300

    // Proportions derived from `size` so the mark is resolution-independent.
    private var ringWidth: CGFloat { size * 0.085 }
    private var ringDiameter: CGFloat { size * 0.56 }
    private var dotDiameter: CGFloat { size * 0.06 }
    private var rimWidth: CGFloat { max(1, size * 0.008) }  // ~1px hairline rim

    public var body: some View {
        ZStack {
            navyTile
            track
            haloRing
            endDot
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("XYLO"))
        .accessibilityAddTraits(.isImage)
    }

    // MARK: Deep-navy tile

    /// The navy disc the gold mark sits on — a deep-navy vertical ramp (lifted at
    /// the top, deeper at the bottom) with a faint cool top sheen and a soft
    /// hairline rim, matching the app icon. No shadow — flat and clean.
    private var navyTile: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color(hex: "#1A1E24"), Color(hex: "#0E1116")],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            // Faint cool top sheen — a soft light catch across the upper third (flat, no bloom).
            .overlay(
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "#2A2F37").opacity(0.5), .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .opacity(0.6)
            )
            // 1px hairline rim so the disc reads cleanly on the navy canvas.
            .overlay(
                Circle().strokeBorder(StrandPalette.hairline, lineWidth: rimWidth)
            )
    }

    // MARK: Halo ring

    /// The faint full circle the halo sits on.
    private var track: some View {
        Circle()
            .inset(by: ringWidth / 2)
            .stroke(Color.white.opacity(0.07), lineWidth: ringWidth)
            .frame(width: ringDiameter, height: ringDiameter)
    }

    /// The open arc, Halo Cyan at the start shading to Halo Blue at the end.
    private var haloRing: some View {
        RecoveryArc(
            startAngle: .degrees(startDegrees),
            spanDegrees: spanDegrees,
            fraction: 1,
            lineWidth: ringWidth
        )
        .stroke(
            AngularGradient(
                colors: [AccentColor.haloCyan, AccentColor.haloBlue],
                center: .center,
                startAngle: .degrees(startDegrees),
                endAngle: .degrees(startDegrees + spanDegrees)
            ),
            style: StrokeStyle(lineWidth: ringWidth, lineCap: .round)
        )
        .frame(width: ringDiameter, height: ringDiameter)
    }

    /// The white dot on the blue end of the ring.
    private var endDot: some View {
        let angle = (startDegrees + spanDegrees) * .pi / 180
        let r = (ringDiameter - ringWidth) / 2
        return Circle()
            .fill(Color.white)
            .frame(width: dotDiameter, height: dotDiameter)
            .offset(x: r * cos(angle), y: r * sin(angle))
    }
}

#if DEBUG
#Preview("BrandMark — sizes") {
    VStack(spacing: 40) {
        BrandMark(size: 120)
        HStack(spacing: 28) {
            BrandMark(size: 72)
            BrandMark(size: 44)
            BrandMark(size: 28)
        }
    }
    .padding(48)
    .frame(width: 420, height: 460)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif

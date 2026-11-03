import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// nikhil/custom — the muscle map: a front and a back body figure, each muscle coloured from the Lift Log
// sets. Two readings of the same sets:
//
//   Recovery         the last 3 days. Worked today or yesterday is red (still recovering), two or three
//                    days ago yellow, otherwise green (ready).
//   Sets this week   the last 7 days of fractional sets (direct 1, indirect 0.5, as the Lift Log counts).
//                    Under 4 red, 4 to under 10 yellow, 10 or more green.
//
// A muscle counts as worked on a day once it got a full set's credit that day (one direct set, or two
// where it was a secondary mover), so a single assisting set does not mark it as needing rest.
// Shown on the Workouts page and on the Effort page under the day's workouts.

enum MuscleMapModel {

    enum Tone: Hashable { case red, yellow, green }

    /// Fractional sets a muscle needs on one day to count as worked that day.
    static let workedCreditPerDay = 1.0
    /// Days since last worked: 0-1 red, 2-3 yellow, older green.
    static let recoveringDays = 1
    static let recoveryWindowDays = 3
    /// Weekly fractional sets: the research floor for growth, and a solid week.
    static let weeklyFloor = LiftMetrics.ReferenceDose.hypertrophyMinimumSetsPerWeek
    static let weeklyGood = 10.0

    /// For each muscle, how many calendar days ago it was last worked (0 = today).
    static func lastWorked(days: [(daysAgo: Int, sets: [LiftSetRow])]) -> [LiftMuscle: Int] {
        var credit: [Int: [LiftMuscle: Double]] = [:]
        for d in days {
            for (m, c) in LiftMetrics.muscleCounts(d.sets).fractional {
                credit[d.daysAgo, default: [:]][m, default: 0] += c
            }
        }
        var last: [LiftMuscle: Int] = [:]
        for (day, perMuscle) in credit {
            for (m, c) in perMuscle where c >= workedCreditPerDay {
                last[m] = min(last[m] ?? day, day)
            }
        }
        return last
    }

    static func recoveryTone(daysAgo: Int?) -> Tone {
        guard let daysAgo else { return .green }
        if daysAgo <= recoveringDays { return .red }
        if daysAgo <= recoveryWindowDays { return .yellow }
        return .green
    }

    static func weeklyTone(sets: Double) -> Tone {
        if sets >= weeklyGood { return .green }
        if sets >= weeklyFloor { return .yellow }
        return .red
    }

    struct Week: Equatable {
        var lastWorked: [LiftMuscle: Int] = [:]
        var weeklySets: [LiftMuscle: Double] = [:]
        var hasSets = false
    }

    /// Sessions of the last 7 calendar days (today included), with their sets.
    @MainActor
    static func load(repo: Repository, now: Date = Date(), calendar: Calendar = .current) async -> Week {
        guard let store = await repo.storeHandle() else { return Week() }
        let today = calendar.startOfDay(for: now)
        guard let from = calendar.date(byAdding: .day, value: -6, to: today) else { return Week() }
        let sessions = ((try? await store.liftSessions(deviceId: repo.deviceId,
                                                       fromTs: Int(from.timeIntervalSince1970),
                                                       toTs: Int(now.timeIntervalSince1970))) ?? [])
            .filter { $0.endTs != nil }
        var days: [(daysAgo: Int, sets: [LiftSetRow])] = []
        var all: [LiftSetRow] = []
        for s in sessions {
            let sets = (try? await store.liftSets(sessionId: s.id)) ?? []
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(s.startTs)))
            let ago = calendar.dateComponents([.day], from: day, to: today).day ?? 0
            days.append((ago, sets))
            all += sets
        }
        return Week(lastWorked: lastWorked(days: days),
                    weeklySets: LiftMetrics.muscleCounts(all).fractional,
                    hasSets: !all.isEmpty)
    }
}

// MARK: - Card

struct MuscleMapCard: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @State private var tab: Tab = .recovery
    @State private var week = MuscleMapModel.Week()
    @State private var loaded = false

    enum Tab: Hashable { case recovery, sets }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Muscle map",
                          overline: tab == .recovery ? LocalizedStringKey("Last 3 days") : LocalizedStringKey("Last 7 days"))
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    SegmentedPillControl([Tab.recovery, .sets], selection: $tab, fillsAvailableWidth: true) {
                        $0 == .recovery ? String(localized: "Recovery") : String(localized: "Sets this week")
                    }
                    if loaded && !week.hasSets {
                        Text("Log a strength session's sets (Lift Log, or Log what you did on a workout) and each muscle is coloured here.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .top, spacing: NoopMetrics.space3) {
                        figure(.front, label: "Front")
                        figure(.back, label: "Back")
                    }
                    legend
                    summary
                }
            }
        }
        .task(id: repo.refreshSeq) {
            week = await MuscleMapModel.load(repo: repo)
            loaded = true
        }
    }

    private func tone(_ m: LiftMuscle) -> MuscleMapModel.Tone {
        switch tab {
        case .recovery: return MuscleMapModel.recoveryTone(daysAgo: week.lastWorked[m])
        case .sets: return MuscleMapModel.weeklyTone(sets: week.weeklySets[m] ?? 0)
        }
    }

    private static func color(_ t: MuscleMapModel.Tone) -> Color {
        switch t {
        case .red: return StrandPalette.statusCritical
        case .yellow: return StrandPalette.statusWarning
        case .green: return StrandPalette.statusPositive
        }
    }

    private func figure(_ side: BodyFigure.Side, label: LocalizedStringKey) -> some View {
        VStack(spacing: 4) {
            BodyFigure(side: side, female: profile.sex.lowercased() == "female") { m in loaded && week.hasSets ? Self.color(tone(m)) : nil }
                .aspectRatio(BodyFigure.aspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
            Text(label).strandOverline()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    private var legend: some View {
        let labels: [(MuscleMapModel.Tone, LocalizedStringKey)] = tab == .recovery
            ? [(.red, "Recovering"), (.yellow, "2-3 days ago"), (.green, "Ready")]
            : [(.red, "Under 4 sets"), (.yellow, "4-9"), (.green, "10+")]
        return HStack(spacing: NoopMetrics.space3) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 5) {
                    Circle().fill(Self.color(item.0)).frame(width: 9, height: 9)
                    Text(item.1).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The muscles in each colour, in words, so the figure never has to be decoded alone.
    @ViewBuilder
    private var summary: some View {
        if loaded && week.hasSets {
            VStack(alignment: .leading, spacing: 6) {
                ForEach([MuscleMapModel.Tone.red, .yellow, .green], id: \.self) { t in
                    let names = muscles(t)
                    if !names.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle().fill(Self.color(t)).frame(width: 7, height: 7)
                            Text(names)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func muscles(_ t: MuscleMapModel.Tone) -> String {
        LiftMuscle.ordered.filter { tone($0) == t }.map { m in
            switch tab {
            case .recovery:
                return m.displayName
            case .sets:
                let n = week.weeklySets[m] ?? 0
                return n > 0 ? "\(m.displayName) \(LiftFormat.trim(n))" : m.displayName
            }
        }.joined(separator: ", ")
    }

    private var accessibilitySummary: String {
        let heads: [(MuscleMapModel.Tone, String)] = tab == .recovery
            ? [(.red, String(localized: "Recovering")), (.yellow, String(localized: "Worked 2 to 3 days ago")),
               (.green, String(localized: "Ready"))]
            : [(.red, String(localized: "Under 4 sets")), (.yellow, String(localized: "4 to 9 sets")),
               (.green, String(localized: "10 or more sets"))]
        return heads.compactMap { t, head in
            let names = muscles(t)
            return names.isEmpty ? nil : "\(head): \(names)"
        }.joined(separator: ". ")
    }
}

// MARK: - Figure

/// A stylised human figure, front or back, in a 100 × 200 box. Each muscle is a few simple shapes on the
/// figure's left side, mirrored to the right; the body underneath is a neutral silhouette. The female
/// figure has narrower shoulders, a waist, wider hips, slimmer limbs and hair; the muscles follow it.
struct BodyFigure: View {
    enum Side { case front, back }

    let side: Side
    var female = false
    /// The fill for a muscle, or nil to leave it neutral.
    let fill: (LiftMuscle) -> Color?

    static let aspect: CGFloat = 100.0 / 200.0

    var body: some View {
        Canvas { ctx, size in
            let t = CGAffineTransform(scaleX: size.width / 100, y: size.height / 200)
            let base = StrandPalette.textPrimary.opacity(0.07)
            let idle = StrandPalette.textPrimary.opacity(0.13)
            let edge = StrandPalette.surfaceBase.opacity(0.9)
            for p in female ? Self.femaleSilhouette : Self.maleSilhouette {
                ctx.fill(p.applying(t), with: .color(base))
            }
            if female {
                let hair = side == .front ? Self.hairFront : Self.hairBack
                ctx.fill(hair.applying(t), with: .color(StrandPalette.textPrimary.opacity(0.22)))
            }
            for (muscle, paths) in Self.muscles(side, female: female) {
                let color = fill(muscle) ?? idle
                for p in paths {
                    let path = p.applying(t)
                    ctx.fill(path, with: .color(color))
                    ctx.stroke(path, with: .color(edge), lineWidth: 1)
                }
            }
        }
    }

    // MARK: Geometry (100 × 200)

    private static func mirrored(_ p: Path) -> Path {
        p.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 100, ty: 0))
    }

    private static func pair(_ p: Path) -> [Path] { [p, mirrored(p)] }

    private static func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat,
                                rotate deg: CGFloat = 0) -> Path {
        let e = Path(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
        return e.applying(CGAffineTransform(rotationAngle: deg * .pi / 180)
            .concatenating(CGAffineTransform(translationX: cx, y: cy)))
    }

    private static func poly(_ pts: [(CGFloat, CGFloat)]) -> Path {
        var p = Path()
        p.addLines(pts.map { CGPoint(x: $0.0, y: $0.1) })
        p.closeSubpath()
        return p
    }

    private static func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
    }

    private static func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    static func muscles(_ side: Side, female: Bool) -> [(LiftMuscle, [Path])] {
        switch (side, female) {
        case (.front, false): return maleFront
        case (.back, false): return maleBack
        case (.front, true): return femaleFront
        case (.back, true): return femaleBack
        }
    }

    // MARK: Male

    /// Head, torso, arms and legs: the neutral body the muscles sit on.
    static let maleSilhouette: [Path] = {
        var parts: [Path] = [ellipse(50, 13, 8.5, 10.5), rounded(45, 21, 10, 12, 3)]
        var torso = Path()
        torso.move(to: pt(31, 32))
        torso.addQuadCurve(to: pt(69, 32), control: pt(50, 27))
        torso.addLine(to: pt(66, 88))
        torso.addQuadCurve(to: pt(68, 104), control: pt(69, 96))
        torso.addLine(to: pt(32, 104))
        torso.addQuadCurve(to: pt(34, 88), control: pt(31, 96))
        torso.closeSubpath()
        parts.append(torso)
        parts += pair(ellipse(26.5, 60, 5.5, 25, rotate: 8))     // upper and lower arm
        parts += pair(ellipse(21, 98, 3.5, 6, rotate: 10))       // hand
        parts += pair(ellipse(41, 128, 8.5, 28, rotate: 2))      // thigh
        parts += pair(ellipse(39.5, 166, 5.5, 22, rotate: 1))    // lower leg
        parts += pair(ellipse(39, 192, 4.5, 3.5))                 // foot
        return parts
    }()

    private static let maleFront: [(LiftMuscle, [Path])] = [
        (.neck, [rounded(45.5, 22, 9, 9, 3)]),
        (.traps, pair(poly([(45, 27), (45, 32), (36, 33)]))),
        (.sideDelts, pair(ellipse(28.5, 40, 4.5, 7.5, rotate: 10))),
        (.frontDelts, pair(ellipse(33.5, 38.5, 5, 6.5, rotate: -15))),
        (.chest, pair(poly([(37, 37), (49.5, 36), (49.5, 52), (44, 54.5), (37, 51)]))),
        (.biceps, pair(ellipse(27, 55, 4.2, 9, rotate: 8))),
        (.forearms, pair(ellipse(23.5, 78, 3.6, 11, rotate: 10))),
        (.abs, [rounded(44.5, 56, 11, 31, 4)]),
        (.obliques, pair(poly([(36, 56), (43, 57), (43, 86), (37.5, 82)]))),
        (.abductors, pair(ellipse(35, 97, 3.5, 7))),
        (.adductors, pair(poly([(44.5, 104), (49, 106), (48, 132), (44.5, 124)]))),
        (.quads, pair(ellipse(39, 124, 6.5, 20, rotate: 3))),
        (.calves, pair(ellipse(37.5, 163, 3.5, 13, rotate: 2))),
    ]

    private static let maleBack: [(LiftMuscle, [Path])] = [
        (.neck, [rounded(45.5, 22, 9, 8, 3)]),
        (.upperBack, pair(poly([(41, 40), (49, 41), (49, 63), (42, 60)]))),
        (.traps, [poly([(50, 26), (63, 34), (55, 44), (50, 60), (45, 44), (37, 34)])]),
        (.sideDelts, pair(ellipse(28.5, 40, 4.5, 7.5, rotate: 10))),
        (.rearDelts, pair(ellipse(33.5, 39, 5, 6, rotate: 15))),
        (.lats, pair(poly([(36.5, 47), (41.5, 60), (48, 66), (45, 84), (36, 72)]))),
        (.triceps, pair(ellipse(27, 55, 4.2, 9, rotate: 8))),
        (.forearms, pair(ellipse(23.5, 78, 3.6, 11, rotate: 10))),
        (.lowerBack, [rounded(44.5, 70, 11, 22, 4)]),
        (.abductors, pair(ellipse(34.5, 97, 3.5, 6.5))),
        (.glutes, pair(ellipse(42.5, 104, 7.5, 8.5))),
        (.adductors, pair(poly([(45.5, 115), (49, 116), (48.5, 130), (45.5, 126)]))),
        (.hamstrings, pair(ellipse(39.5, 132, 6, 17, rotate: 3))),
        (.calves, pair(ellipse(38.5, 163, 5, 14, rotate: 2))),
    ]

    // MARK: Female

    static let femaleSilhouette: [Path] = {
        var parts: [Path] = [ellipse(50, 14, 7, 9.5), rounded(46.5, 21, 7, 12, 3)]
        var torso = Path()
        torso.move(to: pt(34, 33))
        torso.addQuadCurve(to: pt(66, 33), control: pt(50, 28.5))
        torso.addCurve(to: pt(61, 70), control1: pt(67, 46), control2: pt(61, 58))     // in to the waist
        torso.addCurve(to: pt(69, 100), control1: pt(61, 80), control2: pt(69.5, 90))  // out over the hip
        torso.addQuadCurve(to: pt(64, 108), control: pt(68.5, 106))
        torso.addLine(to: pt(36, 108))
        torso.addQuadCurve(to: pt(31, 100), control: pt(31.5, 106))
        torso.addCurve(to: pt(39, 70), control1: pt(30.5, 90), control2: pt(39, 80))
        torso.addCurve(to: pt(34, 33), control1: pt(39, 58), control2: pt(33, 46))
        torso.closeSubpath()
        parts.append(torso)
        parts += pair(ellipse(30.5, 60, 4.4, 24, rotate: 6))     // upper and lower arm
        parts += pair(ellipse(26.5, 96, 2.9, 5.2, rotate: 8))    // hand
        parts += pair(ellipse(41.5, 130, 9, 27, rotate: 4))      // thigh
        parts += pair(ellipse(41.5, 167, 4.6, 21, rotate: 2))    // lower leg
        parts += pair(ellipse(42, 192, 3.8, 3))                   // foot
        return parts
    }()

    /// Hair framing the face and flaring at the shoulders, with a bun on top.
    private static let hairFront: Path = {
        var p = Path()
        p.move(to: pt(37, 34))
        p.addCurve(to: pt(39.5, 14), control1: pt(39.5, 28), control2: pt(38.5, 20))
        p.addCurve(to: pt(50, 3), control1: pt(39.5, 7), control2: pt(44, 3))
        p.addCurve(to: pt(60.5, 14), control1: pt(56, 3), control2: pt(60.5, 7))
        p.addCurve(to: pt(63, 34), control1: pt(61.5, 20), control2: pt(60.5, 28))
        p.addQuadCurve(to: pt(57, 32.5), control: pt(60, 35))
        p.addLine(to: pt(56.5, 15))
        p.addCurve(to: pt(50, 7.5), control1: pt(56.5, 10.5), control2: pt(54, 7.5))
        p.addCurve(to: pt(43.5, 15), control1: pt(46, 7.5), control2: pt(43.5, 10.5))
        p.addLine(to: pt(43, 32.5))
        p.addQuadCurve(to: pt(37, 34), control: pt(40, 35))
        p.closeSubpath()
        p.addPath(ellipse(50, 2.5, 5, 4))
        return p
    }()

    /// The back of the head and the bun, ending above the neck so the neck stays visible.
    private static let hairBack: Path = {
        var p = Path()
        p.move(to: pt(39.5, 23))
        p.addLine(to: pt(39.5, 14))
        p.addCurve(to: pt(50, 3), control1: pt(39.5, 7), control2: pt(44, 3))
        p.addCurve(to: pt(60.5, 14), control1: pt(56, 3), control2: pt(60.5, 7))
        p.addLine(to: pt(60.5, 23))
        p.addQuadCurve(to: pt(39.5, 23), control: pt(50, 27))
        p.closeSubpath()
        p.addPath(ellipse(50, 2.5, 5, 4))
        return p
    }()

    private static let femaleFront: [(LiftMuscle, [Path])] = [
        (.neck, [rounded(46.5, 23, 7, 8, 3)]),
        (.traps, pair(poly([(46, 28), (46, 32.5), (39, 33.5)]))),
        (.sideDelts, pair(ellipse(32, 40, 3.8, 6.5, rotate: 10))),
        (.frontDelts, pair(ellipse(36.5, 39, 4.2, 5.5, rotate: -15))),
        (.chest, pair(poly([(39.5, 37.5), (49.5, 37), (49.5, 49), (44, 51), (39.5, 48)]))),
        (.biceps, pair(ellipse(30.5, 55, 3.5, 8.5, rotate: 6))),
        (.forearms, pair(ellipse(28, 78, 3, 10.5, rotate: 8))),
        (.abs, [rounded(45.5, 54, 9, 28, 4)]),
        (.obliques, pair(poly([(40, 55), (44, 56), (44, 82), (40.5, 76)]))),
        (.abductors, pair(ellipse(34.5, 98, 3.2, 6.5))),
        (.adductors, pair(poly([(45, 110), (49, 112), (48.5, 136), (45, 129)]))),
        (.quads, pair(ellipse(40.5, 128, 7, 20, rotate: 4))),
        (.calves, pair(ellipse(40.5, 164, 3.2, 12.5, rotate: 2))),
    ]

    private static let femaleBack: [(LiftMuscle, [Path])] = [
        (.neck, [rounded(46.5, 23, 7, 7, 3)]),
        (.upperBack, pair(poly([(42.5, 40), (49, 41), (49, 60), (43.5, 58)]))),
        (.traps, [poly([(50, 27), (61, 34), (54.5, 43), (50, 57), (45.5, 43), (39, 34)])]),
        (.sideDelts, pair(ellipse(32, 40, 3.8, 6.5, rotate: 10))),
        (.rearDelts, pair(ellipse(36.5, 39.5, 4.2, 5.2, rotate: 15))),
        (.lats, pair(poly([(39, 46), (43, 58), (48, 63), (45.5, 78), (39.5, 68)]))),
        (.triceps, pair(ellipse(30.5, 55, 3.5, 8.5, rotate: 6))),
        (.forearms, pair(ellipse(28, 78, 3, 10.5, rotate: 8))),
        (.lowerBack, [rounded(45.5, 66, 9, 22, 4)]),
        (.abductors, pair(ellipse(33.5, 96, 3.2, 6))),
        (.glutes, pair(ellipse(42, 105, 8.5, 9.5))),
        (.adductors, pair(poly([(45.5, 118), (49, 119), (48.5, 134), (45.5, 130)]))),
        (.hamstrings, pair(ellipse(40.5, 134, 6.5, 17, rotate: 4))),
        (.calves, pair(ellipse(40.5, 164, 4.5, 13.5, rotate: 2))),
    ]
}

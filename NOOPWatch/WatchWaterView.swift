import SwiftUI
import StrandDesign
import WatchConnectivity
import WatchKit
import WidgetKit

// nikhil/custom — water on the wrist. The phone owns the hydration log; the watch shows the latest state it
// pushed (`WatchHydrationSnapshot`), and + here (or a tap on the water complication, which opens this page
// and logs) sends one glass to the phone; − takes one off. The tap counts on the watch straight away, so the page and the
// face move at once; the phone's reply then replaces it with the real total.

final class WatchWaterStore: ObservableObject {
    static let shared = WatchWaterStore()

    @Published private(set) var snapshot: WatchHydrationSnapshot?

    static let complicationKind = "NOOPWaterComplication"

    private init() { snapshot = WatchHydrationSnapshot.load() }

    var glassML: Int { snapshot?.glassML ?? 250 }
    /// Whether − has anything to take off (it never touches the standard amount).
    var canRemove: Bool { (snapshot?.current().trackedML ?? 0) > 0 }

    /// A state from the phone (context, message, complication transfer or a reply).
    func receive(_ payload: [String: Any]) {
        guard let snap = WatchHydrationSnapshot.decode(payload[WatchHydrationSnapshot.contextKey] as? Data) else { return }
        DispatchQueue.main.async { self.apply(snap) }
    }

    private func apply(_ snap: WatchHydrationSnapshot) {
        snap.save()
        snapshot = snap
        WidgetCenter.shared.reloadTimelines(ofKind: Self.complicationKind)
    }

    /// + : log one glass. It counts here at once, then goes to the phone (a message when it answers,
    /// otherwise queued to arrive when it next can).
    func logGlass() {
        let ml = glassML
        if let snap = snapshot { apply(snap.adding(ml)) }
        WKInterfaceDevice.current().play(.success)
        send([WatchHydrationSnapshot.logMessageKey: ml, WatchHydrationSnapshot.entryIdKey: UUID().uuidString])
    }

    /// − : take one glass off today's tracked drinks (not below the standard amount).
    func removeGlass() {
        guard let snap = snapshot?.current(), snap.trackedML > 0 else { return }
        let ml = min(glassML, snap.trackedML)
        apply(snap.adding(-ml))
        WKInterfaceDevice.current().play(.click)
        send([WatchHydrationSnapshot.removeMessageKey: ml])
    }

    private func send(_ payload: [String: Any]) {
        let session = WCSession.default
        guard session.activationState == .activated else {
            // Not up yet (a cold launch from the complication): try again once it activates.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.sendWhenActive(payload, tries: 5) }
            return
        }
        guard session.isReachable else { session.transferUserInfo(payload); return }
        session.sendMessage(payload, replyHandler: { [weak self] reply in self?.receive(reply) },
                            errorHandler: { _ in session.transferUserInfo(payload) })
    }

    private func sendWhenActive(_ payload: [String: Any], tries: Int) {
        if WCSession.default.activationState == .activated || tries <= 0 {
            if WCSession.default.activationState == .activated { send(payload) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.sendWhenActive(payload, tries: tries - 1) }
    }
}

struct WatchWaterView: View {
    @ObservedObject private var water = WatchWaterStore.shared

    var body: some View {
        let snap = water.snapshot?.current()
        VStack(spacing: 8) {
            if let snap {
                ZStack {
                    Circle().stroke(StrandPalette.accent.opacity(0.2), lineWidth: 8)
                    Circle().trim(from: 0, to: snap.fraction)
                        .stroke(StrandPalette.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.5), value: snap.fraction)
                    VStack(spacing: 0) {
                        Text(Self.litres(snap.totalML))
                            .font(StrandFont.rounded(26, weight: .bold)).monospacedDigit()
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("of \(Self.litres(snap.goalML)) L")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .frame(width: 92, height: 92)
                status(snap)
            } else {
                Image(systemName: "drop.fill").font(.system(size: 30)).foregroundStyle(StrandPalette.accent)
                Text("Open NOOP on your iPhone and turn on hydration tracking.")
                    .font(StrandFont.caption).multilineTextAlignment(.center)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            HStack(spacing: 24) {
                roundButton("minus", label: "Remove a glass", tint: StrandPalette.textSecondary) { water.removeGlass() }
                    .disabled(!water.canRemove).opacity(water.canRemove ? 1 : 0.4)
                roundButton("plus", label: "Log a glass, \(water.glassML) millilitres", tint: StrandPalette.accent) { water.logGlass() }
            }
            .disabled(water.snapshot == nil)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
    }

    private func roundButton(_ symbol: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .bold)).frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .background(Circle().fill(tint.opacity(0.22)))
        .accessibilityLabel(label)
    }

    @ViewBuilder private func status(_ snap: WatchHydrationSnapshot) -> some View {
        let behind = snap.behindML()
        if snap.remainingML == 0 {
            Text("Goal reached").font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.statusPositive)
        } else {
            Text(behind > 0 ? "\(Self.litres(snap.remainingML)) L left · \(behind) ml behind"
                            : "\(Self.litres(snap.remainingML)) L left · on pace")
                .font(StrandFont.caption).monospacedDigit()
                .foregroundStyle(behind > 0 ? StrandPalette.statusWarning : StrandPalette.textSecondary)
        }
    }

    static func litres(_ ml: Int) -> String { String(format: "%.1f", Double(ml) / 1000) }
}

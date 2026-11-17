import SwiftUI
import StrandDesign

// nikhil/custom — the legend under a stacked bar chart, as chips that switch a series off and on: tap the
// ones you don't want to see one series on its own, tap them back for the full stack. The last series
// showing can't be switched off. The chart keeps the full colour domain, so a series keeps its colour.

struct SeriesToggleLegend: View {
    struct Item: Identifiable {
        var key: String
        var label: String
        var color: Color
        var id: String { key }
    }

    let items: [Item]
    @Binding var hidden: Set<String>

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items) { item in
                let on = !hidden.contains(item.key)
                Button {
                    if on {
                        if items.filter({ !hidden.contains($0.key) }).count > 1 { hidden.insert(item.key) }
                    } else {
                        hidden.remove(item.key)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(on ? item.color : Color.clear)
                            .overlay(Circle().stroke(item.color, lineWidth: 1.5))
                            .frame(width: 8, height: 8)
                        Text(item.label)
                            .font(StrandFont.caption)
                            .foregroundStyle(on ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                            .strikethrough(!on)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(on ? item.color.opacity(0.15) : Color.clear))
                    .overlay(Capsule().stroke(StrandPalette.hairlineStrong, lineWidth: on ? 0 : 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(item.label))
                .accessibilityValue(Text(on ? "Shown" : "Hidden"))
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

// Плашка съёмки: экран блокировки, Dynamic Island и Apple Watch (Smart Stack)
import WidgetKit
import SwiftUI
import ActivityKit

@main
struct NightLapseWidgets: WidgetBundle {
    var body: some Widget {
        LapseLiveActivity()
    }
}

struct LapseLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LapseActivityAttributes.self) { ctx in
            LapseLockView(mode: ctx.attributes.mode, s: ctx.state, stale: ctx.isStale)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("\(ctx.state.frames)", systemImage: "camera.aperture")
                        .font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.trailing) {
                    timeText(ctx.state).font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    statusLine(ctx.state, stale: ctx.isStale).font(.caption)
                }
            } compactLeading: {
                Image(systemName: icon(ctx.state)).foregroundStyle(color(ctx.state))
            } compactTrailing: {
                Text("\(ctx.state.frames)").monospacedDigit()
            } minimal: {
                Image(systemName: icon(ctx.state)).foregroundStyle(color(ctx.state))
            }
        }
        .supplementalActivityFamilies([.small])
    }
}

/// Экран блокировки (большая) и часы (маленькая, .small)
struct LapseLockView: View {
    let mode: String
    let s: LapseActivityAttributes.ContentState
    let stale: Bool
    @Environment(\.activityFamily) private var family

    var body: some View {
        if family == .small {
            // Apple Watch: только главное
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Image(systemName: icon(s)).foregroundStyle(color(s))
                    Text("\(s.frames) кадр.").font(.headline.monospacedDigit())
                }
                timeText(s).font(.caption.monospacedDigit())
                statusLine(s, stale: stale).font(.caption2).lineLimit(1)
            }
            .padding(6)
        } else {
            HStack(spacing: 14) {
                Image(systemName: icon(s))
                    .font(.title2)
                    .foregroundStyle(color(s))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(mode): \(s.frames) кадров").font(.headline.monospacedDigit())
                    statusLine(s, stale: stale).font(.caption)
                }
                Spacer()
                timeText(s).font(.title3.monospacedDigit())
            }
            .foregroundStyle(Color.white)
            .padding()
        }
    }
}

private func icon(_ s: LapseActivityAttributes.ContentState) -> String {
    switch s.state {
    case "paused": return "pause.circle.fill"
    case "done": return "checkmark.circle.fill"
    default: return "record.circle"
    }
}

private func color(_ s: LapseActivityAttributes.ContentState) -> Color {
    if s.hot || s.state == "paused" { return .red }
    if s.state == "done" { return .green }
    return .red
}

@ViewBuilder
private func timeText(_ s: LapseActivityAttributes.ContentState) -> some View {
    if s.state == "rec" {
        Text(s.started, style: .timer)
    } else {
        Text(s.started, style: .relative)
    }
}

@ViewBuilder
private func statusLine(_ s: LapseActivityAttributes.ContentState, stale: Bool) -> some View {
    let bat = s.battery >= 0 ? "\(s.battery)%" : "-"
    if stale && s.state == "rec" {
        Text("Нет связи с телефоном или кадров давно не было").foregroundStyle(.orange)
    } else if !s.note.isEmpty {
        Text(s.note).foregroundStyle(s.state == "paused" ? Color.red : Color.secondary)
    } else {
        Text("Батарея \(bat)\(s.hot ? ", горячий" : "")").foregroundStyle(s.hot ? Color.red : Color.secondary)
    }
}

import SwiftUI
import WidgetKit

@main
struct LoomWatchWidgets: WidgetBundle {
    var body: some Widget {
        FleetWidget()
    }
}

/// The fleet on the watch face: agents working, finishes waiting for you,
/// and the task most worth a look.
struct FleetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GlanceStore.widgetKind, provider: FleetProvider()) { entry in
            FleetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Loom")
        .description("Agents working, and finished ones waiting for you.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

struct FleetEntry: TimelineEntry {
    let date: Date
    /// Nil until the iPhone has handed the watch a server.
    let glance: Glance?
}

struct FleetProvider: TimelineProvider {
    func placeholder(in context: Context) -> FleetEntry {
        FleetEntry(date: Date(), glance: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (FleetEntry) -> Void) {
        completion(FleetEntry(date: Date(), glance: context.isPreview ? .sample : GlanceStore.load()))
    }

    /// Fetches for itself rather than waiting for the app, so the face keeps
    /// moving between visits. The system decides how often this runs.
    func getTimeline(in context: Context, completion: @escaping (Timeline<FleetEntry>) -> Void) {
        Task {
            let glance = await GlanceStore.fetch()
            let next = Date().addingTimeInterval(15 * 60)
            completion(Timeline(entries: [FleetEntry(date: Date(), glance: glance)], policy: .after(next)))
        }
    }
}

struct FleetView: View {
    let entry: FleetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let glance = entry.glance {
            switch family {
            case .accessoryCircular: Circular(glance: glance)
            case .accessoryCorner: Corner(glance: glance)
            case .accessoryInline: Inline(glance: glance)
            default: Rectangular(glance: glance)
            }
        } else {
            Unconfigured(family: family)
        }
    }
}

private struct Circular: View {
    let glance: Glance

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Count(value: glance.working, symbol: "bolt.fill")
                Count(value: glance.review, symbol: "checkmark")
                    .widgetAccentable()
            }
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .opacity(glance.reachable ? 1 : 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.summary(glance))
    }

    static func summary(_ glance: Glance) -> String {
        "\(glance.working) working, \(glance.review) to review"
    }
}

private struct Corner: View {
    let glance: Glance

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: glance.review > 0 ? "checkmark.seal.fill" : "bolt.fill")
                .font(.system(size: 18, weight: .semibold))
                .widgetAccentable()
        }
        .widgetLabel {
            Text(label)
        }
        .accessibilityLabel(Circular.summary(glance))
    }

    private var label: String {
        if !glance.reachable { return "Loom offline" }
        if glance.review > 0 { return "\(glance.review) to review" }
        return glance.working > 0 ? "\(glance.working) working" : "Loom idle"
    }
}

private struct Inline: View {
    let glance: Glance

    var body: some View {
        if glance.reachable {
            Label("\(glance.working) working · \(glance.review) to review", systemImage: "bolt.fill")
        } else {
            Label("Loom offline", systemImage: "wifi.exclamationmark")
        }
    }
}

private struct Rectangular: View {
    let glance: Glance

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(glance.server)
                    .font(.headline)
                    .lineLimit(1)
                    .widgetAccentable()
                Spacer(minLength: 2)
                if glance.reachable {
                    Text(glance.checkedAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.caption2)
                }
            }
            HStack(spacing: 10) {
                Count(value: glance.working, symbol: "bolt.fill")
                Count(value: glance.review, symbol: "checkmark.seal.fill")
                    .widgetAccentable()
                if glance.live > glance.working + glance.review {
                    Count(value: glance.live - glance.working - glance.review, symbol: "pause.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(.body, design: .rounded).weight(.semibold))
            Text(headline)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(glance.reachable ? 1 : 0.6)
    }

    private var headline: String {
        if !glance.reachable { return "Can't reach Loom" }
        guard let title = glance.headline else { return "No agent running" }
        return glance.headlineFinished ? "Done: \(title)" : "Working: \(title)"
    }
}

private struct Count: View {
    let value: Int
    let symbol: String

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
            Text("\(value)")
                .monospacedDigit()
        }
    }
}

private struct Unconfigured: View {
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("Set up Loom on iPhone")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text("Loom")
                    .font(.headline)
                    .widgetAccentable()
                Text("Add a server in Loom on your iPhone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 18, weight: .medium))
                    .widgetAccentable()
            }
        }
    }
}

#Preview(as: .accessoryRectangular) {
    FleetWidget()
} timeline: {
    FleetEntry(date: .now, glance: .sample)
    FleetEntry(date: .now, glance: nil)
}

#Preview(as: .accessoryCircular) {
    FleetWidget()
} timeline: {
    FleetEntry(date: .now, glance: .sample)
}

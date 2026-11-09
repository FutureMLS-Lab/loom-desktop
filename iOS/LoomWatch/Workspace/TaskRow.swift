import SwiftUI

/// A task in a list: its state, its title, and — when the agent has said
/// something worth seeing from the wrist — a line of it.
struct TaskRow: View {
    let item: TaskItem
    /// The project name under the title; off where the list is grouped by it.
    var showsProject = true
    var showsPreview = true

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusOrb(state: item.state, waiting: item.question != nil)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .lineLimit(2)
                if showsPreview, let detail {
                    detail
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(captionTint)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var detail: Text? {
        if let prompt = item.question?.questions?.first?.prompt, !prompt.isEmpty {
            return Text(WatchText.attributed(prompt, limit: 140))
        }
        guard let preview = item.preview, preview.state == item.state else { return nil }
        if item.state == .working, let running = preview.running {
            return Text("\(Image(systemName: "gearshape.2")) \(running)")
        }
        if item.state != .working, !preview.text.isEmpty {
            return Text(WatchText.attributed(preview.text, limit: 140))
        }
        return nil
    }

    private var caption: String {
        var parts: [String] = []
        switch item.state {
        case .working:
            parts.append("Working")
        case .finished:
            if let at = item.finishedAt {
                parts.append("Done \(at.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
            } else {
                parts.append("Done")
            }
        case .idle:
            parts.append(item.question != nil ? "Asks you" : "Ready")
        case nil:
            parts.append("Stopped")
        }
        if showsProject, !item.projectLabel.isEmpty { parts.append(item.projectLabel) }
        return parts.joined(separator: " · ")
    }

    private var captionTint: Color {
        item.state == nil ? Color.secondary : LoomColors.tint(item.state, waiting: item.question != nil)
    }
}

struct StatusOrb: View {
    let state: TaskActivity?
    var waiting = false
    var size: CGFloat = 24
    @Environment(\.isLuminanceReduced) private var luminanceReduced

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.22))
            icon
                .font(.system(size: size * 0.44, weight: .heavy))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var tint: Color { LoomColors.tint(state, waiting: waiting) }

    @ViewBuilder
    private var icon: some View {
        if waiting {
            Image(systemName: "questionmark")
        } else {
            switch state {
            case .working:
                Image(systemName: "ellipsis")
                    .symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: !luminanceReduced)
            case .finished:
                Image(systemName: "checkmark")
            case .idle:
                Image(systemName: "pause.fill")
            case nil:
                Image(systemName: "moon.zzz.fill")
            }
        }
    }
}

struct AgentBadge: View {
    let agent: String

    var body: some View {
        Text(LoomColors.agentName(agent))
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(LoomColors.agent(agent))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(LoomColors.agent(agent).opacity(0.2), in: Capsule())
    }
}

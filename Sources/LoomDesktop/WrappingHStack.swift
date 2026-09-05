import SwiftUI

/// Lays pills out left-to-right and wraps to a new row when the next one would
/// not fit, the way words wrap in a text box: the width is given, the number of
/// rows follows from it. (Adapted from togethercomputer/session-dock.)
struct WrappingHStack: Layout {
    var horizontalSpacing: CGFloat = 10
    var verticalSpacing: CGFloat = 8
    /// Show at most this many rows; the rest are left unplaced and counted in
    /// `Metrics.overflow`. `nil` means every row.
    var maxRows: Int?
    /// A compact strip measures all controls on one intrinsic-width row.
    /// Its window can then fit that row without changing the wrapping limit.
    var measuresIntrinsicWidth = false
    /// Reports what the panel needs to know about the current content.
    /// Delivered asynchronously — this fires from inside a layout pass, which is
    /// no place to be resizing a window.
    var onMeasure: ((Metrics) -> Void)?

    struct Metrics: Equatable {
        /// Size of the wrapped rows at the width currently on offer.
        var contentSize: CGSize
        /// The widest single pill. Pills are never broken, so this is the
        /// narrowest the panel can usefully be — and unlike the widest *row*, it
        /// does not depend on the panel's current width, so using it as the
        /// minimum cannot ratchet against a drag.
        var widestSubview: CGFloat
        /// How many subviews `maxRows` left off screen.
        var overflow: Int = 0
        /// How many subviews were actually placed in the visible rows.
        var visibleSubviews: Int = 0
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let limit = wrapWidth(proposal)
        let all = rows(in: subviews, limit: limit)
        let rows = visible(all)
        let widest = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height }
            + verticalSpacing * CGFloat(max(0, rows.count - 1))

        // The true size of the rows, never inflated to the width on offer — the
        // panel's background is stretched by a frame further out instead.
        let size = CGSize(width: widest, height: height)

        // Skip speculative passes that propose no real width: the rows they
        // produce are not the ones that end up on screen.
        if let onMeasure = onMeasure, limit.isFinite || measuresIntrinsicWidth {
            let widestSubview = subviews
                .map { $0.sizeThatFits(.unspecified).width }
                .max() ?? 0
            let hidden = all.dropFirst(rows.count).reduce(0) { $0 + $1.indices.count }
            let metrics = Metrics(
                contentSize: size,
                widestSubview: widestSubview,
                overflow: hidden,
                visibleSubviews: rows.reduce(0) { $0 + $1.indices.count }
            )
            DispatchQueue.main.async { onMeasure(metrics) }
        }
        return size
    }

    private func visible(_ rows: [Row]) -> [Row] {
        guard let maxRows, maxRows > 0 else { return rows }
        return Array(rows.prefix(maxRows))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        // Deliberately the same proposal `sizeThatFits` measured against, not
        // `bounds.width` — those differ in the overflow case above, and rows
        // broken against a different width than they were measured with would
        // not match the height the panel was sized to.
        let all = rows(in: subviews, limit: wrapWidth(proposal))
        let rows = visible(all)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
        // Rows past the cap still have to be placed — a Layout must place
        // every subview. Park them far off-canvas rather than at the origin
        // with a zero proposal: a zero-proposed capsule still draws at its
        // minimum size, and a stack of them lands on top of the header.
        for row in all.dropFirst(rows.count) {
            for index in row.indices {
                subviews[index].place(
                    at: CGPoint(x: -100_000, y: -100_000),
                    proposal: .zero
                )
            }
        }
    }

    private func wrapWidth(_ proposal: ProposedViewSize) -> CGFloat {
        guard let width = proposal.width, width > 0, width.isFinite else { return .infinity }
        return width
    }

    private func rows(in subviews: Subviews, limit: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let widthWithSubview = row.indices.isEmpty
                ? size.width
                : row.width + horizontalSpacing + size.width

            // A single pill is never split, so a row always keeps at least one.
            if !row.indices.isEmpty && widthWithSubview > limit {
                rows.append(row)
                row = Row(indices: [index], width: size.width, height: size.height)
            } else {
                row.indices.append(index)
                row.width = widthWithSubview
                row.height = max(row.height, size.height)
            }
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

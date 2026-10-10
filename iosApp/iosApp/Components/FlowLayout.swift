import SwiftUI

/// Wrapping layout: places subviews left to right at their ideal size and
/// starts a new row when the next one would overflow the proposed width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    /// Gap between wrapped lines; `spacing` when nil.
    var lineSpacing: CGFloat? = nil
    /// Where each line sits within the width the layout is given.
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let result = computeLayout(maxWidth: maxWidth, subviews: subviews)
        // Never report wider than we were offered — otherwise the single-row
        // intrinsic width inflates the enclosing ScrollView and pushes the
        // sheet past the screen edges.
        return CGSize(width: min(result.size.width, maxWidth), height: result.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(maxWidth: bounds.width, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            let slack = max(0, bounds.width - result.lineWidths[result.lines[index]])
            let offset: CGFloat
            switch alignment {
            case .center: offset = slack / 2
            case .trailing: offset = slack
            default: offset = 0
            }
            subviews[index].place(
                at: CGPoint(x: bounds.minX + offset + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private struct LayoutResult {
        var size: CGSize
        var positions: [CGPoint]
        /// The line each subview landed on, parallel to `positions`.
        var lines: [Int]
        var lineWidths: [CGFloat]
    }

    private func computeLayout(maxWidth: CGFloat, subviews: Subviews) -> LayoutResult {
        var positions: [CGPoint] = []
        var lines: [Int] = []
        var lineWidths: [CGFloat] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                lineWidths.append(x - spacing) // x carries trailing spacing
                x = 0
                y += rowHeight + (lineSpacing ?? spacing)
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            lines.append(lineWidths.count)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        lineWidths.append(x - spacing) // last row
        let widestRow = lineWidths.max() ?? 0

        return LayoutResult(
            size: CGSize(width: max(0, widestRow), height: y + rowHeight),
            positions: positions,
            lines: lines,
            lineWidths: lineWidths
        )
    }
}

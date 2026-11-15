import SwiftUI

extension PlayerMarkerTimeline.Kind {
    /// TheIntroDB's segment colours, shared by every Silo client.
    var timelineColor: Color {
        switch self {
        case .intro: Color(hex: "#51A2FF")
        case .recap: Color(hex: "#FF8904")
        case .credits: Color(hex: "#C27AFF")
        case .preview: Color(hex: "#00D3F2")
        }
    }
}

/// A translucent band for every marker occurrence, drawn above the played
/// fill so a marker stays visible after the playhead passes it.
struct PlayerMarkerBands: View {
    let timeline: PlayerMarkerTimeline
    let duration: Double
    let width: CGFloat
    let height: CGFloat
    let opacity: Double

    var body: some View {
        ForEach(Array(timeline.bands(duration: duration).enumerated()), id: \.offset) { _, band in
            Capsule(style: .continuous)
                .fill(band.kind.timelineColor.opacity(opacity))
                .frame(width: width * (band.end - band.start), height: height)
                .offset(x: width * band.start)
        }
    }
}

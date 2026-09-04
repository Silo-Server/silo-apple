import SwiftUI

/// Button for initiating a download. Currently a stub.
struct DownloadButton: View {
    enum DownloadState {
        case notDownloaded
        case downloading(progress: Double)
        case downloaded
    }

    let state: DownloadState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                switch state {
                case .notDownloaded:
                    Image(systemName: "arrow.down.circle")
                        .foregroundColor(.siloSecondaryText)

                case .downloading(let progress):
                    ZStack {
                        Circle()
                            .stroke(Color.siloSecondaryText.opacity(0.3), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.siloPrimary, lineWidth: 2)
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 22, height: 22)

                case .downloaded:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.siloSuccess)
                }
            }
            .font(.system(size: 22))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Download")
    }
}

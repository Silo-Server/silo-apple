import SwiftUI

#if os(iOS)
/// The streaming qualities with their bitrates, one row each and a checkmark
/// on the active one. Pushed from Playback Settings and shown on its own by
/// the player's Quality pill.
struct QualityList: View {
    let viewModel: PlayerViewModel

    var body: some View {
        List {
            Section {
                ForEach(viewModel.qualityOptions) { option in
                    Button {
                        viewModel.switchQuality(option.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .foregroundStyle(.primary)
                                if let subtitle = option.subtitle {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if option.id == viewModel.highlightedQualityOptionId {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    // Plain: a tinted row would draw the whole label, bitrate
                    // included, in the accent colour.
                    .buttonStyle(.plain)
                    .disabled(viewModel.isQualitySwitching)
                }
            } footer: {
                if viewModel.isQualitySwitching {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(.playerQualitySwitching)
                    }
                } else if let error = viewModel.qualitySwitchError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        .contentMargins(.top, 8, for: .scrollContent)
        .navigationTitle(Text(.optionsQuality))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The Quality pill's sheet: a scrolling list, where a native menu would
/// clip its last rows in landscape and cover the transport.
struct QualitySheet: View {
    let viewModel: PlayerViewModel
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            QualityList(viewModel: viewModel)
                .playerSheetNavigationBar()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { onDismiss() } label: { Text(.commonDone) }
                    }
                }
        }
        .preferredColorScheme(.dark)
    }
}

extension View {
    /// An opaque bar over the player's menu lists: rows scrolled under a
    /// translucent bar show through it and read as cut off.
    func playerSheetNavigationBar() -> some View {
        toolbarBackground(Color(white: 0.06), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}
#endif

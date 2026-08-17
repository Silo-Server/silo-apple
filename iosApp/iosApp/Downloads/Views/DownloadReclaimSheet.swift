#if !os(tvOS)
import SwiftUI

/// "Free Up Space" review sheet: every downloaded-and-watched item,
/// pre-selected, so the most common cleanup is a single confirmed tap.
/// The user can deselect anything they want to keep.
struct DownloadReclaimSheet: View {
    @Environment(\.dismiss) private var dismiss
    private var manager: DownloadManager { DownloadManager.shared }

    /// Record ids the user has chosen to keep (everything starts selected).
    @State private var kept: Set<String> = []

    private var records: [DownloadRecord] { manager.reclaimableRecords }
    private var selected: [DownloadRecord] { records.filter { !kept.contains($0.id) } }
    private var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.fileSize } }
    private var allSelected: Bool { kept.isEmpty }

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    EmptyStateView(
                        icon: "checkmark.circle",
                        title: "All Caught Up",
                        subtitle: "There are no watched downloads to clear right now."
                    )
                    .background(Color.siloBackground)
                } else {
                    list
                }
            }
            .navigationTitle("Free Up Space")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !records.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button(allSelected ? "Deselect All" : "Select All") { toggleAll() }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .siloToolbarColorSchemeDark()
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                header
                ForEach(records) { record in
                    row(record)
                    Divider().overlay(Color.siloDivider).padding(.leading, 56)
                }
                Color.clear.frame(height: 24)
            }
        }
        .background(Color.siloBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(records.count) item\(records.count == 1 ? "" : "s") you've finished watching")
                .font(.system(size: 13))
                .foregroundColor(.siloSecondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func row(_ record: DownloadRecord) -> some View {
        Button {
            toggle(record.id)
        } label: {
            HStack(spacing: 12) {
                DownloadSelectionCircle(selected: !kept.contains(record.id))
                ThumbhashImage(thumbhash: record.posterThumbhash)
                    .frame(width: 48, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(label(record))
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(.siloOnSurface)
                        .lineLimit(1)
                    Text("Watched")
                        .font(.system(size: 11.5))
                        .foregroundColor(.siloSecondaryText)
                }
                Spacer(minLength: 8)
                Text(DownloadFormatting.bytes(record.fileSize))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.siloOnSurface)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var bottomBar: some View {
        if !records.isEmpty {
            VStack(spacing: 9) {
                Button {
                    manager.deleteDownloads(ids: selected.map(\.id))
                    dismiss()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "trash")
                        Text("Delete \(selected.count) · Free \(DownloadFormatting.bytes(selectedBytes))")
                            .fontWeight(.bold)
                    }
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(selected.isEmpty ? Color.siloDisabled : Color.siloOnSurface)
                    .foregroundColor(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(selected.isEmpty)

                Button("Not now") { dismiss() }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.siloOnSurface)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(Color.siloChromeRestingFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .stroke(Color.siloChromeRestingBorder, lineWidth: 1)
                            )
                    )
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(.ultraThinMaterial)
        }
    }

    private func label(_ record: DownloadRecord) -> String {
        guard record.seriesId != nil else { return record.title ?? record.contentId }
        let tag = [record.seasonNumber.map { "S\($0)" }, record.episodeNumber.map { "E\($0)" }]
            .compactMap { $0 }
            .joined()
        let series = record.seriesTitle ?? record.title ?? ""
        return tag.isEmpty ? (record.title ?? series) : "\(series) · \(tag)"
    }

    private func toggle(_ id: String) {
        if kept.contains(id) { kept.remove(id) } else { kept.insert(id) }
    }

    private func toggleAll() {
        if allSelected { kept = Set(records.map(\.id)) }
        else { kept.removeAll() }
    }
}
#endif

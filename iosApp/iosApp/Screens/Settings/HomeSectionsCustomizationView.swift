#if !os(tvOS)
import SwiftUI

/// Settings → Interface → Home Sections on iPhone, iPad and Mac. Edits the
/// acting profile's Home layout on the server (see `HomeSectionsEditorModel`),
/// so the order and visibility apply to this profile on every device. The eye
/// shows or hides a row; Edit (iOS) or a drag (Mac) reorders, and Move Up /
/// Move Down are offered as accessibility actions and in each row's context
/// menu for VoiceOver, keyboard and pointer users.
struct HomeSectionsCustomizationView: View {
    @State private var model = HomeSectionsEditorModel()

    var body: some View {
        List {
            if let error = model.saveError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.siloOnSurface)
                }
            }

            Section {
                switch model.phase {
                case .loading:
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 16)
                    .accessibilityLabel("Loading Home sections")
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn’t Load Home Sections", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") {
                            Task { await model.load() }
                        }
                    }
                case .loaded where model.rows.isEmpty:
                    ContentUnavailableView(
                        "No Home Sections",
                        systemImage: "rectangle.3.group",
                        description: Text("This profile’s Home has no rows to arrange yet.")
                    )
                case .loaded:
                    ForEach(model.rows) { row in
                        sectionRow(row)
                    }
                    .onMove { source, destination in
                        model.move(fromOffsets: source, toOffset: destination)
                    }
                }
            } footer: {
                if model.phase == .loaded, !model.rows.isEmpty {
                    Text(footerText)
                }
            }
        }
        #if os(macOS)
        .settingsListChrome()
        #else
        .siloGroupedListStyle()
        #endif
        .navigationTitle("Home Sections")
        #if os(iOS)
        .toolbar {
            if model.phase == .loaded, model.rows.count > 1 {
                EditButton()
            }
        }
        #endif
        .task {
            await model.load()
        }
        .refreshable {
            await model.load()
        }
    }

    private var footerText: String {
        #if os(macOS)
        "Open eye: shown on Home. Closed eye: hidden and dimmed here. Drag rows into a new order. Changes save to this profile and apply on all of its devices."
        #else
        "Open eye: shown on Home. Closed eye: hidden and dimmed here. Tap Edit to drag rows into a new order. Changes save to this profile and apply on all of its devices."
        #endif
    }

    private func sectionRow(_ row: APIv2ProfileSectionSetting) -> some View {
        let isVisible = !row.hidden
        return HStack(spacing: 12) {
            Button {
                model.setHidden(isVisible, id: row.id)
            } label: {
                Image(systemName: isVisible ? "eye.fill" : "eye.slash.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isVisible ? Color.siloOnSurface : Color.siloSecondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isVisible ? "Hide \(row.title)" : "Show \(row.title)")

            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.siloOnSurface)
                    .lineLimit(1)

                if let detail = detail(for: row) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Color.siloSecondaryText)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(isVisible ? "Shown on Home" : "Hidden from Home")

            Spacer(minLength: 8)
        }
        .opacity(isVisible ? 1 : 0.42)
        .animation(.easeInOut(duration: SiloTheme.fastDuration), value: isVisible)
        .accessibilityActions {
            if model.canMove(id: row.id, by: -1) {
                Button("Move Up") { model.move(id: row.id, by: -1) }
            }
            if model.canMove(id: row.id, by: 1) {
                Button("Move Down") { model.move(id: row.id, by: 1) }
            }
        }
        .contextMenu {
            Button {
                model.move(id: row.id, by: -1)
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            .disabled(!model.canMove(id: row.id, by: -1))

            Button {
                model.move(id: row.id, by: 1)
            } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
            .disabled(!model.canMove(id: row.id, by: 1))

            Button {
                model.setHidden(isVisible, id: row.id)
            } label: {
                Label(isVisible ? "Hide" : "Show", systemImage: isVisible ? "eye.slash" : "eye")
            }
        }
    }

    private func detail(for row: APIv2ProfileSectionSetting) -> String? {
        if row.isCustom { return "Added by this profile" }
        if row.title != row.defaultTitle, !row.defaultTitle.isEmpty { return "Renamed from \(row.defaultTitle)" }
        return nil
    }
}
#endif

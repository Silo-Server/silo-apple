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
    @Environment(\.locale) private var locale

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
                    .accessibilityLabel(Text(.homeProfileEditorLoading))
                case .failed(let message):
                    ContentUnavailableView {
                        Label(.homeProfileEditorLoadFailedTitle, systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button(.homeProfileEditorTryAgain) {
                            Task { await model.load() }
                        }
                    }
                case .loaded where model.rows.isEmpty:
                    ContentUnavailableView {
                        Label(.homeProfileEditorEmptyTitle, systemImage: "rectangle.3.group")
                    } description: {
                        Text(.homeProfileEditorEmptyBody)
                    }
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
        .navigationTitle(Text(.homeProfileEditorTitle))
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

    private var footerText: LocalizedStringResource {
        #if os(macOS)
        .homeProfileEditorFooterMac
        #else
        .homeProfileEditorFooterTouch
        #endif
    }

    private func sectionRow(_ row: APIv2ProfileSectionSetting) -> some View {
        let isVisible = !row.hidden
        let title = row.displayTitle(in: locale)
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
            .accessibilityLabel(Text(isVisible ? .homeProfileEditorHideRow(title) : .homeProfileEditorShowRow(title)))

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title)
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
            .accessibilityValue(Text(isVisible ? .homeProfileEditorRowShown : .homeProfileEditorRowHidden))

            Spacer(minLength: 8)
        }
        .opacity(isVisible ? 1 : 0.42)
        .animation(.easeInOut(duration: SiloTheme.fastDuration), value: isVisible)
        .accessibilityActions {
            if model.canMove(id: row.id, by: -1) {
                Button(.homeProfileEditorMoveUp) { model.move(id: row.id, by: -1) }
            }
            if model.canMove(id: row.id, by: 1) {
                Button(.homeProfileEditorMoveDown) { model.move(id: row.id, by: 1) }
            }
        }
        .contextMenu {
            Button {
                model.move(id: row.id, by: -1)
            } label: {
                Label(.homeProfileEditorMoveUp, systemImage: "arrow.up")
            }
            .disabled(!model.canMove(id: row.id, by: -1))

            Button {
                model.move(id: row.id, by: 1)
            } label: {
                Label(.homeProfileEditorMoveDown, systemImage: "arrow.down")
            }
            .disabled(!model.canMove(id: row.id, by: 1))

            Button {
                model.setHidden(isVisible, id: row.id)
            } label: {
                Label(isVisible ? .homeProfileEditorHide : .homeProfileEditorShow, systemImage: isVisible ? "eye.slash" : "eye")
            }
        }
    }

    private func detail(for row: APIv2ProfileSectionSetting) -> LocalizedStringResource? {
        if row.isCustom { return .homeProfileEditorAddedByProfile }
        if row.title != row.defaultTitle, !row.defaultTitle.isEmpty {
            return .homeProfileEditorRenamedFrom(row.displayDefaultTitle(in: locale))
        }
        return nil
    }
}
#endif

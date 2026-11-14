#if os(iOS)
import SwiftUI

/// The iPhone Libraries tab's section switcher: which of the library's
/// pages (Recommended, Browse, Collections) is on screen, and the actions
/// the dock offers. The Libraries tab owns it; the tab bar's accessory slot
/// reads it through `PageDockHost`.
@Observable
@MainActor
final class LibraryDockModel: PageDockModel {
    /// The page on screen. The Libraries tab keeps the truth and mirrors it
    /// here; the dock asks for changes through `select(_:)`.
    var selectedTab: LibraryPageTab = .recommended
    /// The library has collections (as it last loaded), so the dock offers
    /// that page. Set when a library opens, never while it's on screen.
    var hasCollections = true
    var library: Library?
    /// Every library the switcher menu offers, in the tab's order.
    var libraries: [Library] = []
    /// Bumped on every segment tap, for the selection haptic.
    private(set) var feedbackCount = 0

    @ObservationIgnored var onSelect: (LibraryPageTab) -> Void = { _ in }
    @ObservationIgnored var onScrollToTop: (LibraryPageTab) -> Void = { _ in }
    @ObservationIgnored var onPickLibrary: (Int) -> Void = { _ in }

    /// With one library the library button is inert.
    var canSwitchLibrary: Bool { libraries.count > 1 }
    var leadingButtonIsInteractive: Bool { canSwitchLibrary }
    var allTabs: [LibraryPageTab] { LibraryPageTab.allCases }

    func leadingButton(style: PageDockStyle) -> LibraryDockLibraryButton {
        LibraryDockLibraryButton(model: self, style: style)
    }

    /// Recommended, Browse, Collections: the order the dock shows them.
    var visibleTabs: [LibraryPageTab] {
        [.recommended, .library, .collections].filter { $0 != .collections || hasCollections }
    }

    /// A segment was tapped: show its page, or scroll the page already on
    /// screen back to its top.
    func select(_ tab: LibraryPageTab) {
        feedbackCount += 1
        if tab == selectedTab {
            onScrollToTop(tab)
        } else {
            selectedTab = tab
            onSelect(tab)
        }
    }

    /// A drag across the switcher ended over `tab`: show its page. Ending
    /// where it started changes nothing, and never scrolls to the top.
    func commitDrag(to tab: LibraryPageTab) {
        guard tab != selectedTab else { return }
        selectedTab = tab
        onSelect(tab)
    }
}

extension LibraryPageTab: PageDockSegment {
    /// Stands in for the title at accessibility text sizes.
    var dockIcon: String {
        switch self {
        case .recommended: return "sparkles"
        case .library: return "square.grid.3x3"
        case .collections: return "square.stack.3d.up"
        }
    }

    /// The dock's name for the page; the Library page reads as Browse there.
    var dockTitle: LocalizedStringResource {
        self == .library ? .libraryBrowse : title
    }
}

/// The library button: a system menu of the profile's libraries, grouped
/// Watch, Listen, Read, with a checkmark on the one on screen. With one
/// library it is inert.
struct LibraryDockLibraryButton: View {
    let model: LibraryDockModel
    let style: PageDockStyle

    var body: some View {
        Group {
            if model.canSwitchLibrary {
                Menu {
                    LibraryDockLibraryMenu(model: model)
                } label: {
                    glyph
                }
                .menuOrder(.fixed)
                .buttonStyle(.plain)
                .accessibilityHint(Text(verbatim: LibraryDockPendingText.switchLibraryHint))
            } else {
                glyph
            }
        }
        .accessibilityLabel(Text(verbatim: model.library?.name ?? ""))
        .accessibilityShowsLargeContentViewer {
            Label {
                Text(verbatim: model.library?.name ?? "")
            } icon: {
                Image(systemName: iconName)
            }
        }
    }

    private var iconName: String {
        model.library.map(LibraryDockLibraryIcon.name(for:)) ?? "square.stack.3d.up"
    }

    private var glyph: some View {
        PageDockGlyph(systemName: iconName, style: style)
    }
}

/// The libraries as menu items: one inline picker per group, so the system
/// draws its own checkmark on the library on screen. Group headings show
/// only when more than one group has libraries.
private struct LibraryDockLibraryMenu: View {
    let model: LibraryDockModel

    var body: some View {
        let groups = LibraryDockLibraryGroup.grouped(model.libraries)
        let selection = Binding<Int>(
            get: { model.library?.id ?? -1 },
            set: { model.onPickLibrary($0) }
        )
        ForEach(groups, id: \.group) { entry in
            Section {
                Picker(selection: selection) {
                    ForEach(entry.libraries) { library in
                        Label {
                            Text(verbatim: library.name)
                        } icon: {
                            Image(systemName: LibraryDockLibraryIcon.name(for: library))
                        }
                        .tag(library.id)
                    }
                } label: {
                    Text(verbatim: entry.group.title)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                if groups.count > 1 {
                    Text(verbatim: entry.group.title)
                }
            }
        }
    }
}

/// What you do with a library: the switcher menu's groups.
private enum LibraryDockLibraryGroup: CaseIterable, Hashable {
    case watch
    case listen
    case read

    /// Libraries of a kind the app does not know yet fall under Watch, so a
    /// library is never dropped from the menu.
    init(library: Library) {
        if library.isAudiobookLibrary || library.isMusicLibrary {
            self = .listen
        } else if library.isBookLibrary {
            self = .read
        } else {
            self = .watch
        }
    }

    var title: String {
        switch self {
        case .watch: return LibraryDockPendingText.watchHeading
        case .listen: return LibraryDockPendingText.listenHeading
        case .read: return LibraryDockPendingText.readHeading
        }
    }

    /// Groups in Watch, Listen, Read order, skipping empty ones. Libraries
    /// keep the tab's order inside each group.
    static func grouped(_ libraries: [Library]) -> [(group: LibraryDockLibraryGroup, libraries: [Library])] {
        let grouped = Dictionary(grouping: libraries, by: LibraryDockLibraryGroup.init(library:))
        return allCases.compactMap { group in
            guard let members = grouped[group], !members.isEmpty else { return nil }
            return (group, members)
        }
    }
}

private enum LibraryDockLibraryIcon {
    static func name(for library: Library) -> String {
        if library.isAudiobookLibrary { return "book.closed" }
        if library.isMixedLibrary { return "square.stack.3d.up" }
        if library.isSeriesLibrary { return "tv" }
        if library.isMovieLibrary { return "film" }
        if library.isMusicLibrary { return "music.note" }
        if library.isBookLibrary { return "books.vertical" }
        return "square.stack.3d.up"
    }
}

extension Library {
    /// The server's library kind, trimmed and lowercased once, as
    /// `SiloMediaType` compares it.
    private var normalizedKind: String {
        type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isMusicLibrary: Bool { normalizedKind == "music" }

    var isBookLibrary: Bool {
        switch normalizedKind {
        case "book", "books", "ebook", "ebooks": return true
        default: return false
        }
    }
}

/// Hands the selected library page's scroll view to the tab, so the tab bar
/// minimises with the page on screen. The Libraries tab keeps every page it
/// has shown alive, stacked, and the system otherwise follows whichever
/// scroll view the tab showed first.
///
/// Placed as a page's background, it finds the page's scroll view among
/// the views SwiftUI places after it, and passes it to the view controller
/// the tab bar controller holds for the tab. It looks when the page is
/// selected, when it reaches the window, and when the page's scroll view
/// appears later (a page still loading has none yet), which the page's
/// `LibraryPageScrollViewMarker` reports through `link`.
struct LibraryPageScrollClaim: UIViewRepresentable {
    let isActive: Bool
    let link: LibraryPageScrollClaimLink

    func makeUIView(context: Context) -> LibraryPageScrollClaimView {
        LibraryPageScrollClaimView()
    }

    func updateUIView(_ view: LibraryPageScrollClaimView, context: Context) {
        link.claimView = view
        let becameActive = isActive && !view.isActive
        view.isActive = isActive
        if becameActive { view.claimSoon() }
    }
}

/// Connects a page's scroll view, when it appears, to the page's claim.
@MainActor
final class LibraryPageScrollClaimLink {
    fileprivate weak var claimView: LibraryPageScrollClaimView?

    func scrollViewAppeared() {
        claimView?.claimSoon()
    }
}

extension EnvironmentValues {
    /// The selected library page's claim on the tab bar's scroll view. Nil
    /// outside the iPhone Libraries tab.
    @Entry var libraryPageScrollClaimLink: LibraryPageScrollClaimLink? = nil
}

extension View {
    /// Tells the Libraries tab when this page's scroll view appears, so the
    /// tab bar can follow it. Does nothing outside the Libraries tab.
    func reportsLibraryPageScrollView() -> some View {
        background { LibraryPageScrollViewMarker() }
    }
}

private struct LibraryPageScrollViewMarker: UIViewRepresentable {
    @Environment(\.libraryPageScrollClaimLink) private var link

    func makeUIView(context: Context) -> MarkerView {
        MarkerView()
    }

    func updateUIView(_ view: MarkerView, context: Context) {
        view.link = link
    }

    final class MarkerView: UIView {
        var link: LibraryPageScrollClaimLink?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { link?.scrollViewAppeared() }
        }
    }
}

final class LibraryPageScrollClaimView: UIView {
    var isActive = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if isActive { claimSoon() }
    }

    /// After SwiftUI's update, once the page's views are in place.
    func claimSoon() {
        DispatchQueue.main.async { [weak self] in self?.claim() }
    }

    private func claim() {
        guard isActive, window != nil, let scrollView = pageScrollView() else { return }
        var responder: UIResponder? = scrollView
        while let next = responder {
            if let controller = next as? UIViewController, controller.parent is UITabBarController {
                if controller.contentScrollView(for: .bottom) !== scrollView {
                    controller.setContentScrollView(scrollView, for: .bottom)
                }
                return
            }
            responder = next.next
        }
    }

    /// The first vertical scroll view drawn after this marker and before
    /// the next page's marker: this page's own. SwiftUI wraps the marker in
    /// containers of its own, so the search climbs until the page's views
    /// come after the marker's branch.
    private func pageScrollView() -> UIScrollView? {
        var branch: UIView = self
        var levels = 0
        while let parent = branch.superview, levels < 8 {
            if let start = parent.subviews.firstIndex(of: branch) {
                for sibling in parent.subviews[(start + 1)...] {
                    if Self.containsClaim(sibling) { return nil }
                    if let found = Self.verticalScrollView(in: sibling) { return found }
                }
            }
            branch = parent
            levels += 1
        }
        return nil
    }

    private static func containsClaim(_ root: UIView) -> Bool {
        if root is LibraryPageScrollClaimView { return true }
        return root.subviews.contains { containsClaim($0) }
    }

    /// Breadth first, so a page's own scroll view wins over the media rows
    /// inside it.
    private static func verticalScrollView(in root: UIView) -> UIScrollView? {
        var queue = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scrollView = view as? UIScrollView,
               scrollView.alwaysBounceVertical || scrollView.contentSize.height > scrollView.bounds.height {
                return scrollView
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}

/// "1,284 movies": a library's size, named for what it holds.
func libraryCountLabel(_ count: Int, library: Library, scope: LibraryVideoScope?) -> LocalizedStringResource {
    let text = LocaleFormat.integer(count)
    if library.isAudiobookLibrary { return .libraryCollectionCardBooks(count: count, text) }
    switch scope {
    case .movie: return .libraryCollectionCardMovies(count: count, text)
    case .series: return .libraryCollectionCardShows(count: count, text)
    case nil: break
    }
    if library.isSeriesLibrary { return .libraryCollectionCardShows(count: count, text) }
    if library.isMovieLibrary && !library.isMixedLibrary { return .libraryCollectionCardMovies(count: count, text) }
    return .libraryTitleCount(count: count, text)
}

/// English for the iPhone Libraries dock's new text, until silo-translations
/// carries keys for it. Each line names the key it should become.
enum LibraryDockPendingText {
    static let switchLibraryHint = "Switch library" // i18n-ignore: pending key library.page.a11ySwitchLibrary
    static let watchHeading = "Watch" // i18n-ignore: pending key library.switcher.watch
    static let listenHeading = "Listen" // i18n-ignore: pending key library.switcher.listen
    static let readHeading = "Read" // i18n-ignore: pending key library.switcher.read
    static let sectionsLabel = "Sections" // i18n-ignore: pending key library.page.a11ySections
}
#endif

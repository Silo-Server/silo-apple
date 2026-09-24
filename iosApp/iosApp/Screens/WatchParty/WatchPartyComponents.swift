#if os(iOS) || os(tvOS)
import SwiftUI

extension WatchPartySession {
    /// Whether room controls lock while a request runs. tvOS keeps them
    /// enabled: disabling the focused control throws focus elsewhere, and
    /// every session call ignores a repeat until the first one returns.
    var locksControls: Bool {
        #if os(tvOS)
        false
        #else
        isBusy
        #endif
    }
}

/// Platform metrics for the lobby. tvOS values are mockup pixels at 1920×1080.
enum WatchPartyMetrics {
    #if os(tvOS)
    static let seat: CGFloat = 128
    static let seatGap: CGFloat = 36
    static let pageInset: CGFloat = 88
    static let heroTitle: CGFloat = 88
    static let body: CGFloat = 26
    static let caption: CGFloat = 20
    static let eyebrow: CGFloat = 17
    static let code: CGFloat = 30
    static let ballotPoster = CGSize(width: 220, height: 330)
    #else
    static let seat: CGFloat = 56
    static let seatGap: CGFloat = 12
    static let pageInset: CGFloat = 20
    static let heroTitle: CGFloat = 28
    static let body: CGFloat = 15
    static let caption: CGFloat = 13
    static let eyebrow: CGFloat = 11
    static let code: CGFloat = 20
    static let ballotPoster = CGSize(width: 44, height: 66)
    #endif
}

// MARK: - Eyebrow

struct WatchPartyEyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: WatchPartyMetrics.eyebrow, weight: .semibold))
            .tracking(WatchPartyMetrics.eyebrow * 0.12)
            .foregroundStyle(Color.siloSecondaryText)
    }
}

// MARK: - Backdrop

/// Full-bleed artwork under the lobby. The film is the room, so its backdrop
/// (or poster, when that is all the catalog has) tints the whole screen.
struct WatchPartyBackdrop: View {
    let url: String?
    var thumbhash: String? = nil
    var isPoster = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.siloBackground
                if let url, !url.isEmpty {
                    AsyncImageView(url: url, thumbhash: thumbhash, contentMode: .fill, placeholderStyle: .clear)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .blur(radius: isPoster ? 28 : 0)
                        .opacity(isPoster ? 0.7 : 1)
                        .transition(.opacity)
                }
                gradient
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .animation(.easeOut(duration: SiloTheme.slowDuration), value: url)
    }

    private var gradient: some View {
        #if os(tvOS)
        ZStack {
            LinearGradient(stops: [
                .init(color: .black.opacity(0.92), location: 0),
                .init(color: .black.opacity(0.78), location: 0.34),
                .init(color: .black.opacity(0.25), location: 0.62),
                .init(color: .black.opacity(0.05), location: 1),
            ], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [
                .init(color: .black.opacity(0.35), location: 0),
                .init(color: .clear, location: 0.3),
                .init(color: .black.opacity(0.4), location: 0.7),
                .init(color: .black.opacity(0.95), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        #else
        LinearGradient(stops: [
            .init(color: .black.opacity(0.6), location: 0),
            .init(color: .black.opacity(0.25), location: 0.22),
            .init(color: .black.opacity(0.72), location: 0.45),
            .init(color: .black.opacity(0.94), location: 0.62),
            .init(color: .black, location: 0.78),
        ], startPoint: .top, endPoint: .bottom)
        #endif
    }
}

// MARK: - Code pill

/// The room code is the invitation. One pill, monospaced, opens the share sheet.
struct WatchPartyCodePill: View {
    let code: String
    var showsLabel = true
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: WatchPartyMetrics.code * 0.5) {
            #if os(tvOS)
            if showsLabel {
                Text("JOIN WITH")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(isFocused ? Color.black.opacity(0.5) : Color.siloSecondaryText)
            }
            #endif
            Text(code)
                .font(.system(size: WatchPartyMetrics.code, weight: .bold, design: .monospaced))
                .tracking(WatchPartyMetrics.code * 0.18)
            Image(systemName: "qrcode")
                .font(.system(size: WatchPartyMetrics.code * 0.8, weight: .medium))
                .foregroundStyle(isFocused ? Color.black.opacity(0.6) : Color.siloSecondaryText)
        }
        #if os(iOS)
        .foregroundStyle(isFocused ? Color.black : Color.siloOnSurface)
        .padding(.horizontal, WatchPartyMetrics.code * 0.75)
        .padding(.vertical, WatchPartyMetrics.code * 0.4)
        .background(Capsule().fill(isFocused ? Color.siloOnSurface : Color.siloChromeRestingFill))
        .overlay(Capsule().stroke(isFocused ? Color.clear : Color.siloChromeRestingBorder, lineWidth: 1))
        .scaleEffect(isFocused ? 1.04 : 1)
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
        #endif
        .accessibilityLabel("Party code \(code.map(String.init).joined(separator: " ")). Invite friends")
    }
}

// MARK: - Seats

/// One member as a seat: an avatar disc whose ring encodes state. Dashed grey
/// means here but not ready, solid white with a tick means ready, dotted and
/// dimmed means disconnected.
struct WatchPartySeat: View {
    let member: WatchPartyMember
    let state: WatchPartySeatState
    var size: CGFloat = WatchPartyMetrics.seat

    private var ringDiameter: CGFloat { size * 1.14 }

    var body: some View {
        VStack(spacing: size * 0.11) {
            ZStack {
                Circle()
                    .fill(Self.avatarGradient(for: member.id))
                    .overlay {
                        Text(initial)
                            .font(.system(size: size * 0.36, weight: .semibold))
                            .foregroundStyle(Color.siloOnSurface)
                    }
                    .frame(width: size, height: size)
                    .opacity(state == .away ? 0.45 : 1)
                Circle()
                    .strokeBorder(ringColor, style: ringStyle)
            }
            .frame(width: ringDiameter, height: ringDiameter)
            .overlay {
                if state == .ready || state == .watching {
                    // Sits on the ring at 4:30, cutting into it.
                    Circle()
                        .fill(Color.siloOnSurface)
                        .overlay {
                            Image(systemName: "checkmark")
                                .font(.system(size: size * 0.15, weight: .heavy))
                                .foregroundStyle(Color.black)
                        }
                        .padding(size * 0.03)
                        .background(Circle().fill(Color.black))
                        .frame(width: size * 0.34, height: size * 0.34)
                        .offset(x: ringDiameter / 2 * 0.7071, y: ringDiameter / 2 * 0.7071)
                }
            }
            .padding(.top, size * 0.1)
            VStack(spacing: size * 0.02) {
                Text(member.displayName)
                    .font(.system(size: size * 0.19, weight: .medium))
                    .foregroundStyle(Color.siloOnSurface)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detailText {
                    Text(detailText)
                        .font(.system(size: size * 0.16))
                        .foregroundStyle(Color.siloSecondaryText)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: size * 1.4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Role and state under the name: "Host · You", "not ready".
    private var detailText: String? {
        let parts = [member.isHost ? "Host" : nil, member.isSelf ? "You" : nil, statusText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var initial: String {
        String(member.displayName.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    private var statusText: String? {
        switch state {
        case .ready, .watching: return nil
        case .notReady: return "not ready"
        case .away: return "reconnecting"
        case .syncing: return "syncing"
        case .buffering: return "buffering"
        case .joining: return "joining"
        }
    }

    private var accessibilityText: String {
        var parts = [member.displayName]
        if member.isSelf { parts.append("you") }
        if member.isHost { parts.append("host") }
        switch state {
        case .ready: parts.append("ready")
        case .watching: parts.append("watching")
        default: parts.append(statusText ?? "")
        }
        return parts.joined(separator: ", ")
    }

    private var ringColor: Color {
        switch state {
        case .ready, .watching: return .siloOnSurface
        case .away: return .siloOnSurface.opacity(0.25)
        default: return .siloOnSurface.opacity(0.38)
        }
    }

    private var ringStyle: StrokeStyle {
        let width = size * 0.035
        switch state {
        case .ready, .watching: return StrokeStyle(lineWidth: width)
        case .away: return StrokeStyle(lineWidth: width, lineCap: .round, dash: [0.1, width * 3])
        default: return StrokeStyle(lineWidth: width, dash: [width * 3, width * 2.2])
        }
    }

    private static let palette: [(Color, Color)] = [
        (Color(hex: "#5A4A8A"), Color(hex: "#2B2450")),
        (Color(hex: "#8A5A3A"), Color(hex: "#4A2C1C")),
        (Color(hex: "#3A7A6A"), Color(hex: "#1C3F36")),
        (Color(hex: "#7A3A5A"), Color(hex: "#3F1C30")),
        (Color(hex: "#4A6A8A"), Color(hex: "#213546")),
        (Color(hex: "#7A6A2A"), Color(hex: "#3F3616")),
    ]

    static func avatarGradient(for id: String) -> LinearGradient {
        let index = abs(id.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }) % palette.count
        let pair = palette[index]
        return LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// The dashed "+" seat that opens the invitation.
struct WatchPartyInviteSeatLabel: View {
    var size: CGFloat = WatchPartyMetrics.seat
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(spacing: size * 0.11) {
            ZStack {
                Circle()
                    .fill(isFocused ? Color.siloOnSurface : Color.clear)
                    .frame(width: size, height: size)
                Circle()
                    .strokeBorder(isFocused ? Color.clear : Color.siloOutline, lineWidth: size * 0.035)
                    .frame(width: size * 1.14, height: size * 1.14)
                Image(systemName: "plus")
                    .font(.system(size: size * 0.4, weight: .light))
                    .foregroundStyle(isFocused ? Color.black : Color.siloSecondaryText)
            }
            .frame(width: size * 1.14, height: size * 1.14)
            .padding(.top, size * 0.1)
            .scaleEffect(isFocused ? 1.06 : 1)
            Text("Invite")
                .font(.system(size: size * 0.19, weight: .medium))
                .foregroundStyle(Color.siloSecondaryText)
        }
        .frame(width: size * 1.4)
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
        #if os(tvOS)
        .focusEffectDisabled()
        #endif
    }
}

struct WatchPartySeatsRow: View {
    let members: [WatchPartyMember]
    let phase: WatchPartyPhase
    let onInvite: () -> Void
    var seatSize: CGFloat = WatchPartyMetrics.seat

    private var ordered: [WatchPartyMember] {
        members.sorted { lhs, rhs in
            if lhs.isHost != rhs.isHost { return lhs.isHost }
            if lhs.isSelf != rhs.isSelf { return lhs.isSelf }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: seatSize * 0.25) {
            HStack(alignment: .firstTextBaseline, spacing: seatSize * 0.2) {
                WatchPartyEyebrow(text: "Here now")
                Text(WatchPartyLobbyPolicy.presenceSummary(members: members, phase: phase))
                    .font(.system(size: WatchPartyMetrics.caption))
                    .foregroundStyle(Color.siloSecondaryText.opacity(0.7))
                Spacer(minLength: 0)
            }
            seats
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Members")
    }

    @ViewBuilder
    private var seats: some View {
        #if os(tvOS)
        HStack(alignment: .top, spacing: WatchPartyMetrics.seatGap) {
            seatContent
        }
        .focusSection()
        #else
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: WatchPartyMetrics.seatGap) {
                seatContent
            }
            .padding(.horizontal, 2)
        }
        .scrollClipDisabled()
        #endif
    }

    private var seatContent: some View {
        Group {
            ForEach(ordered) { member in
                WatchPartySeat(member: member, state: WatchPartyLobbyPolicy.seatState(member, phase: phase), size: seatSize)
            }
            Button(action: onInvite) { WatchPartyInviteSeatLabel(size: seatSize) }
                .buttonStyle(.siloFlat)
                .accessibilityLabel("Invite friends")
                .accessibilityIdentifier("watchParty.invite")
        }
    }
}

// MARK: - Buttons

enum WatchPartyButtonKind { case primary, secondary, outlined }

/// tvOS actions share the media detail buttons' focus and press treatment.
struct WatchPartyButtonStyle: ButtonStyle {
    var kind: WatchPartyButtonKind = .primary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        #if os(tvOS)
        TVPillButtonStyle(
            kind: kind == .primary ? .primary : .secondary,
            focusTreatment: .compact,
            stabilizesFocusMotion: true
        )
        .makeBody(configuration: configuration)
        .font(.system(size: kind == .primary ? 29 : 26, weight: .semibold))
        .lineLimit(1)
        .opacity(isEnabled ? 1 : 0.45)
        #else
        WatchPartyButtonBody(configuration: configuration, kind: kind)
        #endif
    }
}

#if os(iOS)
private struct WatchPartyButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: WatchPartyButtonKind
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: maxWidth, minHeight: height)
            .padding(.horizontal, horizontalPadding)
            .background(shape.fill(background))
            .overlay(shape.stroke(border, lineWidth: 1))
            .scaleEffect(isFocused ? 1.05 : (configuration.isPressed ? 0.98 : 1))
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: configuration.isPressed)
    }

    private var fontSize: CGFloat { 17 }
    private var height: CGFloat { 52 }
    private var horizontalPadding: CGFloat { 16 }
    private var maxWidth: CGFloat? { .infinity }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    private var foreground: Color {
        if isFocused { return .black }
        switch kind {
        case .primary: return .black
        case .secondary, .outlined: return .siloOnSurface
        }
    }

    private var background: Color {
        if isFocused { return .siloOnSurface }
        switch kind {
        case .primary: return .siloOnSurface
        case .secondary: return .siloChromeRestingFill
        case .outlined: return .clear
        }
    }

    private var border: Color {
        if isFocused { return .clear }
        switch kind {
        case .primary: return .clear
        case .secondary: return .siloChromeRestingBorder
        case .outlined: return .siloOnSurface
        }
    }
}
#endif

// MARK: - Banner

/// One banner for anything the member should know: host away, a failed
/// request, or an unsupported server.
struct WatchPartyBanner: View {
    enum Tone { case warning, neutral }
    let message: String
    var tone: Tone = .neutral

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(tone == .warning ? Color.requestAmber : Color.siloSecondaryText)
                .frame(width: WatchPartyMetrics.caption * 0.6, height: WatchPartyMetrics.caption * 0.6)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(message)
                .font(.system(size: WatchPartyMetrics.caption + 1))
                .foregroundStyle(tone == .warning ? Color(hex: "#F5C563") : Color.siloOnSurface)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, WatchPartyMetrics.caption)
        .padding(.vertical, WatchPartyMetrics.caption * 0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(tone == .warning ? Color.requestAmber.opacity(0.12) : Color.siloChromeRestingFill))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(tone == .warning ? Color.requestAmber.opacity(0.3) : Color.siloChromeRestingBorder, lineWidth: 1))
        .accessibilityIdentifier("watchParty.error")
    }
}

// MARK: - Picker helpers retained by the media picker

/// Color the label inside the native focused control without replacing its focus effect.
private struct WatchPartyButtonLabelModifier: ViewModifier {
    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    #endif

    func body(content: Content) -> some View {
        #if os(tvOS)
        if isFocused {
            content.foregroundStyle(Color.black)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    func watchPartyButtonLabel() -> some View {
        modifier(WatchPartyButtonLabelModifier())
    }
}

struct WatchPartyArtworkRow: View {
    let title: String
    var subtitle: String?
    var posterURL: String?

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            WatchPartyPoster(url: posterURL, width: posterWidth)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }

    private var posterWidth: CGFloat {
        #if os(tvOS)
        80
        #else
        56
        #endif
    }
}

struct WatchPartyPoster: View {
    let url: String?
    var thumbhash: String? = nil
    let width: CGFloat
    var cornerRadius: CGFloat = 8

    var body: some View {
        Group {
            if let url, !url.isEmpty {
                AsyncImageView(url: url, thumbhash: thumbhash, targetSize: CGSize(width: width * 2, height: width * 3), contentMode: .fill)
            } else {
                Rectangle().fill(Color.siloSurfaceElevated)
                    .overlay { Image(systemName: "film").foregroundStyle(Color.siloSecondaryText) }
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct WatchPartyErrorSection: View {
    let message: String?
    var body: some View {
        if let message {
            Section {
                Label(message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("watchParty.error")
            }
        }
    }
}
#endif

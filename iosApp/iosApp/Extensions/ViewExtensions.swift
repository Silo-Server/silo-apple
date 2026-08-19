import SwiftUI

// MARK: - Common View Modifiers

enum SiloNavigationTitleDisplayMode {
    case automatic
    case inline
    case large
}

extension View {
    /// Apply the standard Silo dark background.
    func siloBackground() -> some View {
        self.background(Color.siloBackground.ignoresSafeArea())
    }

    /// Hide the view conditionally.
    @ViewBuilder
    func hidden(_ isHidden: Bool) -> some View {
        if isHidden {
            self.hidden()
        } else {
            self
        }
    }

    @ViewBuilder
    func siloNavigationTitleDisplayMode(_ mode: SiloNavigationTitleDisplayMode) -> some View {
        #if os(tvOS) || os(macOS)
        self
        #else
        switch mode {
        case .automatic:
            self.navigationBarTitleDisplayMode(.automatic)
        case .inline:
            self.navigationBarTitleDisplayMode(.inline)
        case .large:
            self.navigationBarTitleDisplayMode(.large)
        }
        #endif
    }

    @ViewBuilder
    func siloScrollContentBackgroundHidden() -> some View {
        #if os(tvOS)
        self
        #else
        self.scrollContentBackground(.hidden)
        #endif
    }

    /// Soft native scroll-edge blur at the top, where content passes under a
    /// floating bar. iOS/macOS minimums are 26 so it's unconditional there;
    /// no-op on tvOS (no floating bars in the 10-foot UI).
    @ViewBuilder
    func siloScrollEdgeEffect() -> some View {
        #if os(tvOS)
        self
        #else
        self.scrollEdgeEffectStyle(.soft, for: .top)
        #endif
    }

    @ViewBuilder
    func siloStatusBarHidden() -> some View {
        #if os(tvOS) || os(macOS)
        self
        #else
        self.statusBarHidden()
        #endif
    }

    @ViewBuilder
    func siloToolbarColorSchemeDark() -> some View {
        #if os(tvOS) || os(macOS)
        self
        #else
        self.toolbarColorScheme(.dark, for: .navigationBar)
        #endif
    }

    @ViewBuilder
    func siloNavigationBarSurfaceBackground() -> some View {
        #if os(tvOS) || os(macOS)
        self
        #else
        self
            .toolbarBackground(Color.siloSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        #endif
    }

    @ViewBuilder
    func siloNavigationBarBackgroundHidden() -> some View {
        #if os(tvOS) || os(macOS)
        self
        #else
        self.toolbarBackground(.hidden, for: .navigationBar)
        #endif
    }

    @ViewBuilder
    func siloSearchable(text: Binding<String>, prompt: String) -> some View {
        #if os(tvOS)
        self.searchable(text: text, prompt: prompt)
        #elseif os(macOS)
        self.searchable(text: text, prompt: prompt)
        #else
        // Keep the navigation bar's back button and title visible while the
        // field is focused, and drop the search bar's Cancel button so the
        // field's own clear button is the only way to empty the query.
        self.searchable(
            text: text,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: prompt
        )
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .background(SearchCancelButtonSuppressor().frame(width: 0, height: 0))
        #endif
    }

    @ViewBuilder
    func siloGroupedListStyle() -> some View {
        #if os(tvOS)
        self.listStyle(.plain)
        #elseif os(macOS)
        self.listStyle(.inset)
        #else
        self.listStyle(.insetGrouped)
        #endif
    }

    #if !os(tvOS)
    /// Standard chrome for a settings-list `Picker`: on-surface label color,
    /// then a menu on macOS and a navigation-link row on iOS. tvOS drives its
    /// own `TVSettings*` screens and never calls this.
    func siloSettingsPicker() -> some View {
        self
            .foregroundStyle(Color.siloOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif
    }
    #endif

    func siloInputChrome(isFocused: Bool) -> some View {
        self
            .background(SiloInputBackground(isFocused: isFocused))
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .shadow(
                color: isFocused ? Color.siloOnSurface.opacity(0.22) : .clear,
                radius: isFocused ? 18 : 0,
                y: 0
            )
            // On tvOS the system paints a bright white platter under the
            // TextField when it gains focus, which completely hides our dark
            // fill + placeholder. Suppressing it lets SiloInputBackground
            // carry focus via the fill/stroke change instead.
            #if os(tvOS)
            .focusEffectDisabled()
            #endif
            .animation(SiloTheme.springAnimation, value: isFocused)
    }
}

private struct SiloInputBackground: View {
    let isFocused: Bool

    var body: some View {
        // At-rest stroke bumped to 22% so the field boundary reads clearly
        // against pure black auth canvases. `siloOutline` (12%) is
        // tuned for dividers and was too faint here.
        let strokeColor: Color = isFocused ? .siloOnSurface : Color.white.opacity(0.22)
        let strokeWidth: CGFloat = isFocused ? 3 : 1.5
        // Slightly elevated fill gives the field a visible silhouette on
        // pure-black backgrounds without washing it into the focus
        // platter when tvOS lights the field up.
        let fillColor: Color = .siloSurfaceElevated

        RoundedRectangle(cornerRadius: SiloTheme.cornerRadius)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: SiloTheme.cornerRadius)
                    .stroke(strokeColor, lineWidth: strokeWidth)
            )
    }
}

extension View {
    /// Shared centered playback prompt for touch devices.
    ///
    /// `confirmationDialog` can anchor away from the user's thumb on phones,
    /// while a standard alert keeps the decision in the middle of the screen.
    func siloResumePlaybackAlert(
        isPresented: Binding<Bool>,
        stoppedAt timestamp: String,
        onResume: @escaping () -> Void,
        onRestart: @escaping () -> Void
    ) -> some View {
        alert("Continue Watching?", isPresented: isPresented) {
            Button("Resume", action: onResume)
            Button("Play from Beginning", action: onRestart)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You stopped at \(timestamp).")
        }
    }
}

// MARK: - Silo Button Styles

// NOTE: These three styles are tvOS-only, and the guard below enforces it:
// every use site — the `silo*Button()` extensions, CalendarView,
// CreateProfileView — names them inside an `#if os(tvOS)` branch, while
// iOS/macOS route to native `.glass`/`.glassProminent`. They exist because
// tvOS focus appearance (scale, glow, focus stroke, `.focusEffectDisabled()`)
// depends on them. If tvOS later adopts glass too, they can be retired.
#if os(tvOS)

/// Primary action button — filled pill with dark text. At rest the pill is
/// a dimmed white so focus can brighten it to solid white; on tvOS focus
/// also adds a scale + glow so the button is distinguishable even when
/// surrounded by other white-ish surfaces (e.g. focused text fields).
struct SiloPrimaryButtonStyle: ButtonStyle {
    var isLoading: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, isLoading: isLoading)
    }
}

private struct PrimaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let isLoading: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView()
                    .tint(Color.siloBackground)
                    .scaleEffect(0.8)
            }
            configuration.label
        }
        .font(.siloSubheadline)
        .foregroundColor(Color.siloBackground)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 18)
        .background(
            Capsule().fill(
                isLoading ? Color.siloOnSurface.opacity(0.6)
                : isFocused ? Color.siloOnSurface
                : Color.siloOnSurface.opacity(0.72)
            )
        )
        .overlay(
            Capsule().stroke(
                isFocused ? Color.white : Color.clear,
                lineWidth: isFocused ? 4 : 0
            )
        )
        .overlay {
            if isFocused {
                Capsule()
                    .stroke(Color.white.opacity(0.36), lineWidth: 7)
                    .padding(-6)
                    .blur(radius: 6)
            }
        }
        .scaleEffect(isFocused && !reduceMotion ? 1.055 : 1.0)
        .shadow(
            color: isFocused ? Color.siloOnSurface.opacity(0.48) : .clear,
            radius: isFocused ? 24 : 0,
            y: isFocused ? 8 : 0
        )
        .opacity(configuration.isPressed ? 0.8 : 1.0)
        .focusEffectDisabled()
        .animation(.easeInOut(duration: SiloTheme.fastDuration), value: configuration.isPressed)
        .animation(SiloTheme.springAnimation, value: isFocused)
    }
}

/// Secondary action button — outlined pill.
struct SiloSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration)
    }
}

private struct SecondaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .font(.siloSubheadline)
            .foregroundColor(isFocused ? .siloBackground : .siloOnSurface)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
            .background(
                Capsule()
                    .fill(isFocused ? Color.siloOnSurface.opacity(0.96) : Color.clear)
            )
            .overlay(
                Capsule().stroke(
                    isFocused ? Color.white : Color.white.opacity(0.3),
                    lineWidth: isFocused ? 3 : 1.5
                )
            )
            .scaleEffect(isFocused && !reduceMotion ? 1.045 : 1.0)
            .shadow(
                color: isFocused ? Color.siloOnSurface.opacity(0.36) : .clear,
                radius: isFocused ? 18 : 0,
                y: isFocused ? 6 : 0
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .focusEffectDisabled()
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: configuration.isPressed)
            .animation(SiloTheme.springAnimation, value: isFocused)
    }
}

/// Text-only button style for tertiary actions. Focused state fills a
/// soft pill behind the label so the user can distinguish the tertiary action
/// from the primary button above.
struct SiloTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TextButtonBody(configuration: configuration)
    }
}

private struct TextButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .font(.siloBody)
            .foregroundColor(isFocused ? .siloBackground : .siloOnSurface)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(
                    isFocused ? Color.siloOnSurface : Color.clear
                )
            )
            .overlay {
                Capsule().stroke(
                    isFocused ? Color.white.opacity(0.9) : Color.clear,
                    lineWidth: isFocused ? 2 : 0
                )
            }
            .scaleEffect(isFocused ? 1.045 : 1.0)
            .shadow(
                color: isFocused ? Color.siloOnSurface.opacity(0.28) : .clear,
                radius: isFocused ? 14 : 0,
                y: isFocused ? 4 : 0
            )
            .opacity(configuration.isPressed ? 0.6 : 1.0)
            .focusEffectDisabled()
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: configuration.isPressed)
            .animation(SiloTheme.springAnimation, value: isFocused)
    }
}

#endif

// MARK: - Silo button style routing (glass on iOS/macOS, Silo styles on tvOS)

extension View {
    /// Primary action button: native Liquid Glass on iOS/macOS, focus-reactive
    /// `SiloPrimaryButtonStyle` on tvOS (its scale/glow/focus stroke encodes
    /// 10-foot focus, which glass does not provide). All Apple targets are 26+,
    /// so `.glassProminent` is unconditional on the non-tvOS path.
    @ViewBuilder
    func siloPrimaryButton(isLoading: Bool = false) -> some View {
        #if os(tvOS)
        self.buttonStyle(SiloPrimaryButtonStyle(isLoading: isLoading))
        #else
        // `.glassProminent` can't take the in-flight state, so surface it the
        // only way a modifier can: disable the button and overlay a spinner
        // while loading. Without this the iOS save buttons gave no feedback
        // during a request (regression vs SiloPrimaryButtonStyle).
        self
            .buttonStyle(.glassProminent)
            // The global monochrome tint made prominent glass white-on-white;
            // accent the fill so the label stays legible.
            .tint(.siloAccent)
            .disabled(isLoading)
            .overlay {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        #endif
    }

    /// Secondary action button: native glass on iOS/macOS, `SiloSecondaryButtonStyle`
    /// on tvOS.
    @ViewBuilder
    func siloSecondaryButton() -> some View {
        #if os(tvOS)
        self.buttonStyle(SiloSecondaryButtonStyle())
        #else
        self.buttonStyle(.glass)
        #endif
    }

    /// Tertiary / text action button: native glass on iOS/macOS, `SiloTextButtonStyle`
    /// on tvOS.
    @ViewBuilder
    func siloTextButton() -> some View {
        #if os(tvOS)
        self.buttonStyle(SiloTextButtonStyle())
        #else
        self.buttonStyle(.glass)
        #endif
    }
}

// MARK: - Silo Text Field Style

/// Dark-themed text field with rounded surface background.
struct SiloTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        SiloTextFieldBody(configuration: configuration)
    }
}

private struct SiloTextFieldBody<Label: View>: View {
    let configuration: TextField<Label>
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration
            .font(.siloBody)
            // tvOS renders an unavoidable bright-white focus platter under
            // any focused TextField (`.focusEffectDisabled()` doesn't
            // suppress it for text fields the way it does for Buttons).
            // Rather than fight the platform, flip the text color to dark
            // on focus so the typed value reads black-on-white instead of
            // white-on-white.
            .foregroundColor(textColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .siloInputChrome(isFocused: isFocused)
            .tint(isFocused ? .siloBackground : .siloOnSurface)
    }

    private var textColor: Color {
        #if os(tvOS)
        isFocused ? .siloBackground : .siloOnSurface
        #else
        .siloOnSurface
        #endif
    }
}

#if os(tvOS)
extension View {
    /// Applies `prefersDefaultFocus` only when a focus namespace is supplied,
    /// so a single element (the first profile tile, the PIN pad's "1", a
    /// rail's first card, the hero Play pill) can claim a scope's initial
    /// focus while callers that don't manage focus pass `nil` and are
    /// untouched. Shared by every tvOS component that takes an optional
    /// `defaultFocusNamespace`.
    @ViewBuilder
    func applyDefaultFocusIfNeeded(_ prefersDefaultFocus: Bool, namespace: Namespace.ID?) -> some View {
        if let namespace {
            self.prefersDefaultFocus(prefersDefaultFocus, in: namespace)
        } else {
            self
        }
    }

    /// Routes a scope's d-pad-entry focus onto a specific id. `.userInitiated`
    /// priority is what makes `defaultFocus` win over tvOS' geometric
    /// proximity logic on entry. No-op while the target id is nil (empty or
    /// still-loading rail) or the caller has disabled the claim.
    @ViewBuilder
    func applyDefaultFocusIfPresent<ID: Hashable>(
        _ binding: FocusState<ID?>.Binding,
        id: ID?,
        enabled: Bool = true,
        priority: DefaultFocusEvaluationPriority = .userInitiated
    ) -> some View {
        if enabled, let id {
            self.defaultFocus(binding, id, priority: priority)
        } else {
            self
        }
    }

    /// Binds this view to a parent row/rail's `@FocusState` so the parent's
    /// `defaultFocus` can land on it. No-op when either argument is nil —
    /// i.e. the parent doesn't manage focus.
    @ViewBuilder
    func applyFocusBindingIfPresent<ID: Hashable>(
        _ binding: FocusState<ID?>.Binding?,
        id: ID?
    ) -> some View {
        if let binding, let id {
            self.focused(binding, equals: id)
        } else {
            self
        }
    }

    /// Siri Remote play/pause on a card, when the caller supplies an action.
    @ViewBuilder
    func applyPlayPauseAction(_ action: (() -> Void)?) -> some View {
        if let action {
            self.onPlayPauseCommand(perform: action)
        } else {
            self
        }
    }
}
#endif

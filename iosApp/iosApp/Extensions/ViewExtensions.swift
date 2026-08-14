import SwiftUI

// MARK: - Common View Modifiers

enum ContinuumNavigationTitleDisplayMode {
    case automatic
    case inline
    case large
}

extension View {
    /// Apply the standard Continuum dark background.
    func continuumBackground() -> some View {
        self.background(Color.continuumBackground.ignoresSafeArea())
    }

    /// Card-style surface with rounded corners — zero elevation (Plezy style).
    func continuumCard() -> some View {
        self
            .background(Color.continuumSurface)
            .clipShape(RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius))
    }

    /// Standard content padding on all sides.
    func continuumPadding() -> some View {
        self.padding(ContinuumTheme.padding)
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
    func continuumNavigationTitleDisplayMode(_ mode: ContinuumNavigationTitleDisplayMode) -> some View {
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
    func continuumScrollContentBackgroundHidden() -> some View {
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
    func continuumScrollEdgeEffect() -> some View {
        #if os(tvOS)
        self
        #else
        self.scrollEdgeEffectStyle(.soft, for: .top)
        #endif
    }

    @ViewBuilder
    func continuumStatusBarHidden() -> some View {
        #if os(tvOS) || os(macOS)
        self
        #else
        self.statusBarHidden()
        #endif
    }

    @ViewBuilder
    func continuumToolbarColorSchemeDark() -> some View {
        #if os(tvOS) || os(macOS)
        self
        #else
        self.toolbarColorScheme(.dark, for: .navigationBar)
        #endif
    }

    @ViewBuilder
    func continuumNavigationBarSurfaceBackground() -> some View {
        #if os(tvOS) || os(macOS)
        self
        #else
        self
            .toolbarBackground(Color.continuumSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        #endif
    }

    @ViewBuilder
    func continuumNavigationBarBackgroundHidden() -> some View {
        #if os(tvOS) || os(macOS)
        self
        #else
        self.toolbarBackground(.hidden, for: .navigationBar)
        #endif
    }

    @ViewBuilder
    func continuumSearchable(text: Binding<String>, prompt: String) -> some View {
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
    func continuumGroupedListStyle() -> some View {
        #if os(tvOS)
        self.listStyle(.plain)
        #elseif os(macOS)
        self.listStyle(.inset)
        #else
        self.listStyle(.insetGrouped)
        #endif
    }

    func continuumInputChrome(isFocused: Bool) -> some View {
        self
            .background(ContinuumInputBackground(isFocused: isFocused))
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .shadow(
                color: isFocused ? Color.continuumOnSurface.opacity(0.22) : .clear,
                radius: isFocused ? 18 : 0,
                y: 0
            )
            // On tvOS the system paints a bright white platter under the
            // TextField when it gains focus, which completely hides our dark
            // fill + placeholder. Suppressing it lets ContinuumInputBackground
            // carry focus via the fill/stroke change instead.
            #if os(tvOS)
            .focusEffectDisabled()
            #endif
            .animation(ContinuumTheme.springAnimation, value: isFocused)
    }
}

private struct ContinuumInputBackground: View {
    let isFocused: Bool

    var body: some View {
        // At-rest stroke bumped to 22% so the field boundary reads clearly
        // against pure black auth canvases. `continuumOutline` (12%) is
        // tuned for dividers and was too faint here.
        let strokeColor: Color = isFocused ? .continuumOnSurface : Color.white.opacity(0.22)
        let strokeWidth: CGFloat = isFocused ? 3 : 1.5
        // Slightly elevated fill gives the field a visible silhouette on
        // pure-black backgrounds without washing it into the focus
        // platter when tvOS lights the field up.
        let fillColor: Color = .continuumSurfaceElevated

        RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius)
                    .stroke(strokeColor, lineWidth: strokeWidth)
            )
    }
}

extension View {
    /// Shared centered playback prompt for touch devices.
    ///
    /// `confirmationDialog` can anchor away from the user's thumb on phones,
    /// while a standard alert keeps the decision in the middle of the screen.
    func continuumResumePlaybackAlert(
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

// MARK: - Continuum Button Styles

// NOTE: On the migrated paths these styles now serve tvOS only — iOS/macOS
// route to native `.glass`/`.glassProminent` via the `silo*Button()` view
// extensions below. They stay defined because tvOS focus appearance (scale,
// glow, focus stroke, `.focusEffectDisabled()`) depends on them. If tvOS later
// adopts glass too, they can be retired.

/// Primary action button — filled pill with dark text. At rest the pill is
/// a dimmed white so focus can brighten it to solid white; on tvOS focus
/// also adds a scale + glow so the button is distinguishable even when
/// surrounded by other white-ish surfaces (e.g. focused text fields).
struct ContinuumPrimaryButtonStyle: ButtonStyle {
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
                    .tint(Color.continuumBackground)
                    .scaleEffect(0.8)
            }
            configuration.label
        }
        .font(.continuumSubheadline)
        .foregroundColor(Color.continuumBackground)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 18)
        .background(
            Capsule().fill(
                isLoading ? Color.continuumOnSurface.opacity(0.6)
                : isFocused ? Color.continuumOnSurface
                : Color.continuumOnSurface.opacity(0.72)
            )
        )
        .overlay(
            Capsule().stroke(
                isFocused ? Color.white : Color.clear,
                lineWidth: isFocused ? 4 : 0
            )
        )
        .overlay {
            #if os(tvOS)
            if isFocused {
                Capsule()
                    .stroke(Color.white.opacity(0.36), lineWidth: 7)
                    .padding(-6)
                    .blur(radius: 6)
            }
            #endif
        }
        .scaleEffect(isFocused && !reduceMotion ? 1.055 : 1.0)
        .shadow(
            color: isFocused ? Color.continuumOnSurface.opacity(0.48) : .clear,
            radius: isFocused ? 24 : 0,
            y: isFocused ? 8 : 0
        )
        .opacity(configuration.isPressed ? 0.8 : 1.0)
        #if os(tvOS)
        .focusEffectDisabled()
        #endif
        .animation(.easeInOut(duration: ContinuumTheme.fastDuration), value: configuration.isPressed)
        .animation(ContinuumTheme.springAnimation, value: isFocused)
    }
}

/// Secondary action button — outlined pill.
struct ContinuumSecondaryButtonStyle: ButtonStyle {
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
            .font(.continuumSubheadline)
            .foregroundColor(isFocused ? .continuumBackground : .continuumOnSurface)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
            .background(
                Capsule()
                    .fill(isFocused ? Color.continuumOnSurface.opacity(0.96) : Color.clear)
            )
            .overlay(
                Capsule().stroke(
                    isFocused ? Color.white : Color.white.opacity(0.3),
                    lineWidth: isFocused ? 3 : 1.5
                )
            )
            .scaleEffect(isFocused && !reduceMotion ? 1.045 : 1.0)
            .shadow(
                color: isFocused ? Color.continuumOnSurface.opacity(0.36) : .clear,
                radius: isFocused ? 18 : 0,
                y: isFocused ? 6 : 0
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            #if os(tvOS)
            .focusEffectDisabled()
            #endif
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: configuration.isPressed)
            .animation(ContinuumTheme.springAnimation, value: isFocused)
    }
}

/// Text-only button style for tertiary actions. Focused state fills a
/// soft pill behind the label so the user can distinguish the tertiary action
/// from the primary button above.
struct ContinuumTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TextButtonBody(configuration: configuration)
    }
}

private struct TextButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .font(.continuumBody)
            .foregroundColor(isFocused ? .continuumBackground : .continuumOnSurface)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(
                    isFocused ? Color.continuumOnSurface : Color.clear
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
                color: isFocused ? Color.continuumOnSurface.opacity(0.28) : .clear,
                radius: isFocused ? 14 : 0,
                y: isFocused ? 4 : 0
            )
            .opacity(configuration.isPressed ? 0.6 : 1.0)
            #if os(tvOS)
            .focusEffectDisabled()
            #endif
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: configuration.isPressed)
            .animation(ContinuumTheme.springAnimation, value: isFocused)
    }
}

// MARK: - Silo button style routing (glass on iOS/macOS, Continuum on tvOS)

extension View {
    /// Primary action button: native Liquid Glass on iOS/macOS, focus-reactive
    /// `ContinuumPrimaryButtonStyle` on tvOS (its scale/glow/focus stroke encodes
    /// 10-foot focus, which glass does not provide). All Apple targets are 26+,
    /// so `.glassProminent` is unconditional on the non-tvOS path.
    @ViewBuilder
    func siloPrimaryButton(isLoading: Bool = false) -> some View {
        #if os(tvOS)
        self.buttonStyle(ContinuumPrimaryButtonStyle(isLoading: isLoading))
        #else
        // `.glassProminent` can't take the in-flight state, so surface it the
        // only way a modifier can: disable the button and overlay a spinner
        // while loading. Without this the iOS save buttons gave no feedback
        // during a request (regression vs ContinuumPrimaryButtonStyle).
        self
            .buttonStyle(.glassProminent)
            // The global monochrome tint made prominent glass white-on-white;
            // accent the fill so the label stays legible.
            .tint(.continuumAccent)
            .disabled(isLoading)
            .overlay {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        #endif
    }

    /// Secondary action button: native glass on iOS/macOS, `ContinuumSecondaryButtonStyle`
    /// on tvOS.
    @ViewBuilder
    func siloSecondaryButton() -> some View {
        #if os(tvOS)
        self.buttonStyle(ContinuumSecondaryButtonStyle())
        #else
        self.buttonStyle(.glass)
        #endif
    }

    /// Tertiary / text action button: native glass on iOS/macOS, `ContinuumTextButtonStyle`
    /// on tvOS.
    @ViewBuilder
    func siloTextButton() -> some View {
        #if os(tvOS)
        self.buttonStyle(ContinuumTextButtonStyle())
        #else
        self.buttonStyle(.glass)
        #endif
    }
}

// MARK: - Continuum Text Field Style

/// Dark-themed text field with rounded surface background.
struct ContinuumTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        ContinuumTextFieldBody(configuration: configuration)
    }
}

private struct ContinuumTextFieldBody<Label: View>: View {
    let configuration: TextField<Label>
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration
            .font(.continuumBody)
            // tvOS renders an unavoidable bright-white focus platter under
            // any focused TextField (`.focusEffectDisabled()` doesn't
            // suppress it for text fields the way it does for Buttons).
            // Rather than fight the platform, flip the text color to dark
            // on focus so the typed value reads black-on-white instead of
            // white-on-white.
            .foregroundColor(textColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .continuumInputChrome(isFocused: isFocused)
            .tint(isFocused ? .continuumBackground : .continuumOnSurface)
    }

    private var textColor: Color {
        #if os(tvOS)
        isFocused ? .continuumBackground : .continuumOnSurface
        #else
        .continuumOnSurface
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
}
#endif

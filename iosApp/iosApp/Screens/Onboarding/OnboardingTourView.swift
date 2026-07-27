import SwiftUI

#if !os(tvOS)
/// Server-driven first-run feature tour. The manifest comes from
/// /onboarding/flow (already filtered per server and profile); this view
/// renders the step kinds it knows and skips the rest — that skip is the
/// forward-compatibility contract. Progress and completion post per profile,
/// so finishing here silences the web and Android too.
struct OnboardingTourView: View {
    var router: AppRouter
    /// Set when presented as a cover (the tour gate); falls back to a router
    /// reset when pushed as a route.
    var onDismiss: (() -> Void)? = nil
    @State private var viewModel = OnboardingTourViewModel()

    var body: some View {
        AuroraScreen(variant: .signIn, scrim: .soft) {
            if viewModel.isLoading || viewModel.steps.isEmpty {
                ProgressView()
                    .tint(Color.auroraInk)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tourBody
            }
        }
        .navigationBarBackButtonHidden()
        .task { await viewModel.load() }
        .onChange(of: viewModel.finished) { _, finished in
            guard finished else { return }
            if let onDismiss {
                onDismiss()
            } else {
                router.resetToHome()
            }
        }
    }

    @ViewBuilder
    private var tourBody: some View {
        let step = viewModel.steps[viewModel.currentIndex]
        let isLast = viewModel.currentIndex == viewModel.steps.count - 1

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    ForEach(Array(viewModel.steps.enumerated()), id: \.offset) { index, _ in
                        Capsule()
                            .fill(index == viewModel.currentIndex
                                ? Color.auroraInk
                                : Color.auroraInk.opacity(0.25))
                            .frame(width: index == viewModel.currentIndex ? 18 : 6, height: 6)
                    }
                }
                Spacer()
                Button("Skip") { viewModel.skip() }
                    .buttonStyle(AuroraGhostButtonStyle())
            }

            Spacer()

            Image(systemName: illustrationSymbol(step.illustration))
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.auroraInk)
                .frame(width: 56, height: 56)
                .background(Color.auroraInk.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                .padding(.bottom, 20)

            if let title = step.title {
                Text(title)
                    .font(.continuumTitle)
                    .foregroundStyle(Color.auroraInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let body = step.body {
                Text(body)
                    .font(.continuumBody)
                    .foregroundStyle(Color.auroraInkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            if step.kind == "setting_choice", let spec = step.setting {
                settingChoice(step: step, spec: spec)
                    .padding(.top, 22)
            }

            Spacer()

            HStack(spacing: 10) {
                if viewModel.currentIndex > 0 {
                    Button("Back") { viewModel.back() }
                        .buttonStyle(AuroraGhostButtonStyle())
                }
                Button {
                    if step.kind == "handoff" || isLast {
                        viewModel.finish()
                    } else {
                        viewModel.advance()
                    }
                } label: {
                    Text(step.kind == "handoff" || isLast
                        ? "Done"
                        : viewModel.currentIndex == 0 ? "Show me" : "Next")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AuroraPrimaryButtonStyle())
            }
        }
    }

    private func settingChoice(step: OnboardingStep, spec: OnboardingSettingSpec) -> some View {
        VStack(spacing: 4) {
            ForEach(spec.options ?? [], id: \.value) { option in
                let isSelected = viewModel.selectedValues[step.id] == option.value
                    || (viewModel.selectedValues[step.id] == nil && option.value == spec.default)
                Button {
                    viewModel.choose(step: step, value: option.value)
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .strokeBorder(
                                isSelected ? Color.auroraInk : Color.auroraInk.opacity(0.4),
                                lineWidth: 1.5
                            )
                            .background(Circle().fill(isSelected ? Color.auroraInk : .clear).padding(3))
                            .frame(width: 16, height: 16)
                        Text(option.label)
                            .font(.continuumBody.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(Color.auroraInk)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        isSelected ? Color.auroraInk.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .auroraGlass(cornerRadius: 20)
    }

    /// Client-side illustration keys — the server only ever names them.
    private func illustrationSymbol(_ key: String?) -> String {
        switch key {
        case "watchlist": return "heart.fill"
        case "watch-together": return "person.2.fill"
        case "calendar": return "calendar"
        case "playback": return "play.circle.fill"
        case "subtitles": return "captions.bubble.fill"
        case "requests": return "wand.and.stars"
        default: return "sparkles"
        }
    }
}
#endif

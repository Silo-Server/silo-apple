import SwiftUI

#if os(macOS)
/// The Mac's layout of the first-run tour: a fixed landscape sheet with a
/// stage on the left and the step on the right. The stage draws Silo's
/// signal line from the sign-in backdrop, with one point per step, so the
/// line fills in as the tour moves along. Controls are the Mac's own.
struct OnboardingTourMacLayout: View {
    var viewModel: OnboardingTourViewModel
    /// Opens a feature card's route, ending the tour.
    var openRoute: (String) -> Void

    private static let sheetSize = CGSize(width: 760, height: 440)
    private static let stageWidth: CGFloat = 272
    /// One measure for every step: about 60 characters of body text. A
    /// fixed width also keeps the radio group from narrowing the column.
    private static let columnWidth: CGFloat = 400

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            OnboardingTourMacStage(
                symbol: viewModel.steps.isEmpty
                    ? nil
                    : Self.symbol(for: viewModel.steps[viewModel.currentIndex]),
                stepCount: viewModel.steps.count,
                currentIndex: viewModel.currentIndex
            )
            .frame(width: Self.stageWidth)

            Group {
                if viewModel.isLoading || viewModel.steps.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    stepPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.siloPageCanvas)
        }
        .frame(width: Self.sheetSize.width, height: Self.sheetSize.height)
        .preferredColorScheme(.dark)
    }

    /// The stage's symbol. Setting steps carry no illustration key, so the
    /// Mac picks one from the setting; everything else uses the shared keys.
    static func symbol(for step: OnboardingStep) -> String {
        if step.illustration == nil {
            switch step.setting?.key {
            case "quality_preference": return "4k.tv"
            case "subtitle_mode", "subtitle_language": return "captions.bubble"
            case "auto_skip_intro", "auto_skip_credits": return "forward.end"
            default: break
            }
            if step.kind == "handoff" { return "heart.circle" }
        }
        if step.illustration == "recommendations" { return "sparkles.tv" }
        return OnboardingTourView.illustrationSymbol(step.illustration)
    }

    // MARK: Step pane

    private var stepPane: some View {
        let step = viewModel.steps[viewModel.currentIndex]
        let isLast = viewModel.currentIndex == viewModel.steps.count - 1
        let finishes = step.kind == "handoff" || isLast

        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                stepContent(step)
                    .frame(width: Self.columnWidth, alignment: .leading)
                    .id(step.id)
                    .transition(.opacity)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
                    .padding(.bottom, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: viewModel.currentIndex)

            footer(finishes: finishes)
        }
    }

    private func stepContent(_ step: OnboardingStep) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = step.title {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(Color.auroraInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            if let body = step.body {
                Text(body)
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .foregroundStyle(Color.auroraInk.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }

            if step.kind == "setting_choice", let spec = step.setting {
                settingControl(step: step, spec: spec)
                    .padding(.top, 28)
            }

            if step.kind == "feature_card",
               let label = step.actionLabel,
               let route = step.route,
               OnboardingTourView.supportedRoutes.contains(route) {
                Button(label) { openRoute(route) }
                    .buttonStyle(MacTourButtonStyle(role: .secondary))
                    .disabled(viewModel.isSaving)
                    .padding(.top, 24)
            }

            if let error = viewModel.error {
                VStack(alignment: .leading, spacing: 10) {
                    // The shared label's caption style is 10pt on the Mac.
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.requestRose)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Continue without saving") {
                        Task { await viewModel.continueWithoutSaving() }
                    }
                    .buttonStyle(MacTourButtonStyle(role: .secondary))
                    .disabled(viewModel.isSaving)
                }
                .padding(.top, 24)
            }
        }
    }

    @ViewBuilder
    private func settingControl(step: OnboardingStep, spec: OnboardingSettingSpec) -> some View {
        if spec.control == "toggle" {
            Toggle(spec.label ?? step.title ?? "Enabled", isOn: Binding(
                get: { viewModel.isToggleEnabled(for: step) },
                set: { enabled in
                    Task { await viewModel.choose(step: step, value: enabled ? "true" : "false") }
                }
            ))
            .toggleStyle(.switch)
            .tint(.siloSwitchOn)
            .font(.system(size: 14))
            .disabled(viewModel.isSaving)
        } else {
            let options = spec.options ?? []
            let selection = Binding(
                get: { viewModel.selectedValues[step.id] ?? spec.default ?? "" },
                set: { value in Task { await viewModel.choose(step: step, value: value) } }
            )
            let picker = Picker(spec.label ?? step.title ?? "", selection: selection) {
                ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
            }
            .labelsHidden()
            .disabled(viewModel.isSaving)

            if spec.control == "segmented", options.count <= 4 {
                picker
                    .pickerStyle(.segmented)
                    .controlSize(.large)
                    .fixedSize()
            } else {
                picker
                    .pickerStyle(.radioGroup)
                    .font(.system(size: 14))
            }
        }
    }

    // MARK: Footer

    private func footer(finishes: Bool) -> some View {
        HStack(spacing: 10) {
            Button("Skip tour") { Task { await viewModel.skip() } }
                .buttonStyle(MacTourButtonStyle(role: .quiet))
                .keyboardShortcut(.cancelAction)
                .disabled(viewModel.isSaving)

            Spacer()

            if viewModel.currentIndex > 0 {
                Button("Back") { viewModel.back() }
                    .buttonStyle(MacTourButtonStyle(role: .secondary))
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(viewModel.isSaving)
            }

            Button {
                Task {
                    if finishes {
                        await viewModel.finish()
                    } else {
                        await viewModel.advance()
                    }
                }
            } label: {
                Text(primaryLabel(finishes: finishes))
                    .frame(minWidth: 64)
            }
            .buttonStyle(MacTourButtonStyle(role: .primary, isBusy: viewModel.isSaving))
            .keyboardShortcut(.defaultAction)
            .disabled(viewModel.isSaving)
        }
        // The quiet button's own 4pt inset lines "Skip tour" up with the
        // text column; the primary button ends near the column's edge.
        .padding(.horizontal, 40)
        .padding(.vertical, 22)
    }

    private func primaryLabel(finishes: Bool) -> String {
        if viewModel.isSaving { return "Saving…" }
        if finishes { return "Done" }
        return viewModel.currentIndex == 0 ? "Show me" : "Next"
    }
}

// MARK: - Stage

/// The left panel: the step's symbol above the signal line, with one point
/// per step. The line is lit up to the current step.
private struct OnboardingTourMacStage: View {
    let symbol: String?
    let stepCount: Int
    let currentIndex: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let curve = SignalCurve(size: geo.size)
            ZStack(alignment: .topLeading) {
                Color.siloBackground

                RadialGradient(
                    colors: [Color.auroraAccent.opacity(0.10), .clear],
                    center: UnitPoint(x: 0.5, y: 0.6),
                    startRadius: 0,
                    endRadius: geo.size.height * 0.6
                )

                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 54, weight: .light))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.auroraInk)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: geo.size.width, height: geo.size.height * 0.5)
                        .padding(.top, geo.size.height * 0.06)
                        .accessibilityHidden(true)
                }

                if stepCount > 0 {
                    curve.path
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)

                    curve.path
                        .trim(from: 0, to: curve.progress(at: currentIndex, of: stepCount))
                        .stroke(
                            LinearGradient(
                                colors: [Color.auroraAccent.opacity(0.15), Color.auroraAccent],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                        )

                    ForEach(0..<stepCount, id: \.self) { index in
                        dot(index: index)
                            .position(curve.point(atLength: curve.progress(at: index, of: stepCount)))
                    }

                    Text("\(currentIndex + 1) of \(stepCount)")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.auroraInk.opacity(0.5))
                        .contentTransition(.numericText())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        // Sits on the footer buttons' center line.
                        .padding(.horizontal, 24)
                        .padding(.bottom, 30)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: currentIndex)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stepCount > 0 ? "Step \(currentIndex + 1) of \(stepCount)" : "")
    }

    @ViewBuilder
    private func dot(index: Int) -> some View {
        if index == currentIndex {
            ZStack {
                Circle()
                    .fill(Color.auroraAccent.opacity(0.35))
                    .frame(width: 20, height: 20)
                    .blur(radius: 6)
                Circle()
                    .fill(Color.auroraAccent)
                    .frame(width: 8, height: 8)
            }
        } else {
            Circle()
                .fill(index < currentIndex ? Color.auroraInk.opacity(0.55) : Color.white.opacity(0.18))
                .frame(width: 5, height: 5)
        }
    }
}

/// The sign-in backdrop's signal curve, fitted to the stage.
private struct SignalCurve {
    let size: CGSize

    private var p0: CGPoint { CGPoint(x: -size.width * 0.06, y: size.height * 0.66) }
    private var c1: CGPoint { CGPoint(x: size.width * 0.30, y: size.height * 0.50) }
    private var c2: CGPoint { CGPoint(x: size.width * 0.66, y: size.height * 0.80) }
    private var p3: CGPoint { CGPoint(x: size.width * 1.06, y: size.height * 0.60) }

    var path: Path {
        var path = Path()
        path.move(to: p0)
        path.addCurve(to: p3, control1: c1, control2: c2)
        return path
    }

    /// The share of the curve's length where step `index` sits: evenly
    /// spaced between 14% and 86%, inside the stage's edges. `trim` measures
    /// length too, so the lit line ends on the current point.
    func progress(at index: Int, of count: Int) -> CGFloat {
        guard count > 1 else { return 0.5 }
        return 0.14 + 0.72 * CGFloat(index) / CGFloat(count - 1)
    }

    /// The point at `fraction` of the curve's length.
    func point(atLength fraction: CGFloat) -> CGPoint {
        let samples = 120
        var points = [p0]
        var lengths: [CGFloat] = [0]
        for i in 1...samples {
            let p = point(at: CGFloat(i) / CGFloat(samples))
            lengths.append(lengths[i - 1] + hypot(p.x - points[i - 1].x, p.y - points[i - 1].y))
            points.append(p)
        }
        let target = fraction * lengths[samples]
        guard let upper = lengths.firstIndex(where: { $0 >= target }), upper > 0 else { return p0 }
        let span = lengths[upper] - lengths[upper - 1]
        let mix = span > 0 ? (target - lengths[upper - 1]) / span : 0
        let a = points[upper - 1], b = points[upper]
        return CGPoint(x: a.x + (b.x - a.x) * mix, y: a.y + (b.y - a.y) * mix)
    }

    private func point(at t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(
            x: a * p0.x + b * c1.x + c * c2.x + d * p3.x,
            y: a * p0.y + b * c1.y + c * c2.y + d * p3.y
        )
    }
}

// MARK: - Buttons

/// Capsule buttons sized for a Mac sheet, in the app's monochrome palette.
private struct MacTourButtonStyle: ButtonStyle {
    enum Role { case primary, secondary, quiet }
    var role: Role
    /// Keeps the button at full strength while its own save runs.
    var isBusy: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        MacTourButtonBody(configuration: configuration, role: role, isBusy: isBusy)
    }
}

private struct MacTourButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let role: MacTourButtonStyle.Role
    let isBusy: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: role == .primary ? .semibold : .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, role == .quiet ? 4 : 16)
            .frame(height: 30)
            .background {
                switch role {
                case .primary:
                    Capsule().fill(Color.auroraInk.opacity(isHovered ? 1 : 0.92))
                case .secondary:
                    Capsule()
                        .fill(Color.white.opacity(isHovered ? 0.14 : 0.08))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                case .quiet:
                    EmptyView()
                }
            }
            .contentShape(Capsule())
            .opacity(!isEnabled && !isBusy ? 0.45 : configuration.isPressed ? 0.75 : 1)
            .onHover { isHovered = $0 }
    }

    private var foreground: Color {
        switch role {
        case .primary: Color.siloBackground
        case .secondary: Color.auroraInk
        case .quiet: Color.auroraInk.opacity(isHovered ? 0.9 : 0.55)
        }
    }
}
#endif

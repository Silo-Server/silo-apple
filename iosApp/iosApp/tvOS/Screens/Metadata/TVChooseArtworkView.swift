#if os(tvOS)
import SwiftUI

/// Native 10-foot artwork picker for Apple TV backed by `ChooseArtworkViewModel`.
/// Uses a single native focus graph (`@FocusState` + `.focusScope`), custom
/// monochrome focus chrome with `.focusEffectDisabled()`, and explicit apply
/// confirmation so accidental clicks never overwrite artwork.
struct TVChooseArtworkView: View {
    private enum FocusTarget: Hashable {
        case slot(MetadataImageSlot)
        case textless
        case close
        case retry
        case image(String)
    }

    let target: MetadataCurationTarget
    let onArtworkApplied: () -> Void

    @State private var viewModel: ChooseArtworkViewModel
    @State private var pendingApplyImage: AdminItemImage?

    @FocusState private var focused: FocusTarget?
    @Namespace private var screenScope
    @Environment(\.dismiss) private var dismiss

    init(target: MetadataCurationTarget, onArtworkApplied: @escaping () -> Void) {
        self.target = target
        self.onArtworkApplied = onArtworkApplied
        _viewModel = State(initialValue: ChooseArtworkViewModel(target: target))
    }

    private var focusedImage: AdminItemImage? {
        guard case .image(let id) = focused else { return nil }
        return viewModel.filteredImages.first { $0.id == id }
    }

    var body: some View {
        ZStack {
            Color.siloBackground.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                headerBar
                    .padding(.horizontal, 80)
                    .padding(.top, 54)
                    .padding(.bottom, 20)
                    .background(Color.siloBackground)
                    .zIndex(2)

                contentArea
                    .padding(.horizontal, 62)
                    .zIndex(1)

                footerBar
                    .padding(.horizontal, 80)
                    .padding(.top, 18)
                    .padding(.bottom, 44)
                    .background(
                        Color.siloBackground
                            .overlay(alignment: .top) {
                                Rectangle()
                                    .fill(Color.white.opacity(0.08))
                                    .frame(height: 1)
                            }
                    )
                    .zIndex(2)
            }
        }
        .focusScope(screenScope)
        .defaultFocus($focused, .slot(viewModel.activeSlot), priority: .userInitiated)
        .onExitCommand { dismiss() }
        .task {
            await viewModel.loadImages()
            if let first = viewModel.filteredImages.first {
                await Task.yield()
                focused = .image(first.id)
            }
        }
        .alert(
            MetadataStrings.applySlotButton(viewModel.activeSlot),
            isPresented: Binding(
                get: { pendingApplyImage != nil },
                set: { if !$0 { pendingApplyImage = nil } }
            ),
            presenting: pendingApplyImage
        ) { image in
            Button(MetadataStrings.applySlotButton(viewModel.activeSlot)) {
                Task {
                    if await viewModel.applyImage(image) {
                        onArtworkApplied()
                    }
                }
            }
            Button(.commonCancel, role: .cancel) {}
        } message: { image in
            let details = [image.displayProvider, image.resolutionText]
                .compactMap { $0 }
                .joined(separator: " · ")
            Text(details.isEmpty
                ? MetadataStrings.immediateArtworkNotice
                : "\(details)\n\(MetadataStrings.immediateArtworkNotice)")
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(MetadataStrings.chooseArtworkTitle)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Color.siloOnSurface)
                Text(target.displayTitle)
                    .font(.title3)
                    .foregroundStyle(Color.siloSecondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 24)

            HStack(spacing: 14) {
                ForEach(viewModel.availableSlots) { slot in
                    tvHeaderPill(
                        title: MetadataStrings.slotTitle(slot),
                        isActive: viewModel.activeSlot == slot
                    ) {
                        viewModel.selectSlot(slot)
                    }
                    .focused($focused, equals: .slot(slot))
                }

                if viewModel.activeSlot != .logo {
                    tvHeaderPill(
                        title: MetadataStrings.textlessOnlyLabel,
                        isActive: viewModel.textlessOnly
                    ) {
                        viewModel.toggleTextless()
                    }
                    .focused($focused, equals: .textless)
                }

                tvHeaderPill(
                    title: MetadataStrings.doneButton,
                    isActive: false
                ) {
                    dismiss()
                }
                .focused($focused, equals: .close)
            }
        }
        .focusSection()
        .defaultFocus($focused, .slot(viewModel.activeSlot), priority: .userInitiated)
    }

    private func tvHeaderPill(
        title: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 24, weight: isActive ? .semibold : .medium))
            }
        }
        .buttonStyle(TVMetadataPillButtonStyle(isActive: isActive))
    }

    // MARK: - Content Grid

    @ViewBuilder
    private var contentArea: some View {
        if viewModel.isLoading {
            VStack(spacing: 18) {
                ProgressView()
                Text(MetadataStrings.loadingArtwork)
                    .font(.title3)
                    .foregroundStyle(Color.siloSecondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = viewModel.errorMessage {
            VStack(spacing: 20) {
                Text(errorMessage)
                    .font(.title3)
                    .foregroundStyle(Color.siloErrorInk)
                    .multilineTextAlignment(.center)
                tvHeaderPill(
                    title: MetadataStrings.retryButton,
                    isActive: false
                ) {
                    Task { await viewModel.loadImages() }
                }
                .focused($focused, equals: .retry)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.filteredImages.isEmpty {
            VStack(spacing: 12) {
                Text(MetadataStrings.noArtworkTitle)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.siloOnSurface)
                Text(viewModel.textlessOnly ? MetadataStrings.noTextlessArtworkMessage : MetadataStrings.noArtworkMessage)
                    .font(.title3)
                    .foregroundStyle(Color.siloSecondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 720)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let columnCount = viewModel.activeSlot == .poster ? 5 : 3
            let columns = Array(repeating: GridItem(.flexible(), spacing: 36), count: columnCount)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 36) {
                    ForEach(viewModel.filteredImages) { image in
                        artworkCard(image)
                    }
                }
                .padding(.vertical, 28)
                .padding(.horizontal, 18)
            }
            .scrollClipDisabled()
            .clipped()
            .focusSection()
        }
    }

    private func artworkCard(_ image: AdminItemImage) -> some View {
        let isFocused = focused == .image(image.id)
        let currentMatch = viewModel.isCurrent(image)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        return Button {
            guard !viewModel.isBusy, !currentMatch else { return }
            pendingApplyImage = image
        } label: {
            Color.clear
                .aspectRatio(viewModel.activeSlot.aspectRatio, contentMode: .fit)
                .overlay {
                    ZStack {
                        if viewModel.activeSlot == .logo {
                            Color(hex: "#19191D")
                        } else {
                            Color.siloSurfaceElevated
                        }
                        if let url = image.url, !url.isEmpty {
                            AsyncImageView(
                                url: url,
                                contentMode: viewModel.activeSlot == .logo ? .fit : .fill
                            )
                            .padding(viewModel.activeSlot == .logo ? 22 : 0)
                        }
                    }
                }
                .clipped()
                .clipShape(shape)
                .overlay(
                    shape.strokeBorder(
                        isFocused ? Color.siloPrimary : (currentMatch ? Color.white.opacity(0.45) : Color.white.opacity(0.12)),
                        lineWidth: isFocused ? 4 : 1.5
                    )
                )
                .overlay(alignment: .topLeading) {
                    if currentMatch {
                        Text(image.isUploaded ? MetadataStrings.uploadedBadge : MetadataStrings.currentBadge)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.siloPrimary, in: Capsule())
                            .padding(14)
                    }
                }
        }
        .buttonStyle(TVCardFocusButtonStyle(scale: 1.05))
        .focused($focused, equals: .image(image.id))
    }

    // MARK: - Live Footer

    private var footerBar: some View {
        HStack(spacing: 18) {
            if viewModel.isApplying {
                ProgressView()
                    .scaleEffect(0.75)
                Text(MetadataStrings.applyingArtwork)
                    .font(.headline)
                    .foregroundStyle(Color.siloOnSurface)
            } else if let image = focusedImage {
                Text(image.displayProvider)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.siloOnSurface)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.12), in: Capsule())

                if let res = image.resolutionText {
                    Text(res)
                        .font(.system(size: 22).monospacedDigit())
                        .foregroundStyle(Color.siloSecondaryText)
                }

                if viewModel.activeSlot != .logo {
                    Text(image.isTextless ? "Textless" : image.language.uppercased())
                        .font(.system(size: 22))
                        .foregroundStyle(Color.siloSecondaryText)
                }

                if viewModel.isCurrent(image) {
                    Text(MetadataStrings.currentBadge)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.siloStatusWarning)
                }

                Spacer()

                if !viewModel.isCurrent(image) {
                    Text(MetadataStrings.tvSelectToApplyHint)
                        .font(.system(size: 20))
                        .foregroundStyle(Color.siloSecondaryText)
                }
            } else {
                Text(target.mediaType == "season" ? MetadataStrings.seasonArtworkNotice : MetadataStrings.immediateArtworkNotice)
                    .font(.system(size: 22))
                    .foregroundStyle(Color.siloSecondaryText)
                Spacer()
            }
        }
        .frame(height: 44)
    }
}
#endif

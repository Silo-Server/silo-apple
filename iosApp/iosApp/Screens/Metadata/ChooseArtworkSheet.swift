#if !os(tvOS)
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

struct ChooseArtworkSheet: View {
    let target: MetadataCurationTarget
    var initialSlot: MetadataImageSlot = .poster
    let onArtworkApplied: () -> Void

    @State private var viewModel: ChooseArtworkViewModel
    @State private var isShowingFileImporter = false
    @State private var isDropTargeted = false
    /// Slot captured at the moment the user opened Photos or Files so switching
    /// tabs during a slow download never uploads into a different slot.
    @State private var pendingUploadSlot: MetadataImageSlot
    #if os(iOS)
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isShowingPhotosPicker = false
    #endif

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(
        target: MetadataCurationTarget,
        initialSlot: MetadataImageSlot = .poster,
        onArtworkApplied: @escaping () -> Void
    ) {
        self.target = target
        self.initialSlot = initialSlot
        self.onArtworkApplied = onArtworkApplied
        let vm = ChooseArtworkViewModel(target: target, initialSlot: initialSlot)
        _viewModel = State(initialValue: vm)
        _pendingUploadSlot = State(initialValue: vm.activeSlot)
    }

    private var usesSplitLayout: Bool {
        #if os(macOS)
        return true
        #else
        return horizontalSizeClass == .regular
        #endif
    }

    var body: some View {
        Group {
            if usesSplitLayout {
                splitLayout
            } else {
                compactLayout
            }
        }
        .preferredColorScheme(.dark)
        .tint(Color.siloPrimary)
        .task {
            await viewModel.loadImages()
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.jpeg, .png, .webP, .image],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result, slot: pendingUploadSlot)
        }
        #if os(iOS)
        .photosPicker(
            isPresented: $isShowingPhotosPicker,
            selection: $selectedPhotoItem,
            matching: .images
        )
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            let capturedSlot = pendingUploadSlot
            selectedPhotoItem = nil
            viewModel.setUploadBusy(true)
            Task {
                guard let data = try? await newItem.loadTransferable(type: Data.self) else {
                    viewModel.setUploadBusy(false)
                    return
                }
                if await viewModel.uploadRawData(data, for: capturedSlot) {
                    onArtworkApplied()
                }
            }
        }
        #endif
    }

    // MARK: - Compact (iPhone) Layout

    private var compactLayout: some View {
        NavigationStack {
            VStack(spacing: 0) {
                slotPicker
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .background(MetadataPalette.sheetCanvas)

                Divider().overlay(MetadataPalette.hairline)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        previewStage(compact: true)
                        bannersSection
                        artworkGrid(columnCount: viewModel.activeSlot == .poster ? 3 : 2)
                    }
                    .padding(16)
                }
                .background(MetadataPalette.sheetCanvas)

                if viewModel.selectedImage != nil || viewModel.isBusy {
                    VStack(spacing: 0) {
                        Divider().overlay(MetadataPalette.hairline)
                        applyButton
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(MetadataPalette.sidebarCanvas)
                    }
                }
            }
            .navigationTitle(MetadataStrings.chooseArtworkTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.commonDone) { dismiss() }
                        .disabled(viewModel.isBusy)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    filterMenu
                    uploadMenu
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        .presentationBackground(MetadataPalette.sheetCanvas)
        #endif
    }

    // MARK: - Split (iPadOS Regular & macOS) Layout

    private var splitLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(MetadataStrings.chooseArtworkTitle)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(MetadataPalette.primaryText)
                        Text(target.displayTitle)
                            .font(.subheadline)
                            .foregroundStyle(MetadataPalette.secondaryText)
                            .lineLimit(1)
                    }

                    previewStage(compact: false)

                    Spacer(minLength: 8)

                    uploadDropZone
                    applyButton
                }
                .padding(18)
                .frame(width: 320)
                .background(MetadataPalette.sidebarCanvas)

                Divider().overlay(MetadataPalette.hairline)

                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        slotPicker
                            .frame(maxWidth: 320)
                        Spacer()
                        filterMenu
                        uploadMenu
                        Button(.commonDone) { dismiss() }
                            .keyboardShortcut(.cancelAction)
                            .disabled(viewModel.isBusy)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(MetadataPalette.sheetCanvas)

                    Divider().overlay(MetadataPalette.hairline)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            bannersSection
                            artworkGrid(columnCount: viewModel.activeSlot == .poster ? 4 : 3)
                        }
                        .padding(18)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(MetadataPalette.sheetCanvas)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 820, idealWidth: 940, minHeight: 580, idealHeight: 680)
        #endif
    }

    // MARK: - Controls

    private var slotPicker: some View {
        Picker(MetadataStrings.chooseArtworkTitle, selection: $viewModel.activeSlot) {
            ForEach(viewModel.availableSlots) { slot in
                Text(MetadataStrings.slotTitle(slot)).tag(slot)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onChange(of: viewModel.activeSlot) { _, _ in
            viewModel.resetFiltersForSlotChange()
        }
    }

    private var filterMenu: some View {
        Menu {
            if viewModel.activeSlot != .logo {
                Toggle(
                    MetadataStrings.textlessOnlyLabel,
                    isOn: Binding(
                        get: { viewModel.textlessOnly },
                        set: { _ in viewModel.toggleTextless() }
                    )
                )
                Divider()
            }
            Button {
                viewModel.selectProvider(nil)
            } label: {
                if viewModel.activeProvider == nil {
                    Label("\(MetadataStrings.allProvidersLabel) (\(viewModel.visibleImages.count))", systemImage: "checkmark")
                } else {
                    Text("\(MetadataStrings.allProvidersLabel) (\(viewModel.visibleImages.count))")
                }
            }
            ForEach(viewModel.providerBuckets) { bucket in
                Button {
                    viewModel.selectProvider(bucket.id)
                } label: {
                    let label = "\(bucket.id.uppercased()) (\(bucket.count))"
                    if viewModel.activeProvider == bucket.id {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
        } label: {
            Label(
                MetadataStrings.filterMenuLabel,
                systemImage: (viewModel.textlessOnly || viewModel.activeProvider != nil)
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
    }

    private var uploadMenu: some View {
        Menu {
            #if os(iOS)
            Button {
                pendingUploadSlot = viewModel.activeSlot
                isShowingPhotosPicker = true
            } label: {
                Label(MetadataStrings.uploadFromPhotos, systemImage: "photo.on.rectangle")
            }
            #endif
            Button {
                pendingUploadSlot = viewModel.activeSlot
                isShowingFileImporter = true
            } label: {
                Label(MetadataStrings.uploadFromFiles, systemImage: "doc.badge.plus")
            }
        } label: {
            if viewModel.isUploading {
                ProgressView().controlSize(.small)
            } else {
                Label(MetadataStrings.uploadMenuLabel, systemImage: "arrow.up.circle")
            }
        }
        .disabled(viewModel.isBusy)
    }

    // MARK: - Live Preview Stage

    private func previewStage(compact: Bool) -> some View {
        let preview = viewModel.previewImage
        let isPreviewingCandidate = viewModel.selectedImage != nil && !viewModel.isCurrent(viewModel.selectedImage!)
        let displayUrl = (preview?.url?.isEmpty == false ? preview?.url : nil)
            ?? (fallbackCurrentUrl?.isEmpty == false ? fallbackCurrentUrl : nil)
        let stageHeight: CGFloat = {
            switch viewModel.activeSlot {
            case .poster: return compact ? 220 : 320
            case .backdrop: return compact ? 175 : 170
            case .logo: return compact ? 116 : 140
            }
        }()
        let stageShape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        return VStack(alignment: .leading, spacing: 10) {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: stageHeight)
                .overlay {
                    ZStack {
                        if viewModel.activeSlot == .logo {
                            ArtworkCheckerboardBackground()
                        } else {
                            MetadataPalette.elevatedSurface
                        }

                        if let url = displayUrl {
                            switch viewModel.activeSlot {
                            case .poster:
                                Color.clear
                                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                                    .overlay {
                                        AsyncImageView(url: url, contentMode: .fill)
                                    }
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
                                    .padding(.vertical, 12)
                            case .backdrop:
                                AsyncImageView(url: url, contentMode: .fill)
                            case .logo:
                                AsyncImageView(url: url, contentMode: .fit)
                                    .padding(18)
                            }
                        } else {
                            VStack(spacing: 6) {
                                Image(systemName: "photo")
                                    .font(.title2)
                                Text(MetadataStrings.slotSingular(viewModel.activeSlot))
                                    .font(.caption)
                            }
                            .foregroundStyle(MetadataPalette.secondaryText)
                        }
                    }
                }
                .clipped()
                .clipShape(stageShape)
                .contentShape(stageShape)
                .allowsHitTesting(false)
                .overlay(
                    stageShape.strokeBorder(
                        isPreviewingCandidate ? Color.siloPrimary : MetadataPalette.hairline,
                        lineWidth: isPreviewingCandidate ? 1.5 : 1
                    )
                )
                .overlay(alignment: .topLeading) {
                    if let preview {
                        let isCur = viewModel.isCurrent(preview)
                        Text(isCur ? MetadataStrings.currentBadge : MetadataStrings.previewingBadge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(isCur ? Color.black : MetadataPalette.primaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                isCur ? Color.siloPrimary : Color.black.opacity(0.75),
                                in: Capsule()
                            )
                            .padding(10)
                    }
                }

            if let preview {
                HStack(spacing: 8) {
                    Text(preview.displayProvider)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(MetadataPalette.primaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.10), in: Capsule())

                    if let resolution = preview.resolutionText {
                        Text(resolution)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(MetadataPalette.secondaryText)
                    }

                    if viewModel.activeSlot != .logo {
                        Text(preview.isTextless ? "Textless" : preview.language.uppercased())
                            .font(.caption)
                            .foregroundStyle(MetadataPalette.secondaryText)
                    }
                    Spacer()
                }
            }

            Text(MetadataStrings.immediateArtworkNotice)
                .font(.caption2)
                .foregroundStyle(MetadataPalette.secondaryText)
        }
        .padding(12)
        .background(MetadataPalette.cellSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var fallbackCurrentUrl: String? {
        switch viewModel.activeSlot {
        case .poster: return target.posterUrl
        case .backdrop: return target.backdropUrl
        case .logo: return target.logoUrl
        }
    }

    private var uploadDropZone: some View {
        Button {
            pendingUploadSlot = viewModel.activeSlot
            isShowingFileImporter = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.doc")
                    .font(.subheadline)
                Text(MetadataStrings.dropArtworkHint)
                    .font(.caption)
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(isDropTargeted ? Color.siloPrimary : MetadataPalette.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(
                (isDropTargeted ? Color.white.opacity(0.10) : Color.white.opacity(0.04)),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? Color.siloPrimary : MetadataPalette.hairline,
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
            )
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            guard !viewModel.isBusy, let url = urls.first else { return false }
            uploadFile(at: url, slot: viewModel.activeSlot)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }

    // MARK: - Banners & Grid

    @ViewBuilder
    private var bannersSection: some View {
        if target.mediaType == "season" {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(MetadataPalette.lockedAmber)
                Text(MetadataStrings.seasonArtworkNotice)
                    .font(.caption)
                    .foregroundStyle(MetadataPalette.lockedAmber)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MetadataPalette.lockedAmber.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }

        if !viewModel.providerErrors.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(MetadataPalette.lockedAmber)
                Text(MetadataStrings.providerErrorsBanner(Array(viewModel.providerErrors.keys)))
                    .font(.caption)
                    .foregroundStyle(MetadataPalette.lockedAmber)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MetadataPalette.lockedAmber.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }

        if let error = viewModel.errorMessage {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(MetadataPalette.destructiveRed)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(MetadataPalette.primaryText)
                Spacer()
            }
            .padding(10)
            .background(MetadataPalette.destructiveRed.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    @ViewBuilder
    private func artworkGrid(columnCount: Int) -> some View {
        if viewModel.isLoading {
            VStack(spacing: 12) {
                ProgressView().tint(Color.siloPrimary)
                Text(MetadataStrings.loadingArtwork)
                    .font(.subheadline)
                    .foregroundStyle(MetadataPalette.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 56)
        } else if viewModel.filteredImages.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.title2)
                    .foregroundStyle(MetadataPalette.secondaryText)
                Text(MetadataStrings.noArtworkTitle)
                    .font(.headline)
                    .foregroundStyle(MetadataPalette.primaryText)
                Text(viewModel.textlessOnly ? MetadataStrings.noTextlessArtworkMessage : MetadataStrings.noArtworkMessage)
                    .font(.subheadline)
                    .foregroundStyle(MetadataPalette.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 52)
            .padding(.horizontal, 16)
        } else {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: columnCount)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(viewModel.filteredImages) { image in
                    artworkTile(image)
                }
            }
        }
    }

    private func artworkTile(_ image: AdminItemImage) -> some View {
        let isSelected = viewModel.selectedImage == image
        let isCurrent = viewModel.isCurrent(image)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        return Button {
            viewModel.selectedImage = isSelected ? nil : image
        } label: {
            Color.clear
                .aspectRatio(viewModel.activeSlot.aspectRatio, contentMode: .fit)
                .overlay {
                    ZStack {
                        if viewModel.activeSlot == .logo {
                            ArtworkCheckerboardBackground()
                        } else {
                            MetadataPalette.elevatedSurface
                        }

                        if let url = image.url, !url.isEmpty {
                            AsyncImageView(
                                url: url,
                                contentMode: viewModel.activeSlot == .logo ? .fit : .fill
                            )
                            .padding(viewModel.activeSlot == .logo ? 10 : 0)
                        }
                    }
                }
                .clipped()
                .clipShape(shape)
                .contentShape(shape)
                .overlay(
                    shape.strokeBorder(
                        isSelected ? Color.siloPrimary : (isCurrent ? Color.white.opacity(0.45) : MetadataPalette.hairline),
                        lineWidth: isSelected ? 2 : 1
                    )
                )
                .overlay(alignment: .topLeading) {
                    if isCurrent {
                        Text(image.isUploaded ? MetadataStrings.uploadedBadge : MetadataStrings.currentBadge)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.siloPrimary, in: Capsule())
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 4) {
                        Text(image.displayProvider)
                            .font(.system(size: 9, weight: .semibold))
                        if let res = image.resolutionText {
                            Text(res)
                                .font(.system(size: 9).monospacedDigit())
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.72), in: Capsule())
                    .padding(6)
                }
        }
        .buttonStyle(.plain)
    }

    private var applyButton: some View {
        Button {
            Task {
                if await viewModel.applySelected() {
                    onArtworkApplied()
                }
            }
        } label: {
            HStack(spacing: 8) {
                if viewModel.isApplying || viewModel.isUploading {
                    ProgressView().controlSize(.small).tint(.black)
                }
                Text(
                    viewModel.isUploading
                        ? MetadataStrings.uploadingArtwork
                        : (viewModel.isApplying
                            ? MetadataStrings.applyingArtwork
                            : MetadataStrings.applySlotButton(viewModel.activeSlot))
                )
                .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                viewModel.canApplySelection ? Color.siloPrimary : Color.white.opacity(0.16),
                in: Capsule()
            )
            .foregroundStyle(viewModel.canApplySelection ? Color.black : MetadataPalette.secondaryText)
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canApplySelection)
    }

    private func handleFileImport(_ result: Result<[URL], Error>, slot: MetadataImageSlot) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            uploadFile(at: url, slot: slot)
        case .failure(let error):
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func uploadFile(at url: URL, slot: MetadataImageSlot) {
        guard !viewModel.isBusy else { return }
        let needsAccess = url.startAccessingSecurityScopedResource()
        defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            viewModel.errorMessage = MetadataStrings.fileReadFailedError
            return
        }
        viewModel.setUploadBusy(true)
        Task {
            if await viewModel.uploadRawData(data, for: slot) {
                onArtworkApplied()
            }
        }
    }
}

/// Low-contrast dark checkerboard so white transparent clearlogos remain legible.
struct ArtworkCheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 12
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: "#141416")))
            let cols = Int(ceil(size.width / tile))
            let rows = Int(ceil(size.height / tile))
            var darkSquares = Path()
            for row in 0..<rows {
                for col in 0..<cols where (row + col).isMultiple(of: 2) {
                    darkSquares.addRect(CGRect(x: CGFloat(col) * tile, y: CGFloat(row) * tile, width: tile, height: tile))
                }
            }
            context.fill(darkSquares, with: .color(Color(hex: "#1F1F23")))
        }
    }
}
#endif

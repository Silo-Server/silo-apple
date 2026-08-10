#if os(tvOS)
import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import Foundation
import OSLog
import UIKit

/// tvOS HDMI mode negotiation helpers. The compositor on Apple TV
/// chooses HDMI refresh rate and HDR mode based on
/// `AVDisplayManager.preferredDisplayCriteria`. PlayerCore drives this at
/// load time (when stream FPS / dynamic range are known) and on dispose
/// (to release the criteria so the system UI returns to its preferred
/// mode). The Profile-5 gate stays on PlayerCore because it owns the
/// observation lifetime.
enum TVDisplayCriteria {
    /// The color signaling the TV compositor needs to choose an HDMI mode.
    /// Dolby Vision keeps its base-layer transfer because Profile 8.1 is PQ,
    /// 8.2 is SDR, and 8.4 is HLG.
    enum ContentFormat {
        case sdr
        case hdr10
        case hlg
        case dolbyVision(baseLayer: LoopbackSessionSpec.DVProfile8BaseLayer)

    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app.tvos",
        category: "TVDisplayCriteria"
    )

    static func activeTVWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            if let key = ws.windows.first(where: \.isKeyWindow) { return key }
            if let first = ws.windows.first { return first }
        }
        return nil
    }

    /// Result of a preferredDisplayCriteria write attempt. Callers own the
    /// logging so each surface keeps its established log grammar.
    enum ApplyOutcome {
        case applied
        case noDisplayManager
        case matchingDisabled
        /// `CMVideoFormatDescriptionCreate` failed. Not reachable through
        /// bad input — `makeFormatDescription` covers every range — so this
        /// means the allocation itself failed and nothing was written.
        case formatUnavailable

        var didWrite: Bool { self == .applied }
    }

    /// Criteria write against the public
    /// `AVDisplayCriteria(refreshRate:formatDescription:)` (tvOS 17+), for
    /// every dynamic range — SDR and Dolby Vision included.
    ///
    /// The compositor keys its HDMI mode off the codec fourcc plus the color
    /// signaling; the 4K raster size is nominal.
    @MainActor
    @discardableResult
    static func setCriteria(_ contentFormat: ContentFormat, refreshRate: Float) -> ApplyOutcome {
        guard let dm = activeTVWindow()?.avDisplayManager else {
            return .noDisplayManager
        }
        guard dm.isDisplayCriteriaMatchingEnabled else {
            return .matchingDisabled
        }
        guard let formatDescription = makeFormatDescription(for: contentFormat) else {
            return .formatUnavailable
        }
        dm.preferredDisplayCriteria = AVDisplayCriteria(
            refreshRate: refreshRate,
            formatDescription: formatDescription
        )
        return .applied
    }

    /// The nominal 4K description the compositor negotiates from. Each
    /// supported content format has a complete mapping; nil means the Core
    /// Media allocation itself failed.
    private static func makeFormatDescription(
        for contentFormat: ContentFormat
    ) -> CMVideoFormatDescription? {
        let codecType: CMVideoCodecType
        let colorPrimaries: CFString
        let transferFunction: CFString
        let yCbCrMatrix: CFString
        switch contentFormat {
        case .sdr:
            // Rec.709 throughout: the SDR counterpart of the BT.2020
            // signaling below, so the compositor is asked for an SDR mode at
            // this refresh rate rather than being left in whatever HDR mode
            // a previous title negotiated.
            codecType = kCMVideoCodecType_HEVC
            colorPrimaries = kCVImageBufferColorPrimaries_ITU_R_709_2
            transferFunction = kCVImageBufferTransferFunction_ITU_R_709_2
            yCbCrMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case .hdr10:
            codecType = kCMVideoCodecType_HEVC
            colorPrimaries = kCVImageBufferColorPrimaries_ITU_R_2020
            transferFunction = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
            yCbCrMatrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
        case .hlg:
            codecType = kCMVideoCodecType_HEVC
            colorPrimaries = kCVImageBufferColorPrimaries_ITU_R_2020
            transferFunction = kCVImageBufferTransferFunction_ITU_R_2100_HLG
            yCbCrMatrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
        case .dolbyVision(let baseLayer):
            // `dvh1` is the loopback writer's Dolby Vision sample entry. The
            // codec type asks for a Dolby Vision HDMI mode; the color triple
            // must still describe the actual base layer, which differs by
            // Profile 8 variant (8.1 PQ, 8.2 Rec.709 SDR, 8.4 HLG) — asking
            // for PQ on an SDR base negotiates a mode the base-layer pixels
            // are not graded for. Shared with the format description
            // `PlayerCore` hands the decoder, so the mode the panel is asked
            // for and the frames it is handed cannot describe different
            // transfers.
            codecType = kCMVideoCodecType_DolbyVisionHEVC
            let colorimetry = VideoColorMetadata.dolbyVisionBaseLayerColorimetry(baseLayer)
            colorPrimaries = colorimetry.primaries
            transferFunction = colorimetry.transfer
            yCbCrMatrix = colorimetry.matrix
        }
        let colorExtensions: NSDictionary = [
            kCMFormatDescriptionExtension_ColorPrimaries: colorPrimaries,
            kCMFormatDescriptionExtension_TransferFunction: transferFunction,
            kCMFormatDescriptionExtension_YCbCrMatrix: yCbCrMatrix,
        ]
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: 3840,
            height: 2160,
            extensions: colorExtensions,
            formatDescriptionOut: &formatDescription
        )
        return formatDescription
    }

    /// Blocks until the HDMI renegotiation requested by a criteria write has
    /// settled, within a bounded budget. A criteria write is a plain
    /// property assignment; the renegotiation it requests only surfaces on
    /// `isDisplayModeSwitchInProgress` after a short delay, so a lone
    /// immediate check would race it. Phase one polls until the manager
    /// reports a switch underway, bailing out early when the panel's EDR
    /// headroom already clears the HDR floor (nothing left to negotiate).
    /// Phase two polls until the manager reports the switch finished. A
    /// switch that never surfaces within budget means the criteria were
    /// unsatisfiable or a no-op — playback proceeds and AVPlayer tonemaps.
    /// The returned Bool is "panel is hosting HDR at exit", judged purely by
    /// EDR headroom: the only public signal that separates a dynamic-range
    /// change from rate-only matching.
    @MainActor
    static func waitForModeSwitchSettle() async -> Bool {
        guard let window = activeTVWindow() else {
            print("[CMP] displayModeSettle: no window")
            return false
        }
        let manager = window.avDisplayManager
        let screen = window.screen

        var negotiationBegan = false
        var startBudget = HDRDisplayCriteriaPolicy.switchStartPollAttempts
        while startBudget > 0, !Task.isCancelled {
            if manager.isDisplayModeSwitchInProgress {
                negotiationBegan = true
                break
            }
            if screen.currentEDRHeadroom > HDRDisplayCriteriaPolicy.hdrHeadroomFloor {
                logger.info("settle: panel already HDR")
                print(String(format: "[CMP] displayModeSettle already-hdr headroom=%.3f", screen.currentEDRHeadroom))
                return true
            }
            startBudget -= 1
            try? await Task.sleep(
                nanoseconds: UInt64(HDRDisplayCriteriaPolicy.switchStartPollIntervalMs) * 1_000_000
            )
        }
        if Task.isCancelled { return panelIsHostingHDR() }
        guard negotiationBegan else {
            logger.info("settle: switch never started")
            print(String(format: "[CMP] displayModeSettle no-switch-start headroom=%.3f", screen.currentEDRHeadroom))
            return screen.currentEDRHeadroom > HDRDisplayCriteriaPolicy.hdrHeadroomFloor
        }

        var settleBudget = HDRDisplayCriteriaPolicy.switchSettlePollAttempts
        var settledAfterMs = 0
        while settleBudget > 0, !Task.isCancelled {
            try? await Task.sleep(
                nanoseconds: UInt64(HDRDisplayCriteriaPolicy.switchSettlePollIntervalMs) * 1_000_000
            )
            settleBudget -= 1
            settledAfterMs += HDRDisplayCriteriaPolicy.switchSettlePollIntervalMs
            if !manager.isDisplayModeSwitchInProgress {
                let headroom = screen.currentEDRHeadroom
                logger.info("settle: switch settled afterMs=\(settledAfterMs)")
                print(String(format: "[CMP] displayModeSettle settled afterMs=%d headroom=%.3f", settledAfterMs, headroom))
                return headroom > HDRDisplayCriteriaPolicy.hdrHeadroomFloor
            }
        }
        if Task.isCancelled { return panelIsHostingHDR() }
        logger.warning("settle: switch did not settle in budget")
        print(String(format: "[CMP] displayModeSettle timeout headroom=%.3f", screen.currentEDRHeadroom))
        return screen.currentEDRHeadroom > HDRDisplayCriteriaPolicy.hdrHeadroomFloor
    }

    /// Panel-readiness signal: whether the screen is currently hosting an
    /// HDR mode. Only meaningful after a criteria write has settled.
    @MainActor
    static func panelIsHostingHDR() -> Bool {
        guard let screen = activeTVWindow()?.screen else { return false }
        return screen.currentEDRHeadroom > HDRDisplayCriteriaPolicy.hdrHeadroomFloor
    }

    @MainActor
    static func apply(refreshRate: Float, contentFormat: ContentFormat) {
        let outcome = setCriteria(contentFormat, refreshRate: refreshRate)
        switch outcome {
        case .noDisplayManager:
            logger.warning("apply: no avDisplayManager")
            print("[CMP] applyDisplayCriteria: no avDisplayManager (skipping HDMI negotiation)")
        case .matchingDisabled:
            logger.info("apply: matching disabled")
            print("[CMP] applyDisplayCriteria: isDisplayCriteriaMatchingEnabled=false (user has 'Match Content' off)")
        case .applied:
            logger.info("apply: fps=\(refreshRate) format=\(String(describing: contentFormat))")
            print(String(format:
                "[CMP] applyDisplayCriteria APPLIED fps=%.3f format=%@ matching=true",
                Double(refreshRate), String(describing: contentFormat)))
        case .formatUnavailable:
            logger.warning("apply: no criteria written format=\(String(describing: contentFormat))")
            print("[CMP] applyDisplayCriteria: no criteria written format=\(contentFormat)")
        }
    }

    static func clear(context: String) {
        DispatchQueue.main.async {
            guard let dm = activeTVWindow()?.avDisplayManager else {
                logger.warning("clear: no avDisplayManager")
                print("[CMP] clearDisplayCriteria context=\(context) manager=nil")
                return
            }
            dm.preferredDisplayCriteria = nil
            logger.info("clear context=\(context)")
            print("[CMP] clearDisplayCriteria context=\(context) switchInProgress=\(dm.isDisplayModeSwitchInProgress ? 1 : 0)")
        }
    }
}
#endif

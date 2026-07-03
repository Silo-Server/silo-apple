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
        case formatUnavailable
    }

    /// Dynamic-range criteria write (private initializer bridged via
    /// `AVDisplayCriteriaPrivate.h`). The shipped path for Dolby Vision and
    /// PlayerCore's HDR signaling.
    @MainActor
    @discardableResult
    static func setRangeCriteria(
        _ dynamicRange: SpikeDynamicRange, refreshRate: Float
    ) -> ApplyOutcome {
        guard let dm = activeTVWindow()?.avDisplayManager else {
            return .noDisplayManager
        }
        guard dm.isDisplayCriteriaMatchingEnabled else {
            return .matchingDisabled
        }
        dm.preferredDisplayCriteria = AVDisplayCriteria(
            refreshRate: refreshRate,
            videoDynamicRange: dynamicRange.rawValue
        )
        return .applied
    }

    /// Format-description-based criteria write for plain HDR10/HLG HEVC
    /// (public `AVDisplayCriteria(refreshRate:formatDescription:)`,
    /// tvOS 17+). The compositor keys its HDMI mode off the codec fourcc
    /// plus the BT.2020 color signaling; the 4K raster size is nominal.
    @MainActor
    @discardableResult
    static func setHDRFormatCriteria(
        hlg: Bool, refreshRate: Float
    ) -> ApplyOutcome {
        guard let dm = activeTVWindow()?.avDisplayManager else {
            return .noDisplayManager
        }
        guard dm.isDisplayCriteriaMatchingEnabled else {
            return .matchingDisabled
        }
        let transferFunction: CFString = hlg
            ? kCVImageBufferTransferFunction_ITU_R_2100_HLG
            : kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        let colorExtensions: NSDictionary = [
            kCMFormatDescriptionExtension_ColorPrimaries:
                kCVImageBufferColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction: transferFunction,
            kCMFormatDescriptionExtension_YCbCrMatrix:
                kCVImageBufferYCbCrMatrix_ITU_R_2020,
        ]
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: 3840,
            height: 2160,
            extensions: colorExtensions,
            formatDescriptionOut: &formatDescription
        )
        guard let formatDescription else { return .formatUnavailable }
        dm.preferredDisplayCriteria = AVDisplayCriteria(
            refreshRate: refreshRate,
            formatDescription: formatDescription
        )
        return .applied
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
    static func apply(refreshRate: Float, dynamicRange: SpikeDynamicRange) {
        switch setRangeCriteria(dynamicRange, refreshRate: refreshRate) {
        case .noDisplayManager:
            logger.warning("apply: no avDisplayManager")
            print("[CMP] applyDisplayCriteria: no avDisplayManager (skipping HDMI negotiation)")
        case .matchingDisabled:
            logger.info("apply: matching disabled")
            print("[CMP] applyDisplayCriteria: isDisplayCriteriaMatchingEnabled=false (user has 'Match Content' off)")
        case .applied:
            logger.info("apply: fps=\(refreshRate) dr=\(dynamicRange.rawValue)")
            print(String(format:
                "[CMP] applyDisplayCriteria APPLIED fps=%.3f dr=%d matching=true",
                Double(refreshRate), Int(dynamicRange.rawValue)))
        case .formatUnavailable:
            // Not produced by the range-criteria path.
            break
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

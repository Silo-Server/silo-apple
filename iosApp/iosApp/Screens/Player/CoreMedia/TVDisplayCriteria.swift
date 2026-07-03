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

    /// Waits for the HDMI mode negotiation a criteria write kicks off. The
    /// handshake starts asynchronously after the property write, so stage 1
    /// polls for it to begin (early-exiting when the panel already reports
    /// HDR headroom); stage 2 polls for it to clear. If it never starts
    /// within budget the panel can't satisfy the criteria (or the write was
    /// a no-op) and playback should proceed — AVPlayer tonemaps. Returns
    /// whether the panel is hosting HDR (EDR headroom above the floor) at
    /// exit: post-settle headroom is the only public signal separating a
    /// dynamic-range switch from rate-only matching.
    @MainActor
    static func waitForModeSwitchSettle() async -> Bool {
        guard let window = activeTVWindow() else {
            print("[CMP] displayModeSettle: no window")
            return false
        }
        let dm = window.avDisplayManager
        let screen = window.screen
        var sawSwitchStart = false
        for _ in 0..<HDRDisplayCriteriaPolicy.switchStartPollAttempts {
            if Task.isCancelled { return panelIsHostingHDR() }
            if dm.isDisplayModeSwitchInProgress {
                sawSwitchStart = true
                break
            }
            if screen.currentEDRHeadroom > HDRDisplayCriteriaPolicy.hdrHeadroomFloor {
                logger.info("settle: panel already HDR")
                print(String(format: "[CMP] displayModeSettle already-hdr headroom=%.3f", screen.currentEDRHeadroom))
                return true
            }
            try? await Task.sleep(
                nanoseconds: UInt64(HDRDisplayCriteriaPolicy.switchStartPollIntervalMs) * 1_000_000
            )
        }
        guard sawSwitchStart else {
            logger.info("settle: switch never started")
            print(String(format: "[CMP] displayModeSettle no-switch-start headroom=%.3f", screen.currentEDRHeadroom))
            return screen.currentEDRHeadroom > HDRDisplayCriteriaPolicy.hdrHeadroomFloor
        }
        for tick in 0..<HDRDisplayCriteriaPolicy.switchSettlePollAttempts {
            if Task.isCancelled { return panelIsHostingHDR() }
            try? await Task.sleep(
                nanoseconds: UInt64(HDRDisplayCriteriaPolicy.switchSettlePollIntervalMs) * 1_000_000
            )
            if !dm.isDisplayModeSwitchInProgress {
                let headroom = screen.currentEDRHeadroom
                logger.info("settle: switch settled tick=\(tick)")
                print(String(format: "[CMP] displayModeSettle settled tick=%d headroom=%.3f", tick, headroom))
                return headroom > HDRDisplayCriteriaPolicy.hdrHeadroomFloor
            }
        }
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

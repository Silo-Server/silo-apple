#if os(iOS)
import AVKit
import SwiftUI

/// AirPlay button for the mobile player's top strip.
///
/// The picker lives inside the `showControls` branch of `MobilePlayerControls`,
/// which the 3s auto-hide tears down. UIKit taps on this view never reach the
/// SwiftUI gesture layer, so without `onPresentingRoutes` the timer keeps
/// running while the route sheet is up and dismantles the button — and the
/// sheet with it — mid-selection. The callback lets the caller pin the
/// controls for the duration, the same way sheet presentation does.
struct AirPlayRoutePicker: UIViewRepresentable {
    let onPresentingRoutes: (Bool) -> Void

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.activeTintColor = .white
        picker.tintColor = .white
        picker.prioritizesVideoDevices = true
        picker.accessibilityLabel = "AirPlay"
        picker.accessibilityHint = "Choose a device for video playback"
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        // The closure captures the current view generation; refresh it so the
        // coordinator never calls back into a stale one.
        context.coordinator.onPresentingRoutes = onPresentingRoutes
    }

    static func dismantleUIView(_ uiView: AVRoutePickerView, coordinator: Coordinator) {
        uiView.delegate = nil
        // If the view goes away while the sheet is up, "did end" never
        // arrives — release the pin here so the controls can auto-hide again.
        coordinator.resignPresentation()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPresentingRoutes: onPresentingRoutes)
    }

    /// `AVRoutePickerView.delegate` is weak and SwiftUI owns the coordinator's
    /// lifetime, so this deliberately holds no reference back to the view.
    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var onPresentingRoutes: (Bool) -> Void
        private var isPresenting = false

        init(onPresentingRoutes: @escaping (Bool) -> Void) {
            self.onPresentingRoutes = onPresentingRoutes
        }

        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            guard !isPresenting else { return }
            isPresenting = true
            onPresentingRoutes(true)
        }

        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            resignPresentation()
        }

        func resignPresentation() {
            guard isPresenting else { return }
            isPresenting = false
            onPresentingRoutes(false)
        }
    }
}
#endif

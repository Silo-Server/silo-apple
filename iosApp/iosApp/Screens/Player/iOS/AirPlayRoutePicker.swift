#if os(iOS)
import SwiftUI
import AVKit

/// Thin wrapper around `AVRoutePickerView` so the player's top strip can
/// offer AirPlay. The system view draws its own button; callers give it a
/// frame and a glass backing to match the neighboring controls.
struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.backgroundColor = .clear
        view.tintColor = .white
        view.activeTintColor = .systemBlue
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif

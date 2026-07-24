#if os(iOS)
import AVKit
import SwiftUI

struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.activeTintColor = .white
        picker.tintColor = .white
        picker.prioritizesVideoDevices = true
        picker.accessibilityLabel = "AirPlay"
        picker.accessibilityHint = "Choose a device for video playback"
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif

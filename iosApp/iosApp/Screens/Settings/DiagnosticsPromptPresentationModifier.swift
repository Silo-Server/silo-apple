#if os(iOS) || os(tvOS)
import SwiftUI

/// Presents the pending-report prompt and its notices. `isEnabled` gates the
/// presentation bindings only: wrapping `content` in a condition would give
/// the whole app a new identity each time it flips.
struct DiagnosticsPromptPresentationModifier: ViewModifier {
    @Bindable var model: DiagnosticsViewModel
    let isEnabled: Bool

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
            .fullScreenCover(item: gated($model.prompt)) { prompt in
                TVDiagnosticsPromptScreen(prompt: prompt, model: model)
            }
            .alert(item: gated($model.notice)) { notice in
                Alert(title: Text("Diagnostics"), message: Text(notice.message))
            }
        #else
        content
            .sheet(item: gated($model.prompt)) { prompt in
                DiagnosticsPromptSheet(prompt: prompt, model: model)
                    .interactiveDismissDisabled()
            }
            .alert(item: gated($model.notice)) { notice in
                Alert(title: Text("Diagnostics"), message: Text(notice.message))
            }
        #endif
    }

    private func gated<Item>(_ binding: Binding<Item?>) -> Binding<Item?> {
        Binding(
            get: { isEnabled ? binding.wrappedValue : nil },
            set: { binding.wrappedValue = $0 }
        )
    }
}
#endif

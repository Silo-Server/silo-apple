#if os(iOS) || os(tvOS)
import SwiftUI

struct DiagnosticsPromptPresentationModifier: ViewModifier {
    @Bindable var model: DiagnosticsViewModel
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            #if os(tvOS)
            content
                .fullScreenCover(item: $model.prompt) { prompt in
                    TVDiagnosticsPromptScreen(prompt: prompt, model: model)
                }
                .alert(item: $model.notice) { notice in
                    Alert(title: Text("Diagnostics"), message: Text(notice.message))
                }
            #else
            content
                .sheet(item: $model.prompt) { prompt in
                    DiagnosticsPromptSheet(prompt: prompt, model: model)
                        .interactiveDismissDisabled()
                }
                .alert(item: $model.notice) { notice in
                    Alert(title: Text("Diagnostics"), message: Text(notice.message))
                }
            #endif
        } else {
            content
        }
    }
}
#endif

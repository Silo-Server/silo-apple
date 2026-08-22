import Foundation

#if os(tvOS)
import UIKit
#endif

enum AetherDisplayContext {
    @MainActor
    static var matchContentEnabled: Bool {
        #if os(tvOS)
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            let window = windowScene.windows.first(where: \.isKeyWindow)
                ?? windowScene.windows.first
            if let displayManager = window?.avDisplayManager {
                return displayManager.isDisplayCriteriaMatchingEnabled
            }
        }
        return false
        #else
        return true
        #endif
    }
}

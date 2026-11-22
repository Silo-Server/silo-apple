#if os(iOS) || os(tvOS)
import Foundation

struct DiagnosticsNotice: Identifiable, Equatable {
    let id = UUID()
    /// One or more sentences, shown in order.
    let messages: [LocalizedStringResource]

    init(message: LocalizedStringResource) {
        messages = [message]
    }

    init(messages: [LocalizedStringResource]) {
        self.messages = messages
    }

    /// The sentences in a view's `\.locale`, joined by a space.
    func text(in locale: Locale) -> String {
        messages.map { AppLanguage.string($0, locale: locale) }.joined(separator: " ")
    }
}
#endif

#if os(tvOS)
import SwiftUI

/// The whole description of an audiobook, opened from the detail page's
/// About section when its clamped text is cut off. The cover and title stay
/// on the left; the text scrolls on the right. Menu closes it.
///
/// Focus: tvOS scrolls only to focusable views, so the text is split into
/// passages of a few sentences, each a passive focus stop. Up and Down move
/// passage by passage and the scroll view follows natively.
struct TVAudiobookDescriptionView: View {
    let detail: ItemDetail
    let overview: String

    @Environment(\.locale) private var locale
    @FocusState private var focusedPassage: Int?

    private let passages: [DescriptionPassage]
    private let model: TVAudiobookViewModel

    init(detail: ItemDetail, overview: String) {
        self.detail = detail
        self.overview = overview
        self.passages = DescriptionPassage.split(overview)
        self.model = TVAudiobookViewModel(detail: detail)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TVAudiobookBackdrop(posterUrl: detail.posterUrl, thumbhash: detail.posterThumbhash)
                .ignoresSafeArea()
            Color.black.opacity(0.45).ignoresSafeArea()

            HStack(alignment: .top, spacing: 90) {
                identity
                    .frame(width: 420, alignment: .leading)
                    .padding(.top, 120)
                text
            }
            .padding(.horizontal, SiloTheme.safePadding)
        }
        .defaultFocus($focusedPassage, passages.first?.id)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 0) {
            AsyncImageView(
                url: detail.posterUrl ?? "",
                thumbhash: detail.posterThumbhash,
                targetSize: CGSize(width: 340, height: 340),
                contentMode: .fill,
                placeholderStyle: .artwork,
                placeholderSymbol: ArtworkPlaceholderSymbol.audiobook
            )
            .frame(width: 340, height: 340)
            .clipShape(RoundedRectangle(cornerRadius: SiloTheme.cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.6), radius: 30, x: 0, y: 18)

            Text(model.title)
                .font(.system(size: 40, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 36)

            if let series = model.seriesLine {
                Text(series.uppercased(with: locale))
                    .font(.system(size: 19, weight: .bold))
                    .tracking(3)
                    .foregroundColor(TVAudiobookStyle.gold)
                    .lineLimit(2)
                    .padding(.top, 12)
            }
        }
    }

    private var text: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                TVSectionHeader(title: AppLanguage.string(.detailAudiobookAbout, locale: locale))
                    .padding(.bottom, 28)
                ForEach(passages) { passage in
                    PassageView(text: passage.text)
                        .focusable(true)
                        .focused($focusedPassage, equals: passage.id)
                        .padding(.top, passage.startsParagraph && passage.id > 0 ? 26 : 0)
                }
            }
            .padding(.top, 120)
            .padding(.bottom, 160)
            .frame(maxWidth: 1080, alignment: .leading)
        }
        .scrollClipDisabled()
    }
}

/// A run of sentences short enough to fit on screen with room to spare, so
/// focusing it always scrolls all of it into view.
struct DescriptionPassage: Identifiable, Equatable {
    let id: Int
    let text: String
    /// Whether a paragraph break precedes it (drawn as extra space).
    let startsParagraph: Bool

    /// Roughly six lines at the reading width.
    static let targetLength = 420

    /// Splits text into paragraphs, then splits long paragraphs at sentence
    /// boundaries into passages near `targetLength` characters.
    static func split(_ text: String) -> [DescriptionPassage] {
        var passages: [DescriptionPassage] = []
        let paragraphs = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for paragraph in paragraphs {
            for (index, chunk) in chunks(of: paragraph).enumerated() {
                passages.append(DescriptionPassage(id: passages.count, text: chunk, startsParagraph: index == 0))
            }
        }
        return passages
    }

    private static func chunks(of paragraph: String) -> [String] {
        guard paragraph.count > targetLength else { return [paragraph] }
        var sentences: [String] = []
        paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence { sentences.append(sentence) }
        }
        guard sentences.count > 1 else { return [paragraph] }
        var chunks: [String] = []
        var current = ""
        for sentence in sentences {
            if !current.isEmpty, current.count + sentence.count > targetLength {
                chunks.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
            current += sentence
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            chunks.append(current.trimmingCharacters(in: .whitespaces))
        }
        return chunks
    }
}

private struct PassageView: View {
    let text: String

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Text(text)
            .font(.system(size: 28))
            .foregroundColor(.white.opacity(isFocused ? 1 : 0.72))
            .lineSpacing(8)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: SiloTheme.cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(isFocused ? 0.08 : 0))
                    .padding(.horizontal, -24)
            )
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
    }
}
#endif

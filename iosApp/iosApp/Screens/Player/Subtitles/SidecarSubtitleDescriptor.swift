import Foundation

/// Product-level descriptor for an external subtitle artifact.
struct SidecarSubtitleDescriptor: Hashable {
    let index: Int
    let language: String?
    let codec: String?
    let label: String?
    let source: String?
    let forced: Bool?
    let isDefault: Bool?
    let isHearingImpaired: Bool?
    let fontBundleUrl: URL?
    let url: URL

    init(
        index: Int,
        language: String?,
        codec: String?,
        label: String?,
        source: String?,
        forced: Bool?,
        isDefault: Bool? = nil,
        isHearingImpaired: Bool? = nil,
        fontBundleUrl: URL? = nil,
        url: URL
    ) {
        self.index = index
        self.language = language
        self.codec = codec
        self.label = label
        self.source = source
        self.forced = forced
        self.isDefault = isDefault
        self.isHearingImpaired = isHearingImpaired
        self.fontBundleUrl = fontBundleUrl
        self.url = url
    }
}

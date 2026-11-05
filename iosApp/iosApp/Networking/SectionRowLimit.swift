import Foundation
import Synchronization

/// Home and library rows show at most `cards` cards. The row's trailing
/// Explore all card opens the rest on the section's full page.
enum SectionRowLimit {
    static let cards = 20

    /// Each row cut to `cards`, with `item_limit` reporting the cut. Older
    /// servers send up to the row's configured limit (often 100).
    static func capped(_ response: SectionsResponse) -> SectionsResponse {
        guard response.sections.contains(where: { $0.items.count > cards || ($0.itemLimit ?? 0) > cards }) else {
            return response
        }
        return SectionsResponse(sections: response.sections.map { section in
            ResolvedSection(
                id: section.id,
                sectionType: section.sectionType,
                title: section.title,
                featured: section.featured,
                itemLimit: section.itemLimit.map { min($0, cards) },
                totalCount: section.totalCount,
                isCustom: section.isCustom,
                customized: section.customized,
                items: Array(section.items.prefix(cards))
            )
        })
    }

    /// The server refused `item_limit` as an unknown query parameter (`422`
    /// `validation_failed`): it was downgraded after advertising it.
    static func isUnsupportedItemLimit(_ error: Error) -> Bool {
        guard case APIv2Error.problem(let problem) = error else { return false }
        return problem.errors?.contains {
            $0.location == "query.item_limit" && $0.code == "unknown_parameter"
        } == true
    }
}

/// Whether a server accepts `item_limit` on its Home and library section
/// reads, from `section_item_limit_max` in `GET /api/v2/home/capabilities`.
/// Servers without it reject the parameter with `422`, so it is sent only to
/// a server that advertised it.
///
/// The answer is remembered per server, so a launch's first Home read already
/// asks for short rows. A failed probe keeps the previous answer.
final class SectionItemLimitSupport: Sendable {
    static let shared = SectionItemLimitSupport()

    struct Memory: Sendable {
        let load: @Sendable (_ serverID: String) -> Int?
        let save: @Sendable (_ serverID: String, _ max: Int?) -> Void

        static let userDefaults = Memory(
            load: { serverID in
                let value = UserDefaults.standard.integer(forKey: key(serverID))
                return value > 0 ? value : nil
            },
            save: { serverID, max in
                if let max {
                    UserDefaults.standard.set(max, forKey: key(serverID))
                } else {
                    UserDefaults.standard.removeObject(forKey: key(serverID))
                }
            }
        )

        private static func key(_ serverID: String) -> String {
            "sectionItemLimitMax.v1.\(serverID)"
        }
    }

    /// Server ID → advertised maximum, nil when the server offers none.
    private let known = Mutex<[String: Int?]>([:])
    private let memory: Memory

    init(memory: Memory = .userDefaults) {
        self.memory = memory
    }

    /// The `item_limit` to send to `serverID`, or nil to send none.
    func itemLimit(serverID: String) -> Int? {
        let max = known.withLock { known -> Int? in
            if let entry = known[serverID] { return entry }
            let loaded = memory.load(serverID)
            known[serverID] = loaded
            return loaded
        }
        return max.map { min($0, SectionRowLimit.cards) }
    }

    func record(_ max: Int?, serverID: String) {
        let max = max.flatMap { $0 > 0 ? $0 : nil }
        known.withLock { $0[serverID] = max }
        memory.save(serverID, max)
    }

    /// Re-read the active server's capability.
    func refresh(api: SiloAPI = .shared) async {
        guard let probe = try? await api.homeSectionItemLimitMax() else { return }
        record(probe.max, serverID: probe.serverID)
    }
}

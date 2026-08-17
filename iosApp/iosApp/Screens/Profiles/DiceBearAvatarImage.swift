import SwiftUI

/// Cached, retrying loader for DiceBear avatar PNGs.
///
/// Built to replace `AsyncImage` in the `CreateProfileView` preset grid.
/// Eighteen parallel `AsyncImage` fetches inside a `LazyVGrid` routinely
/// stall or fail — the view's `.task` gets cancelled as the cell reflows,
/// `URLSession`'s per-host pool of six connections queues the rest, and
/// SwiftUI latches the cancelled ones as `.failure`, which is what the
/// "film" placeholder reveals.
///
/// This loader decouples the download from the view lifecycle: the actor
/// owns each in-flight `Task` so cell churn doesn't cancel it, successful
/// decodes are memoised by URL, and failures retry twice with a short
/// backoff before giving up.
struct DiceBearAvatarImage: View {
    let url: String

    @State private var image: PlatformImage?
    @State private var didFail: Bool = false

    var body: some View {
        ZStack {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity)
            } else if didFail {
                failurePlaceholder
            } else {
                loadingPlaceholder
            }
        }
        .task(id: url) { await load() }
    }

    private var loadingPlaceholder: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.white.opacity(0.05))
    }

    private var failurePlaceholder: some View {
        Image(systemName: "person.crop.square")
            .font(.system(size: 20, weight: .regular))
            .foregroundStyle(Color.white.opacity(0.3))
    }

    private func load() async {
        if let cached = await DiceBearImageCache.shared.cached(url) {
            image = cached
            return
        }
        if let fetched = await DiceBearImageCache.shared.fetch(url) {
            withAnimation(.easeOut(duration: 0.18)) { image = fetched }
        } else {
            didFail = true
        }
    }
}

/// In-memory cache for DiceBear avatar PNGs. One shared instance across the
/// app since preset URLs are deterministic — the same seed resolves to the
/// same bytes forever, so memoising is safe and cheap.
actor DiceBearImageCache {
    static let shared = DiceBearImageCache()

    private var cache: [String: PlatformImage] = [:]
    private var inflight: [String: Task<PlatformImage?, Never>] = [:]

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpMaximumConnectionsPerHost = 12
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    func cached(_ url: String) -> PlatformImage? { cache[url] }

    func fetch(_ url: String) async -> PlatformImage? {
        if let hit = cache[url] { return hit }
        if let existing = inflight[url] { return await existing.value }

        let task = Task { () -> PlatformImage? in
            guard let u = URL(string: url) else { return nil }
            let backoff: [UInt64] = [0, 250_000_000, 750_000_000] // 0ms, 250ms, 750ms
            for attempt in 0..<backoff.count {
                if backoff[attempt] > 0 {
                    try? await Task.sleep(nanoseconds: backoff[attempt])
                }
                do {
                    let (data, response) = try await session.data(from: u)
                    if let http = response as? HTTPURLResponse,
                       !(200..<300).contains(http.statusCode) {
                        continue
                    }
                    if let image = PlatformImage.siloImage(data: data) {
                        return image
                    }
                } catch {
                    continue
                }
            }
            return nil
        }

        inflight[url] = task
        let result = await task.value
        inflight[url] = nil
        if let result { cache[url] = result }
        return result
    }
}

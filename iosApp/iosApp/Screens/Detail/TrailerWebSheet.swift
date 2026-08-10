#if os(iOS)
import SwiftUI
import UIKit
import WebKit

/// In-app player for a remote (YouTube) trailer, presented as a sheet from
/// the detail page's trailers rail.
///
/// Mirrors the web client's `TrailerModal`: the privacy-preserving
/// `youtube-nocookie.com` embed inside a web view that is allowed to start
/// playback inline and without a user gesture, so the trailer begins the
/// moment the sheet settles. `SFSafariViewController` was the obvious
/// alternative and can't do this — it can only load the full watch page,
/// with its consent interstitials, ads, and browser chrome.
struct TrailerWebSheet: View {
    /// Shown in the navigation bar so the sheet says which trailer is
    /// playing once the video fills the frame.
    let title: String
    let siteKey: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let url = TrailerRail.embedURL(siteKey: siteKey) {
                    TrailerWebView(url: url)
                } else {
                    unavailableState
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .tint(.continuumOnSurface)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
    }

    private var unavailableState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(Color.continuumOnSurface.opacity(0.4))
            Text("This trailer can't be played.")
                .font(.continuumCaption)
                .foregroundStyle(Color.continuumSecondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Minimal `WKWebView` host. Configured before the view exists because
/// `allowsInlineMediaPlayback` and the user-action requirement are read from
/// the configuration at init time and are not settable afterwards.
private struct TrailerWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        // Empty set == no user gesture required, so the embed's `autoplay=1`
        // is honored instead of leaving a poster frame the user must tap.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        // The embed is exactly one video; scrolling it only reveals letterbox.
        webView.scrollView.isScrollEnabled = false
        webView.allowsBackForwardNavigationGestures = false
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // The sheet is keyed on the site key, so the URL never changes for a
        // live view; reload only if it somehow does.
        guard uiView.url != url, !uiView.isLoading else { return }
        uiView.load(URLRequest(url: url))
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) {
        // Stop the audio immediately on dismiss — a deallocating web view
        // can otherwise keep playing for a beat after the sheet is gone.
        uiView.stopLoading()
        if let blank = URL(string: "about:blank") {
            uiView.load(URLRequest(url: blank))
        }
    }
}
#endif

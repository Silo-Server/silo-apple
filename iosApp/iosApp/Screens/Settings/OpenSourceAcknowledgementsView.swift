import Foundation
import SwiftUI

enum OpenSourceAcknowledgements {
    struct Resource: Sendable {
        let title: String
        let name: String
    }

    static let resources: [Resource] = [
        Resource(title: "Overview and provenance", name: "README"),
        Resource(
            title: "AetherEngine — LGPL 3 and Apple Store / DRM Exception",
            name: "AetherEngine-LGPL-3.0-App-Store-Exception"
        ),
        Resource(title: "GNU General Public License version 3", name: "GPL-3.0"),
        Resource(title: "FFmpegBuild and FFmpeg — LGPL 2.1", name: "FFmpegBuild-LGPL-2.1"),
        Resource(title: "dav1d — BSD 2-Clause", name: "dav1d-BSD-2-Clause"),
        Resource(title: "zimg — WTFPL version 2", name: "zimg-WTFPL"),
        Resource(title: "libzvbi ure.c — MIT", name: "libzvbi-ure-MIT"),
        Resource(title: "LibDovi packaging — MIT", name: "LibDovi-Packaging-MIT"),
        Resource(title: "libdovi — MIT", name: "libdovi-MIT"),
        Resource(title: "Nuke and NukeUI — MIT", name: "Nuke-MIT"),
        Resource(title: "ThumbHash decoder — MIT", name: "ThumbHash-MIT"),
    ]

    static let text: String = resources.map { resource in
        let body: String
        if let url = resourceURL(named: resource.name),
           let contents = try? String(contentsOf: url, encoding: .utf8) {
            body = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            body = "The bundled license resource \(resource.name).txt is unavailable."
        }

        return "\(resource.title)\n\(String(repeating: "=", count: resource.title.count))\n\n\(body)"
    }
    .joined(separator: "\n\n\n")

    private static func resourceURL(named name: String) -> URL? {
        Bundle.main.url(
            forResource: name,
            withExtension: "txt",
            subdirectory: "OpenSourceLicenses"
        ) ?? Bundle.main.url(forResource: name, withExtension: "txt")
    }
}

struct OpenSourceAcknowledgementsView: View {
    var body: some View {
        ScrollView {
            Text(OpenSourceAcknowledgements.text)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Color.continuumOnSurface)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                #if !os(tvOS)
                .textSelection(.enabled)
                #endif
        }
        .background(Color.continuumBackground)
        .navigationTitle("Open Source Licenses")
        .continuumNavigationTitleDisplayMode(.inline)
        .continuumToolbarColorSchemeDark()
    }
}

#if os(tvOS)
struct TVOpenSourceAcknowledgementsOverlay: View {
    let dismiss: () -> Void

    @FocusState private var focusedElement: FocusedElement?

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("OPEN SOURCE")
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .tracking(2)
                            .foregroundStyle(Color.continuumAccent)

                        Text("Licenses & Acknowledgements")
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundStyle(Color.continuumOnSurface)
                    }

                    Spacer(minLength: 40)

                    Button("Done", action: dismiss)
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: 210)
                        .buttonStyle(TVSettingsPaneRowStyle())
                        .focused($focusedElement, equals: .done)
                }

                ScrollView(.vertical) {
                    Text(OpenSourceAcknowledgements.text)
                        .font(.system(size: 20, design: .monospaced))
                        .foregroundStyle(Color.continuumOnSurface)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .focusable()
                .focused($focusedElement, equals: .document)
                .accessibilityLabel("Open-source licenses and acknowledgements")
            }
            .padding(40)
            .frame(maxWidth: 1500, maxHeight: 900, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(Color.continuumSurfaceElevated)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .strokeBorder(Color.continuumChromeRestingBorder, lineWidth: 1)
            }
            .focusSection()
            .defaultFocus($focusedElement, .document, priority: .userInitiated)
        }
        .onAppear { focusedElement = .document }
        .onExitCommand(perform: dismiss)
    }

    private enum FocusedElement: Hashable {
        case document
        case done
    }
}
#endif

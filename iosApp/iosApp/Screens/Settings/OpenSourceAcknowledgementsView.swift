import Foundation
import SwiftUI

enum OpenSourceAcknowledgements {
    struct Resource: Sendable {
        let title: String
        let name: String
        var fileExtension: String? = "txt"
    }

    /// The AGPL's "Appropriate Legal Notices" for Silo itself: copyright, no
    /// warranty, the license and its additional permission, and where the
    /// source is published (this build's archive when a release lane stamped it).
    static let siloNotice = """
    Copyright (C) 2026 Silo Media L.L.C. and contributors.

    Silo is free software: you can redistribute it and/or modify it under the \
    terms of the GNU Affero General Public License as published by the Free \
    Software Foundation, either version 3 of the License, or (at your option) \
    any later version, with the additional permission for app store \
    distribution reproduced below.

    Silo is distributed in the hope that it will be useful, but WITHOUT ANY \
    WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS \
    FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License below \
    for more details.

    Source code: \(SiloLegalLinks.sourceCode.absoluteString)

    The Silo name, logo, and wordmark are trademarks of Silo Media L.L.C. and \
    are not licensed under the AGPL.

    \(TMDBAttributionNotice.text)
    """

    /// The first two resources are the repository's own LICENSE and
    /// APPSTORE-EXCEPTION.md, copied into the bundle by project.yml.
    static let resources: [Resource] = [
        Resource(title: "GNU Affero General Public License version 3", name: "LICENSE", fileExtension: nil),
        Resource(title: "Silo Apple App Store / DRM Exception", name: "APPSTORE-EXCEPTION", fileExtension: "md"),
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
        Resource(title: "SiloObjectAudio and truehd — Apache 2.0", name: "SiloObjectAudio-Apache-2.0"),
        Resource(title: "Nuke and NukeUI — MIT", name: "Nuke-MIT"),
        Resource(title: "SwiftAssRenderer — MIT", name: "SwiftAssRenderer-MIT"),
        Resource(title: "SwiftLibass — MIT", name: "SwiftLibass-MIT"),
        Resource(title: "Combine Schedulers — MIT", name: "combine-schedulers-MIT"),
        Resource(title: "Concurrency Extras — MIT", name: "swift-concurrency-extras-MIT"),
        Resource(title: "Issue Reporting — MIT", name: "swift-issue-reporting-MIT"),
        Resource(title: "libass — ISC", name: "libass-ISC"),
        Resource(title: "Fontconfig", name: "Fontconfig"),
        Resource(title: "FreeType — FreeType License", name: "FreeType"),
        Resource(title: "FriBidi — LGPL 2.1", name: "FriBidi-LGPL-2.1"),
        Resource(title: "HarfBuzz", name: "HarfBuzz"),
        Resource(title: "libpng", name: "libpng"),
        Resource(title: "ThumbHash decoder — MIT", name: "ThumbHash-MIT"),
        Resource(title: "Go Noto Current font — SIL Open Font License 1.1", name: "GoNoto-OFL-1.1"),
        Resource(title: "DiceBear avatar styles — artwork credits", name: "DiceBear-Avatar-Styles"),
    ]

    /// One titled license text per resource.
    struct Entry: Identifiable, Sendable {
        let id: String
        let text: String
    }

    /// Silo's own notice first, then the resources in order.
    static let entries: [Entry] = [Entry(id: "Silo", text: "Silo\n====\n\n\(siloNotice)")] + resourceEntries

    private static let resourceEntries: [Entry] = resources.map { resource in
        let body: String
        if let url = resourceURL(for: resource),
           let contents = try? String(contentsOf: url, encoding: .utf8) {
            body = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let file = [resource.name, resource.fileExtension].compactMap { $0 }.joined(separator: ".")
            body = "The bundled license resource \(file) is unavailable."
        }

        return Entry(
            id: resource.name,
            text: "\(resource.title)\n\(String(repeating: "=", count: resource.title.count))\n\n\(body)"
        )
    }

    #if os(tvOS)
    static let text: String = entries.map(\.text).joined(separator: "\n\n\n")
    #endif

    static func resourceURL(for resource: Resource) -> URL? {
        Bundle.main.url(
            forResource: resource.name,
            withExtension: resource.fileExtension,
            subdirectory: "OpenSourceLicenses"
        ) ?? Bundle.main.url(forResource: resource.name, withExtension: resource.fileExtension)
    }
}

struct OpenSourceAcknowledgementsView: View {
    var body: some View {
        ScrollView {
            // One Text per license, laid out lazily: a single Text of every
            // bundled license would lay out about 150 KB as the page opens.
            LazyVStack(alignment: .leading, spacing: 32) {
                ForEach(OpenSourceAcknowledgements.entries) { entry in
                    Text(entry.text)
                }
            }
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(Color.siloOnSurface)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            #if !os(tvOS)
            .textSelection(.enabled)
            #endif
        }
        .background(Color.siloBackground)
        .navigationTitle("Open Source Licenses")
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
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
                            .foregroundStyle(Color.siloSecondaryText)

                        Text("Licenses & Acknowledgements")
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundStyle(Color.siloOnSurface)
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
                        .foregroundStyle(Color.siloOnSurface)
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
                    .fill(Color.siloSurfaceElevated)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .strokeBorder(Color.siloChromeRestingBorder, lineWidth: 1)
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

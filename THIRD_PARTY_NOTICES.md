# Third-Party Notices and Media Binary Provenance

This file describes third-party code shipped by the installable Silo Apple
applications. Build and release tools that do not ship in an application
bundle are outside its scope. Complete license texts are committed under
`iosApp/Resources/OpenSourceLicenses/`. The shared resource source configures
them for the iOS, tvOS, and macOS applications, with a local reader at
Settings > About > Open Source Licenses. Generated-project and built-bundle
verification is still required.

The authoritative dependency lock is
`iosApp/Silo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

## Shipped package products

| Component | Exact revision | Shipped form | License |
| --- | --- | --- | --- |
| AetherEngine 6.34.0 | `0ae80496ab6f3fda135f43ef195ff10961c0e625` | Swift package target linked into each host app | LGPL-3.0-only with AetherEngine's Apple Store / DRM exception |
| FFmpegBuild 2.4.3 | `b2185fa842b829cd53d182a5e9a53182c1d9c84c` | Nine separately embedded dynamic frameworks | See the component table below |
| LibDovi 2.0.0 | `89be93431c2a5f2e54fb77e93059071b8d2ddb3a` | Static `Dovi.xcframework` linked through AetherEngine | MIT packaging; embedded libdovi is MIT |
| Nuke and NukeUI 12.9.0 | `83e19143355b02e9261edb2323b3e1e93287ebb9` | Swift package targets linked into each host app | MIT |

SwiftPM also resolves SMBClient 0.3.1 because AetherEngine publishes an
optional `AetherEngineSMB` product. Silo depends only on the `AetherEngine`
product. `AetherEngineSMB` and SMBClient are not linked or copied into Silo's
app targets, so SMBClient is not a shipped component and its notice is not
included here.

## AetherEngine

Copyright (C) 2026 Vincent Herbst.

AetherEngine is licensed under GNU LGPL version 3 with its upstream Apple
Store / DRM exception. Silo uses the source unmodified at the exact revision
above. The bundled acknowledgements include AetherEngine's complete license
and exception plus the GNU GPL version 3 text incorporated by LGPLv3.

- Exact source: <https://github.com/superuser404notfound/AetherEngine/tree/0ae80496ab6f3fda135f43ef195ff10961c0e625>
- Rebuild input: `Package.swift` and the source tree at that revision
- Bundled texts: `AetherEngine-LGPL-3.0-App-Store-Exception.txt`,
  `GPL-3.0.txt`

The exception permits Apple App Store and TestFlight distribution despite
store signing, DRM, and relinking restrictions. It does not waive source-code
obligations. A release therefore still needs an immutable corresponding-source
record for the exact Aether revision and any downstream modifications.

## FFmpegBuild and its component libraries

AetherEngine's `AetherEngine` product depends on FFmpegBuild's umbrella
product. The resolved FFmpegBuild manifest links all of these as separate
dynamic frameworks:

| Frameworks | Upstream input | License |
| --- | --- | --- |
| Libavcodec, Libavformat, Libavutil, Libswresample, Libswscale, Libavfilter | FFmpeg `n8.1.2` (currently `38b88335f99e76ed89ff3c93f877fdefce736c13`) | LGPL-2.1-or-later |
| Libdav1d | dav1d `1.5.1` (currently `42b2b24fb8819f1ed3643aa9cf2a62f03868e3aa`) | BSD-2-Clause |
| Libzimg | zimg `release-3.0.5` (currently `e5b0de6bebbcbc66732ed5afaafef6b2c7dfef87`) | WTFPL-2.0 |
| Libzvbi | libzvbi `v0.2.44` (currently `5169a428d51c3ae8ff7b0897e8a687d8e05e37b5`) | LGPL-2.0-or-later, conveyed under LGPL-2.1; `src/ure.c` is MIT |

The exact FFmpegBuild 2.4.3 `build.sh` is the rebuild recipe and patch record:

- it builds FFmpeg with dynamic linkage and does not enable GPL, version-3,
  or nonfree FFmpeg components;
- it removes libzvbi's three GPL-family source files (`packet-830.c`, `pdc.c`,
  and `exp-vtx.c`) before compilation and publishes the LGPL replacement stubs;
- it records its FFmpeg, dav1d, zimg, and libzvbi tags and every downstream
  patch applied to those sources.

The commit IDs in the table are the tags' dereferenced values observed on
2026-08-22. FFmpegBuild's script records tag names rather than immutable
upstream commit IDs, and its prebuilt binaries do not carry a source-lock
manifest. The packaging revision therefore pins the exact shipped binary bytes
but does not independently prove the upstream commit IDs used when those bytes
were built. This is a remaining provenance gate: archive the corresponding
source used for the release or reproducibly rebuild from audited immutable
commits before external distribution.

The checked iOS debug app embeds exactly the nine frameworks in the table,
and its FFmpeg configure strings contain `--enable-shared` without
`--enable-gpl`, `--enable-version3`, or nonfree enablement. Repeat this
inventory against each release archive; debug evidence is not a release
substitute.

- Exact packaging source and rebuild script:
  <https://github.com/superuser404notfound/FFmpegBuild/tree/b2185fa842b829cd53d182a5e9a53182c1d9c84c>
- Current upstream tag resolutions:
  [FFmpeg](https://github.com/FFmpeg/FFmpeg/tree/38b88335f99e76ed89ff3c93f877fdefce736c13),
  [dav1d](https://code.videolan.org/videolan/dav1d/-/tree/42b2b24fb8819f1ed3643aa9cf2a62f03868e3aa),
  [zimg](https://github.com/sekrit-twc/zimg/tree/e5b0de6bebbcbc66732ed5afaafef6b2c7dfef87),
  and [libzvbi](https://github.com/zapping-vbi/zvbi/tree/5169a428d51c3ae8ff7b0897e8a687d8e05e37b5)
- Bundled texts: `FFmpegBuild-LGPL-2.1.txt`,
  `dav1d-BSD-2-Clause.txt`, `zimg-WTFPL.txt`, `libzvbi-ure-MIT.txt`

No GPL-licensed FFmpeg or libzvbi object is expected in this package. That is
an evidence statement about this pinned build recipe and inspected binary, not
a substitute for a final release archive scan.

## LibDovi and libdovi

LibDovi's packaging and rebuild script are MIT licensed, Copyright (c) 2026
Vincent Herbst. Its `Dovi.xcframework` contains the static `dolby_vision`
3.3.2 crate built from dovi_tool tag `libdovi-3.3.2`, exact upstream revision
`4fd2b2235c9f93582dd4a00e65ee34a07800afd7`, under the MIT license,
Copyright (c) 2025 quietvoid.

As with FFmpegBuild, LibDovi's rebuild script clones the tag name rather than
an immutable commit. The commit above is the tag's value observed on
2026-08-22; preserve the actual release source alongside the static library.
LibDovi's packaging `LICENSE` describes the embedded crate as dual MIT or
Apache-2.0, but the exact `libdovi-3.3.2` source's `LICENSE` and Cargo manifest
declare MIT. The bundled files reproduce the packaging license unmodified and
also include quietvoid's controlling MIT text; this notice uses MIT for the
embedded crate.

- Exact packaging source and rebuild script:
  <https://github.com/superuser404notfound/LibDovi/tree/89be93431c2a5f2e54fb77e93059071b8d2ddb3a>
- Exact embedded crate source:
  <https://github.com/quietvoid/dovi_tool/tree/4fd2b2235c9f93582dd4a00e65ee34a07800afd7/dolby_vision>
- Bundled texts: `LibDovi-Packaging-MIT.txt`, `libdovi-MIT.txt`

## Nuke and NukeUI

Nuke and NukeUI are distributed under the MIT license, Copyright (c)
2015-2026 Alexander Grebenyuk.

- Exact source:
  <https://github.com/kean/Nuke/tree/83e19143355b02e9261edb2323b3e1e93287ebb9>
- Bundled text: `Nuke-MIT.txt`

## External-distribution gate

Bundling notices and license texts is necessary but is not, by itself, the
complete LGPL distribution process. Before App Store, TestFlight, or other
external distribution, release engineering must:

1. archive the exact resolved manifests, source trees, patches, build scripts,
   and release-binary inventory together under a durable retrieval location;
2. verify the archive embeds the FFmpegBuild libraries as replaceable dynamic
   frameworks and does not merge or statically link them into the app binary;
3. publish the corresponding-source location or a license-compliant written
   source offer with the distributed build and retain it for the required
   period;
4. publish any AetherEngine or LGPL-component modifications under the
   applicable license;
5. obtain legal approval that the final distribution channel's signing, DRM,
   and terms are compatible with FFmpeg/libzvbi's unexcepted LGPL-2.x terms.

Until those release-specific steps are complete, this provenance work supports
internal builds but does not claim that an external binary is legally cleared.

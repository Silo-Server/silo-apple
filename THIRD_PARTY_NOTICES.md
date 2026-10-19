# Third-Party Notices and Media Binary Provenance

This file describes third-party code shipped by the installable Silo Apple
applications. Build and release tools that do not ship in an application
bundle are outside its scope. Complete license texts are committed under
`iosApp/Resources/OpenSourceLicenses/`. The shared resource source configures
them for the iOS, tvOS, and macOS applications, with a local reader under
Settings > About > Acknowledgements. That reader opens with Silo's own AGPL
notice, `LICENSE`, and `APPSTORE-EXCEPTION.md`, and links the build's source
archive when a release lane stamped one (`SiloSourceURL`). Generated-project
and built-bundle verification is still required.

The authoritative dependency lock is
`iosApp/Silo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

## Shipped package products

| Component | Exact revision | Shipped form | License |
| --- | --- | --- | --- |
| AetherEngine 7.40.1 + Silo subtitle, HLS authorization and playback recovery patches, object-audio traits on | `185be1f52486f548086b4c0f5e70624885056e74` | Swift package target linked into each host app | LGPL-3.0-only with AetherEngine's Apple Store / DRM exception |
| FFmpegBuild 3.7.1 | `013c48bd4d3073428f31cade039ec4ed958d0ceb` | Nine separately embedded dynamic frameworks | See the component table below |
| LibTrueHD 3.0.0 | `aebd5ffe1046dadbea833ce87a75d00fd8b1edd1` | Static `TrueHD.xcframework` linked through AetherEngine | MIT; embedded `truehd` and `oamd` crates are Apache-2.0 |
| LibDTSX 3.0.0 | `7d68c8bbda348a10e169b9bb9619c8b2b7a0c642` | Dynamic `DTSX.framework` embedded in each app | Built library LGPL-3.0-or-later (its `dca` decoder is a port of FFmpeg's); LibDTSX source Apache-2.0 |
| LibDovi 2.1.0 | `0d7cce1d6836a30d13a3a2326e50a153af53f014` | Static `Dovi.xcframework` linked through AetherEngine | MIT packaging; embedded libdovi is MIT |
| Nuke and NukeUI 13.2.0 | `30f7a7e72e0607d304fbf69c799474bd5fb6d1ce` | Swift package targets linked into each host app | MIT |

SwiftPM also resolves SMBClient 0.3.1 because AetherEngine publishes an
optional `AetherEngineSMB` product. Silo depends only on the `AetherEngine`
product. `AetherEngineSMB` and SMBClient are not linked or copied into Silo's
app targets, so SMBClient is not a shipped component and its notice is not
included here.

## AetherEngine

Copyright (C) 2026 Vincent Herbst.

AetherEngine is licensed under GNU LGPL version 3 with its upstream Apple
Store / DRM exception. Silo builds a published fork revision: upstream release
`7.40.1` (upstream commit `93d54e50`), plus Silo patches for complete native subtitle
renditions, source timing after a media reanchor, ASS subtitle routing, refreshable
authorization for native HLS, sidecar subtitles and font bundles, and audio-switch
tracking. Upstream compiles TrueHD Atmos and DTS:X object rendering only for a host
that enables its `TrueHDObjectAudio` and `DTSXObjectAudio` package traits, noting that
those components may need third-party patent licenses. The Silo fork turns those two
traits on by default, so LibTrueHD and LibDTSX are linked and the Playback setting can
deliver TrueHD Atmos and DTS:X heights as Apple Positional Audio. The Profile 7
dual-layer and Profile 5 still components stay off. Raw ASS events stay on the
primary local overlay; secondary subtitles and software PiP receive normalized
text, and packaged HLS retains
its native text rendition for PiP and AirPlay. These modifications are
published under the LGPL at the exact source revision below. The bundled
acknowledgements include AetherEngine's complete license and exception plus
the GNU GPL version 3 text incorporated by LGPLv3.

- Exact source: <https://github.com/Silo-Server/AetherEngine/tree/185be1f52486f548086b4c0f5e70624885056e74>
  (engine pull requests: <https://github.com/Silo-Server/AetherEngine/pull/2>,
  <https://github.com/Silo-Server/AetherEngine/pull/6>,
  <https://github.com/Silo-Server/AetherEngine/pull/15>,
  <https://github.com/Silo-Server/AetherEngine/pull/16>,
  <https://github.com/Silo-Server/AetherEngine/pull/17>,
  <https://github.com/Silo-Server/AetherEngine/pull/18>,
  <https://github.com/Silo-Server/AetherEngine/pull/20>,
  <https://github.com/Silo-Server/AetherEngine/pull/21>,
  <https://github.com/Silo-Server/AetherEngine/pull/22>,
  <https://github.com/Silo-Server/AetherEngine/pull/23>,
  <https://github.com/Silo-Server/AetherEngine/pull/24>)
- Upstream base: <https://github.com/superuser404notfound/AetherEngine/tree/93d54e5067ca0ad856259c0ebc1693aeafa20677>
- Rebuild input: `Package.swift` and the source tree at that revision
- Bundled texts: `AetherEngine-LGPL-3.0-App-Store-Exception.txt`,
  `GPL-3.0.txt`

The exception permits Apple App Store and TestFlight distribution despite
store signing, DRM, and relinking restrictions. It does not waive source-code
obligations: the exact-revision link above must stay current for each release,
and any downstream modifications must be published under the LGPL. The exact
source revision linked above is that publication; keep it public for as long
as builds that link this revision are distributed.

## FFmpegBuild and its component libraries

AetherEngine's `AetherEngine` product depends on FFmpegBuild's umbrella
product. The resolved FFmpegBuild manifest links all of these as separate
dynamic frameworks:

| Frameworks | Upstream input | License |
| --- | --- | --- |
| AetherLibavcodec, AetherLibavformat, AetherLibavutil, AetherLibswresample, AetherLibswscale, AetherLibavfilter | FFmpeg `n8.1.3` (currently `1041abdc962f4cc4f394aa8de9dc5236c0c3b9e7`) | LGPL-2.1-or-later |
| AetherLibdav1d | dav1d `1.5.4` (currently `54706fc6bc0cdecab7e9593974a4039cc038fca7`) | BSD-2-Clause |
| AetherLibzimg | zimg `release-3.0.6` (currently `f819b14e8f39d1282400b0d9543e8ef73c1b2bbd`) | WTFPL-2.0 |
| AetherLibzvbi | libzvbi `v0.2.45` (currently `d3a5ee9f2b047bf16cd1ee5ccf6ec05ee75409d0`) | LGPL-2.0-or-later, conveyed under LGPL-2.1; `src/ure.c` is MIT |

FFmpegBuild 3.0.0 renamed every target, framework bundle, and install name
with an `Aether` prefix so the build can coexist with another FFmpeg in the
same app. Earlier releases added WMV/ASF and legacy Flash support, the VC-1
parser repair for seeking, and dSYMs for crash symbolication. 3.4.0 added FFmpeg
support for the `dav1` (Dolby Vision AV1) MP4 sample entry. 3.5.0 moved to FFmpeg
`n8.1.3`, and 3.6.0 enabled the `dts`, `truehd` and `loas` raw demuxers and added a
local patch that probes the payload of an MPEG-TS audio PID labelled MPEG-1 audio.
3.7.0 patches the mp4 muxer's `dec3` box so an E-AC-3 track that carries its height
channels and Atmos objects in a dependent substream keeps them, and the pinned 3.7.1
release patches the mp4 muxer so a packet still queued behind a fragment's written
samples cannot end that fragment's track early. Both releases keep FFmpeg `n8.1.3`
and the same component set. The exact FFmpegBuild 3.7.1 `build.sh` is the rebuild
recipe and patch record:

- it builds FFmpeg with dynamic linkage and does not enable GPL, version-3,
  or nonfree FFmpeg components;
- it removes libzvbi's three GPL-family source files (`packet-830.c`, `pdc.c`,
  and `exp-vtx.c`) before compilation and publishes the LGPL replacement stubs;
- it records its FFmpeg, dav1d, zimg, and libzvbi tags and every downstream
  patch applied to those sources;
- it does not build the FFmpeg `concat` demuxer, which 2.5.0 removed.

libzvbi 0.2.45 is the GHSA-86rm-g7qf-j2fh security update (out-of-bounds
read, out-of-bounds write, integer underflow reachable through the teletext
decoder). The commit IDs in the table are the tags' dereferenced values
observed on 2026-09-04 (FFmpeg `n8.1.3` on 2026-10-09). FFmpegBuild's script records tag names rather than immutable
upstream commit IDs; recording the dereferenced commits here pins them if the
tags ever move. Forking the pinned FFmpegBuild revision is cheap,
commit-immutable insurance if stronger provenance is ever wanted, but the
exact-revision links satisfy the source pointer as they stand.

Historical binary inventory (FFmpegBuild 3.0.0): a tvOS Simulator debug build,
inspected on 2026-09-04, embedded exactly the nine `Aether`-prefixed frameworks
in the table under `SiloTV.app/Frameworks/`. Its `AetherLibavcodec` configure
string contained `--enable-shared` without `--enable-gpl`, `--enable-version3`, or
nonfree enablement, and the app binary exported no `avcodec_`/`avformat_`
symbols of its own. These observations describe that older debug artifact;
they are not a binary inventory of the current 3.7.1 dependency. Repeat this
inventory against each release archive; debug evidence is not a release substitute.

- Exact packaging source and rebuild script:
  <https://github.com/superuser404notfound/FFmpegBuild/tree/013c48bd4d3073428f31cade039ec4ed958d0ceb>
- Current upstream tag resolutions:
  [FFmpeg](https://github.com/FFmpeg/FFmpeg/tree/1041abdc962f4cc4f394aa8de9dc5236c0c3b9e7),
  [dav1d](https://code.videolan.org/videolan/dav1d/-/tree/54706fc6bc0cdecab7e9593974a4039cc038fca7),
  [zimg](https://github.com/sekrit-twc/zimg/tree/f819b14e8f39d1282400b0d9543e8ef73c1b2bbd),
  and [libzvbi](https://github.com/zapping-vbi/zvbi/tree/d3a5ee9f2b047bf16cd1ee5ccf6ec05ee75409d0)
- Bundled texts: `FFmpegBuild-LGPL-2.1.txt`,
  `dav1d-BSD-2-Clause.txt`, `zimg-WTFPL.txt`, `libzvbi-ure-MIT.txt`

No GPL-licensed FFmpeg or libzvbi object is expected in this package. That is
an evidence statement about this pinned build recipe and inspected binary, not
a substitute for a final release archive scan.

## LibDovi and libdovi

LibDovi's packaging and rebuild script are MIT licensed, Copyright (c) 2026
Vincent Herbst. Its `Dovi.xcframework` contains the static `dolby_vision`
3.4.0 crate built from dovi_tool tag `libdovi-3.4.0`, exact upstream revision
`d1abe0e27ff2c7ab3339614d06db9f8a058af6b2`, under the MIT license,
Copyright (c) 2026 quietvoid.

As with FFmpegBuild, LibDovi's rebuild script clones the tag name rather than
an immutable commit. The commit above is the tag's value observed on
2026-09-04; preserve the actual release source alongside the static library.
LibDovi's packaging `LICENSE` describes the embedded crate as dual MIT or
Apache-2.0, but the exact `libdovi-3.4.0` source's `LICENSE` and Cargo manifest
declare MIT. The bundled files reproduce the packaging license unmodified and
also include quietvoid's controlling MIT text; this notice uses MIT for the
embedded crate.

- Exact packaging source and rebuild script:
  <https://github.com/superuser404notfound/LibDovi/tree/0d7cce1d6836a30d13a3a2326e50a153af53f014>
- Exact embedded crate source:
  <https://github.com/quietvoid/dovi_tool/tree/d1abe0e27ff2c7ab3339614d06db9f8a058af6b2/dolby_vision>
- Bundled texts: `LibDovi-Packaging-MIT.txt`, `libdovi-MIT.txt`

## LibTrueHD and truehd

LibTrueHD is the TrueHD and Dolby Atmos decoder library Silo wrote as SiloObjectAudio
and transferred to AetherEngine's maintainer, who renamed it for release 2.0.0. Its C
API, access-unit framer, and build and verification scripts are MIT licensed,
Copyright (c) 2026 Quick104, with packaging changes since 2.0.0 Copyright (c) 2026
Vincent Herbst. Its static `TrueHD.xcframework` contains the `truehd` crate (TrueHD/MLP
decoder) from the truehdd project, Copyright Rainbaby and the truehdd contributors,
built from the exact commit `33bae1657ceb25b5fe0347f42c544c3414e2760e` (upstream
`02d29cd0` with harletty's performance changes and a build feature that discards matrix
interpolation values), and the `oamd` crate 0.1.0 (object audio metadata), Copyright
Rainbaby, both under the Apache License 2.0. It also compiles in the Rust standard
library and the crates its NOTICE lists, each under the MIT license or the Apache
License 2.0. The bundled texts reproduce LibTrueHD's MIT license, its NOTICE, and the
Apache License.

- Exact source and rebuild script:
  <https://github.com/superuser404notfound/LibTrueHD/tree/aebd5ffe1046dadbea833ce87a75d00fd8b1edd1>
- Embedded decoder source: <https://github.com/superuser404notfound/truehdd/tree/33bae1657ceb25b5fe0347f42c544c3414e2760e>
- Embedded metadata parser source: <https://crates.io/crates/oamd/0.1.0>
- Bundled texts: `LibTrueHD-MIT.txt`, `truehd-Apache-2.0.txt`

## LibDTSX and dca

LibDTSX is the DTS:X decoder AetherEngine uses for DTS:X heights. Its C API, DTS:X
reconstruction and Apple packaging are Apache-2.0, Copyright 2026 kristofferR. The
built library compiles in, unmodified, the `dca` crate 0.8.0 from the harletty-bridge
project at the exact commit `a717bae441b116485f0254603dc20a6ede65d8c6`. That crate is
labelled Apache-2.0 but is a port of FFmpeg's LGPL-2.1-or-later `dca` decoder, so the
built library is distributed under the GNU LGPL version 3 or later. It ships as the
dynamic `DTSX.framework`, embedded in each app beside the FFmpeg frameworks, so a user
can replace it with a modified version. It also compiles in the Rust standard library
and the crates its NOTICE lists, each under the MIT license or the Apache License 2.0.
The bundled text reproduces LibDTSX's NOTICE, the LGPL version 3 and LibDTSX's Apache
License; the GPL version 3 that LGPLv3 incorporates and the LGPL 2.1 FFmpeg grants are
bundled with AetherEngine and FFmpegBuild.

- Exact source and rebuild script (corresponding source with the `dca` commit above):
  <https://github.com/superuser404notfound/LibDTSX/tree/7d68c8bbda348a10e169b9bb9619c8b2b7a0c642>
- Embedded decoder source: <https://github.com/harletty/harletty-bridge/tree/a717bae441b116485f0254603dc20a6ede65d8c6/dca>
- Bundled text: `LibDTSX-LGPL-3.0.txt`

## Nuke and NukeUI

Nuke and NukeUI are distributed under the MIT license, Copyright (c)
2015-2026 Alexander Grebenyuk.

- Exact source:
  <https://github.com/kean/Nuke/tree/30f7a7e72e0607d304fbf69c799474bd5fb6d1ce>
- Bundled text: `Nuke-MIT.txt`

## ThumbHash decoder

Silo includes an adapted copy of the ThumbHash Swift decoder, distributed
under the MIT license, Copyright (c) 2023 Evan Wallace. Only the image decode
path is retained; Silo adds bounds validation, cross-platform image creation,
and a bounded asynchronous cache around the reference algorithm.

- Exact source:
  <https://github.com/evanw/thumbhash/tree/a652ce6ed691242f459f468f0a8756cda3b90a82>
- Bundled text: `ThumbHash-MIT.txt`

## Runtime attributions

These services are not shipped in the app bundle, but the app shows their
data or artwork. Settings > About > Acknowledgements lists each one from
`ThirdPartyCredits.swift`; add an entry there when the app starts showing
another service.

- TMDB: rating badges and Requests artwork come from TMDB. Its API terms
  require the TMDB logo and the notice "This application uses TMDB and the
  TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB."
  in an About or Credits section. The logo's provenance is in
  `iosApp/iosApp/ThirdPartyLogos.xcassets/README.md`.
- DiceBear: profile avatar presets load from the DiceBear HTTP API. The
  default Fun Emoji style is a remix of Davis Uche's Fun Emoji Set under
  CC BY 4.0, which requires credit.

## Release checklist

The dynamically embedded FFmpeg libraries and the statically linked SwiftLibass
libraries use different rebuild paths. Before App Store, TestFlight, or other
external distribution:

1. verify the release archive embeds the FFmpegBuild libraries as separate
   dynamic frameworks and does not merge or statically link them into the app
   binary (the debug-build inventory above is not a release substitute);
2. confirm the revisions in this file and in the bundled acknowledgements
   match what the release actually resolves in `Package.resolved`;
3. if AetherEngine or any LGPL component was modified, publish the modified
   source under its license before shipping;
4. publish the matching `Silo-source-<app-commit>.tar.gz` archive, with the app
   source, pinned Swift packages, SwiftLibass dependency sources, revision manifest,
   and rebuild instructions, before distributing a binary that links SwiftLibass.

## Local ASS rendering

Silo uses SwiftLibass 1.4.0 for libass bindings and SwiftAssRenderer 1.3.1
for image compositing on all three Apple clients. Both Swift packages are MIT.
The native libraries are libass 0.17.3 (ISC), Fontconfig 2.15.0, FreeType 2.13.2
(FreeType License), FriBidi 1.0.14 (LGPL-2.1-or-later), HarfBuzz 8.5.0, and
libpng 1.6.43. Their full notices are bundled in `OpenSourceLicenses/`.
This product uses the FreeType project.

The native XCFrameworks contain static `.a` libraries and headers. Silo links
the libraries without embedding subtitle framework wrappers or generated stubs.

- SwiftAssRenderer source: <https://github.com/mihai8804858/swift-ass-renderer/tree/28919f6b5ddd896d327b0283f8d97624902236e6>
- SwiftLibass source and binary artifacts: <https://github.com/mihai8804858/swift-libass/tree/6513c488e377a26c06db327fb2acfc2653a041d5>
- Rebuild entry point: `build-libraries.sh` at that revision.
- Transitive Swift dependencies: Combine Schedulers 1.2.2, Concurrency Extras
  1.4.1, and IssueReporting from xctest-dynamic-overlay 1.13.1, all MIT; exact revisions are in
  `Package.resolved` and their notices are bundled.
- The test-only `SiloASSFixture.ttf` is an original rectangular glyph
  generated by `iosApp/Tests/Fixtures/ASS/generate-font.py`; it is not shipped
  in the application.

### Source-based relinking

FriBidi is statically linked. LGPL 2.1 section 6(a) allows the work that uses
the library to be supplied as source code or object code so a recipient can
modify the library and relink the application. Silo uses the source-code path;
the app is distributed under the repository's AGPL license.

The TestFlight and sideload workflows publish a source archive to GitHub
Releases before their binary jobs run. TestFlight builds attach it to their
`vX.Y.Z-beta.B` prerelease and include its URL in the build's What to Test
notes; sideload builds attach it to their `v<version>-build.<run>` release.
Earlier TestFlight builds published it under `source-<app-commit>`.
External local TestFlight uploads require `SILO_RELEASE_SOURCE_URL` to point
to the matching published archive. Other distribution channels must publish
these materials and provide their location alongside the binary as well.

`scripts/ci/package-release-source.py` captures the committed app tree and
every resolved Swift package, plus immutable snapshots of SwiftLibass's six
native libraries recorded in `scripts/ci/swift-libass-sources.json`. The archive
includes a pinned ffmpeg-kit builder and a local build entry point that skips
its destructive checkout step, preserving a recipient's edits. `REBUILD.md`
explains how to build and relink through local package overrides. Signing
credentials and untracked configuration are excluded. `revisions.json` records
source revisions and checksums.

SwiftLibass's upstream script clones an unpinned ffmpeg-kit branch. The builder
and native source tags recorded here match its documented prebuilt versions;
upstream does not publish a manifest establishing byte-for-byte provenance of
those prebuilt libraries. The supplied rebuild inputs are pinned independently.

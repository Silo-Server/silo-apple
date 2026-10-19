Silo Open-Source Acknowledgements
================================

This Silo build includes the components listed below. Their complete license
texts are bundled beside this file and are available from Settings > About >
Acknowledgements.

AetherEngine
  Revision: 185be1f52486f548086b4c0f5e70624885056e74 (upstream release
  7.40.1, upstream commit 93d54e50, plus Silo patches for subtitle renditions,
  source timing, primary ASS routing with normalized secondary/PiP text,
  refreshable authorization for native HLS, sidecar subtitles and fonts,
  dense subtitle catch-up, audio-switch tracking, playback recovery, and
  resuming forward-only sources)
  License: GNU LGPL version 3 with the upstream Apple Store / DRM exception
  Source (modified, as built): https://github.com/Silo-Server/AetherEngine/tree/185be1f52486f548086b4c0f5e70624885056e74
  Upstream base: https://github.com/superuser404notfound/AetherEngine/tree/93d54e5067ca0ad856259c0ebc1693aeafa20677
  Rebuild: the Package.swift and source tree at that revision, with its
  default package traits: TrueHD Atmos and DTS:X object rendering are built;
  Dolby Vision Profile 7 FEL composition and Profile 5 still reshaping are not

FFmpegBuild and embedded media frameworks
  Revision: 013c48bd4d3073428f31cade039ec4ed958d0ceb (release 3.7.1)
  Source and rebuild script: https://github.com/superuser404notfound/FFmpegBuild/tree/013c48bd4d3073428f31cade039ec4ed958d0ceb

  Components built by that revision:
  - FFmpeg n8.1.3, currently 1041abdc962f4cc4f394aa8de9dc5236c0c3b9e7:
    LGPL-2.1-or-later
  - dav1d 1.5.4, currently 54706fc6bc0cdecab7e9593974a4039cc038fca7:
    BSD-2-Clause
  - zimg release-3.0.6, currently
    f819b14e8f39d1282400b0d9543e8ef73c1b2bbd: WTFPL-2.0
  - libzvbi v0.2.45, currently
    d3a5ee9f2b047bf16cd1ee5ccf6ec05ee75409d0: LGPL-2.0-or-later,
    conveyed under LGPL-2.1;
    src/ure.c retains its MIT notice

  The exact build is configured without --enable-gpl, --enable-version3, or
  nonfree components. FFmpegBuild removes the three GPL libzvbi source files
  before compilation and publishes the replacement stubs and patches in its
  build.sh. The app embeds these nine libraries as separate dynamic
  frameworks: AetherLibavcodec, AetherLibavformat, AetherLibavutil,
  AetherLibswresample, AetherLibswscale, AetherLibavfilter, AetherLibdav1d,
  AetherLibzimg, and AetherLibzvbi.

  "Currently" records the tags' dereferenced values observed on 2026-09-04
  (FFmpeg n8.1.3 on 2026-10-09).
  FFmpegBuild's script records tag names rather than immutable upstream
  commit IDs; the dereferenced commits recorded here pin the exact sources if
  those tags ever move.

LibTrueHD / truehd (formerly SiloObjectAudio)
  Revision: aebd5ffe1046dadbea833ce87a75d00fd8b1edd1 (release 3.0.0)
  License: MIT for the C API, framer, and build and verification scripts
  (LibTrueHD-MIT.txt)
  Source and rebuild script: https://github.com/superuser404notfound/LibTrueHD/tree/aebd5ffe1046dadbea833ce87a75d00fd8b1edd1
  Embeds the truehd crate from the truehdd project (Apache-2.0), built from
  https://github.com/superuser404notfound/truehdd at commit
  33bae1657ceb25b5fe0347f42c544c3414e2760e, the oamd crate 0.1.0 from
  crates.io (https://github.com/truehdd/oamd, Apache-2.0), and the Rust
  standard library and crates listed in its NOTICE (MIT or Apache-2.0).
  The NOTICE and the Apache License 2.0 are in truehd-Apache-2.0.txt.

LibDTSX / dca
  Revision: 7d68c8bbda348a10e169b9bb9619c8b2b7a0c642 (release 3.0.0)
  License: LGPL-3.0-or-later for the built DTSX.framework, Apache-2.0 for the
  LibDTSX source (LibDTSX-LGPL-3.0.txt, with its NOTICE)
  Source and rebuild script: https://github.com/superuser404notfound/LibDTSX/tree/7d68c8bbda348a10e169b9bb9619c8b2b7a0c642
  Embeds, unmodified, the dca crate 0.8.0 from
  https://github.com/harletty/harletty-bridge, commit
  a717bae441b116485f0254603dc20a6ede65d8c6, a port of FFmpeg's LGPL-2.1-or-later
  dca decoder, and the Rust standard library and crates listed in its NOTICE
  (MIT or Apache-2.0). It ships as a separate dynamic framework so it can be
  replaced.

LibDovi / libdovi
  Packaging revision: 0d7cce1d6836a30d13a3a2326e50a153af53f014
  (release 2.1.0)
  Packaging license: MIT
  Packaging source and rebuild script: https://github.com/superuser404notfound/LibDovi/tree/0d7cce1d6836a30d13a3a2326e50a153af53f014
  Embedded crate: dolby_vision 3.4.0 from dovi_tool tag libdovi-3.4.0,
  revision d1abe0e27ff2c7ab3339614d06db9f8a058af6b2, under MIT
  Crate source: https://github.com/quietvoid/dovi_tool/tree/d1abe0e27ff2c7ab3339614d06db9f8a058af6b2/dolby_vision
  The build script records the tag name, and the commit above is the tag value
  observed on 2026-09-04; preserve the actual release source with the binary.
  The packaging license calls the crate dual MIT/Apache, while this exact
  crate tag declares MIT in its LICENSE and Cargo manifest. Both the unchanged
  packaging license and quietvoid's controlling MIT text are included here.

Nuke and NukeUI
  Revision: 30f7a7e72e0607d304fbf69c799474bd5fb6d1ce (release 13.2.0)
  License: MIT
  Source: https://github.com/kean/Nuke/tree/30f7a7e72e0607d304fbf69c799474bd5fb6d1ce

ThumbHash decoder
  Revision: a652ce6ed691242f459f468f0a8756cda3b90a82
  License: MIT
  Source: https://github.com/evanw/thumbhash/tree/a652ce6ed691242f459f468f0a8756cda3b90a82
  Silo includes an adapted copy of the reference Swift decode path with input
  validation, cross-platform image creation, and a bounded asynchronous cache.

SMBClient 0.3.1 is present in SwiftPM's resolution graph only because
AetherEngine publishes a separate optional AetherEngineSMB product. Silo links
the AetherEngine product, not AetherEngineSMB, so SMBClient is not included in
these shipped-component notices.

Source availability
-------------------

The links above identify the exact source and rebuild inputs for this build,
including each component's rebuild script and patches at the pinned revision.
They are this build's corresponding-source pointer; keep them matched to the
revisions each release actually resolves.

SwiftAssRenderer, SwiftLibass, and local ASS rendering
  SwiftAssRenderer 1.3.1 (MIT)
  Source: https://github.com/mihai8804858/swift-ass-renderer/tree/28919f6b5ddd896d327b0283f8d97624902236e6
  SwiftLibass 1.4.0 (MIT)
  Source and rebuild script: https://github.com/mihai8804858/swift-libass/tree/6513c488e377a26c06db327fb2acfc2653a041d5
  Transitive Swift packages: Combine Schedulers 1.2.2, Concurrency Extras
  1.4.1, and IssueReporting from xctest-dynamic-overlay 1.13.1, all MIT;
  their notices are included.
  libass 0.17.3: ISC
  Fontconfig 2.15.0: permissive notices in Fontconfig.txt
  FreeType 2.13.2: FreeType License; this product uses the FreeType project
  FriBidi 1.0.14: LGPL-2.1-or-later
  HarfBuzz 8.5.0: notices in HarfBuzz.txt
  libpng 1.6.43: PNG Reference Library License
  Complete license texts are bundled alongside this overview.

  SwiftLibass ships these as static libraries and headers in XCFrameworks.
  It does not embed separate subtitle framework bundles in the application.
  Its upstream builder uses an unpinned ffmpeg-kit checkout. Our source archive
  records a builder revision and native source tags matching its documented
  versions; upstream does not publish byte-for-byte binary build provenance.

  FriBidi is statically linked. App and library source, a revision
  manifest, and instructions for rebuilding with a modified library are
  published as Silo-source-<app-commit>.tar.gz at:
  https://github.com/Silo-Server/silo-apple/releases
  Each TestFlight build places the archive on its vX.Y.Z-beta.<build>
  release (earlier builds used a source-<app-commit> release), and each
  sideload build on its own release. The TestFlight build's
  What to Test notes include the exact archive URL. Builds from the release
  and sideload workflows also show it at the top of these acknowledgements
  and behind Settings > About > Source Code on iPhone and iPad; other builds
  link the repository. No original release signing keys are needed to
  rebuild for a simulator; physical-device builds use the recipient's
  signing identity.

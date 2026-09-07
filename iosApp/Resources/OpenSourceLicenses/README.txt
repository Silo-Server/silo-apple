Silo Open-Source Acknowledgements
================================

This Silo build includes the components listed below. Their complete license
texts are bundled beside this file and are available from Settings > About >
Open Source Licenses.

AetherEngine
  Revision: f8239c206097c88b53492b281af15cf906c8295b (upstream release
  6.67.2 plus Silo patches for native item handover, subtitle renditions,
  source timing, and primary ASS routing with normalized secondary/PiP text)
  License: GNU LGPL version 3 with the upstream Apple Store / DRM exception
  Source (modified, as built): https://github.com/Silo-Server/AetherEngine/tree/f8239c206097c88b53492b281af15cf906c8295b
  Upstream base: https://github.com/superuser404notfound/AetherEngine/tree/6.67.2
  Rebuild: the Package.swift and source tree at that revision

FFmpegBuild and embedded media frameworks
  Revision: 421e13be7061de67d91b85ac34a6b22a002b164f (release 3.0.0)
  Source and rebuild script: https://github.com/superuser404notfound/FFmpegBuild/tree/421e13be7061de67d91b85ac34a6b22a002b164f

  Components built by that revision:
  - FFmpeg n8.1.2, currently 38b88335f99e76ed89ff3c93f877fdefce736c13:
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

  "Currently" records the tags' dereferenced values observed on 2026-09-04.
  FFmpegBuild's script records tag names rather than immutable upstream
  commit IDs; the dereferenced commits recorded here pin the exact sources if
  those tags ever move.

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
  1.4.1, and Issue Reporting 2.1.0, all MIT; their notices are included.
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
  Tagged builds place the archive on their release; manually dispatched
  TestFlight builds use a source-<app-commit> release. The TestFlight build's
  What to Test notes include the exact archive URL. No original release
  signing keys are needed to rebuild for a simulator; physical-device builds
  use the recipient's signing identity.

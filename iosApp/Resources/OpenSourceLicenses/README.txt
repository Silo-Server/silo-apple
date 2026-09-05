Silo Open-Source Acknowledgements
================================

This Silo build includes the components listed below. Their complete license
texts are bundled beside this file and are available from Settings > About >
Open Source Licenses.

AetherEngine
  Revision: 745de1ccdc4b226adccdf18f03a28071f0e972d5 (upstream release
  6.67.2 plus two Silo-published patches that let the host request the
  in-place native item handover on an episode change)
  License: GNU LGPL version 3 with the upstream Apple Store / DRM exception
  Source (modified, as built): https://github.com/Silo-Server/AetherEngine/tree/745de1ccdc4b226adccdf18f03a28071f0e972d5
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

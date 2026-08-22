Silo Open-Source Acknowledgements
================================

This Silo build includes the components listed below. Their complete license
texts are bundled beside this file and are available from Settings > About >
Open Source Licenses.

AetherEngine
  Revision: 0ae80496ab6f3fda135f43ef195ff10961c0e625 (release 6.34.0)
  License: GNU LGPL version 3 with the upstream Apple Store / DRM exception
  Source: https://github.com/superuser404notfound/AetherEngine/tree/0ae80496ab6f3fda135f43ef195ff10961c0e625
  Rebuild: the Package.swift and source tree at that revision

FFmpegBuild and embedded media frameworks
  Revision: b2185fa842b829cd53d182a5e9a53182c1d9c84c (release 2.4.3)
  Source and rebuild script: https://github.com/superuser404notfound/FFmpegBuild/tree/b2185fa842b829cd53d182a5e9a53182c1d9c84c

  Components built by that revision:
  - FFmpeg n8.1.2, currently 38b88335f99e76ed89ff3c93f877fdefce736c13:
    LGPL-2.1-or-later
  - dav1d 1.5.1, currently 42b2b24fb8819f1ed3643aa9cf2a62f03868e3aa:
    BSD-2-Clause
  - zimg release-3.0.5, currently
    e5b0de6bebbcbc66732ed5afaafef6b2c7dfef87: WTFPL-2.0
  - libzvbi v0.2.44, currently
    5169a428d51c3ae8ff7b0897e8a687d8e05e37b5: LGPL-2.0-or-later,
    conveyed under LGPL-2.1;
    src/ure.c retains its MIT notice

  The exact build is configured without --enable-gpl, --enable-version3, or
  nonfree components. FFmpegBuild removes the three GPL libzvbi source files
  before compilation and publishes the replacement stubs and patches in its
  build.sh. The app embeds these nine libraries as separate dynamic
  frameworks: Libavcodec, Libavformat, Libavutil, Libswresample, Libswscale,
  Libavfilter, Libdav1d, Libzimg, and Libzvbi.

  "Currently" records the tags' dereferenced values observed on 2026-08-22.
  FFmpegBuild's script records tag names rather than immutable upstream commit
  IDs, so external release remains blocked until the actual corresponding
  source is archived or the binaries are reproducibly rebuilt from audited
  immutable commits.

LibDovi / libdovi
  Packaging revision: 89be93431c2a5f2e54fb77e93059071b8d2ddb3a
  (release 2.0.0)
  Packaging license: MIT
  Packaging source and rebuild script: https://github.com/superuser404notfound/LibDovi/tree/89be93431c2a5f2e54fb77e93059071b8d2ddb3a
  Embedded crate: dolby_vision 3.3.2 from dovi_tool tag libdovi-3.3.2,
  revision 4fd2b2235c9f93582dd4a00e65ee34a07800afd7, under MIT
  Crate source: https://github.com/quietvoid/dovi_tool/tree/4fd2b2235c9f93582dd4a00e65ee34a07800afd7/dolby_vision
  The build script records the tag name, and the commit above is the tag value
  observed on 2026-08-22; preserve the actual release source with the binary.
  The packaging license calls the crate dual MIT/Apache, while this exact
  crate tag declares MIT in its LICENSE and Cargo manifest. Both the unchanged
  packaging license and quietvoid's controlling MIT text are included here.

Nuke and NukeUI
  Revision: 83e19143355b02e9261edb2323b3e1e93287ebb9 (release 12.9.0)
  License: MIT
  Source: https://github.com/kean/Nuke/tree/83e19143355b02e9261edb2323b3e1e93287ebb9

SMBClient 0.3.1 is present in SwiftPM's resolution graph only because
AetherEngine publishes a separate optional AetherEngineSMB product. Silo links
the AetherEngine product, not AetherEngineSMB, so SMBClient is not included in
these shipped-component notices.

Source availability
-------------------

The links above identify the exact source and rebuild inputs for this build.
This internal implementation is not yet an external-distribution source
offer. Before external release, Silo must publish an immutable corresponding-
source archive for the exact binary, including the FFmpegBuild build script
and its patches, and put its durable retrieval location in this notice.

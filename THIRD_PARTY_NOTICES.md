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
| AetherEngine 6.67.2 + Silo handover/subtitle patches | `f68ad1309001d879ad69f95dd03b9c57410550b1` | Swift package target linked into each host app | LGPL-3.0-only with AetherEngine's Apple Store / DRM exception |
| FFmpegBuild 3.0.0 | `421e13be7061de67d91b85ac34a6b22a002b164f` | Nine separately embedded dynamic frameworks | See the component table below |
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
`6.67.2` plus three commits: one lets a host request the in-place native item
handover on a foreground episode change through `prepareForItemReplacement()`,
and one makes the remote-HLS bypass honour that handover instead of dropping
the item across the swap. The third preserves complete native subtitle renditions
and maps external subtitle timing after an upstream media reanchor. These modifications
are published under the LGPL on
the fork branch below, which satisfies the license's source obligation for
modified code. The bundled
acknowledgements include AetherEngine's complete license and exception plus
the GNU GPL version 3 text incorporated by LGPLv3.

- Exact source: <https://github.com/Silo-Server/AetherEngine/tree/f68ad1309001d879ad69f95dd03b9c57410550b1>
  (fork branch `silo/host-requested-item-handover`)
- Upstream base: <https://github.com/superuser404notfound/AetherEngine/tree/6.67.2>
- Rebuild input: `Package.swift` and the source tree at that revision
- Bundled texts: `AetherEngine-LGPL-3.0-App-Store-Exception.txt`,
  `GPL-3.0.txt`

The exception permits Apple App Store and TestFlight distribution despite
store signing, DRM, and relinking restrictions. It does not waive source-code
obligations: the exact-revision link above must stay current for each release,
and any downstream modifications must be published under the LGPL. The fork
branch above is that publication; keep it public for as long as builds that
link this revision are distributed.

## FFmpegBuild and its component libraries

AetherEngine's `AetherEngine` product depends on FFmpegBuild's umbrella
product. The resolved FFmpegBuild manifest links all of these as separate
dynamic frameworks:

| Frameworks | Upstream input | License |
| --- | --- | --- |
| AetherLibavcodec, AetherLibavformat, AetherLibavutil, AetherLibswresample, AetherLibswscale, AetherLibavfilter | FFmpeg `n8.1.2` (currently `38b88335f99e76ed89ff3c93f877fdefce736c13`) | LGPL-2.1-or-later |
| AetherLibdav1d | dav1d `1.5.4` (currently `54706fc6bc0cdecab7e9593974a4039cc038fca7`) | BSD-2-Clause |
| AetherLibzimg | zimg `release-3.0.6` (currently `f819b14e8f39d1282400b0d9543e8ef73c1b2bbd`) | WTFPL-2.0 |
| AetherLibzvbi | libzvbi `v0.2.45` (currently `d3a5ee9f2b047bf16cd1ee5ccf6ec05ee75409d0`) | LGPL-2.0-or-later, conveyed under LGPL-2.1; `src/ure.c` is MIT |

FFmpegBuild 3.0.0 renamed every target, framework bundle, and install name
with an `Aether` prefix so the build can coexist with another FFmpeg in the
same app; the binaries are the same as 2.5.0. The exact FFmpegBuild 3.0.0
`build.sh` is the rebuild recipe and patch record:

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
observed on 2026-09-04. FFmpegBuild's script records tag names rather than immutable
upstream commit IDs; recording the dereferenced commits here pins them if the
tags ever move. Forking the pinned FFmpegBuild revision is cheap,
commit-immutable insurance if stronger provenance is ever wanted, but the
exact-revision links satisfy the source pointer as they stand.

A tvOS Simulator debug build against FFmpegBuild 3.0.0, inspected on
2026-09-04, embeds exactly the nine `Aether`-prefixed frameworks in the table
under `SiloTV.app/Frameworks/`, its `AetherLibavcodec` configure string
contains `--enable-shared` without `--enable-gpl`, `--enable-version3`, or
nonfree enablement, and the app binary exports no `avcodec_`/`avformat_`
symbols of its own. Repeat this inventory against each release archive;
debug evidence is not a release substitute.

- Exact packaging source and rebuild script:
  <https://github.com/superuser404notfound/FFmpegBuild/tree/421e13be7061de67d91b85ac34a6b22a002b164f>
- Current upstream tag resolutions:
  [FFmpeg](https://github.com/FFmpeg/FFmpeg/tree/38b88335f99e76ed89ff3c93f877fdefce736c13),
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

## Release checklist

The bundled notices, license texts, and exact-revision source links above
cover the standing LGPL obligations: this matches the adopter steps
AetherEngine's own README asks for (embed FFmpeg dynamically, ship the license
texts, point at the exact source). Per release, before App Store, TestFlight,
or other external distribution:

1. verify the release archive embeds the FFmpegBuild libraries as separate
   dynamic frameworks and does not merge or statically link them into the app
   binary (the debug-build inventory above is not a release substitute);
2. confirm the revisions in this file and in the bundled acknowledgements
   match what the release actually resolves in `Package.resolved`;
3. if AetherEngine or any LGPL component was modified, publish the modified
   source under its license before shipping.

# tvOS Redesign Mockups

> **Decision:** Skyline (A) was chosen; Rail (B) is also specced for
> prototyping/comparison. Implementation specs:
> [`../skyline-design-guide.md`](../skyline-design-guide.md) ·
> [`../rail-design-guide.md`](../rail-design-guide.md), with ready-to-paste
> prompts in `../skyline-implementation-prompt.md` /
> `../rail-implementation-prompt.md`.

Three navigation paradigms for a ground-up redesign of the Silo tvOS app, each
attacking the two current UX pain points:

1. **Library switching** — today a full-screen modal picker behind the Libraries tab.
2. **Library vs Collections mode** — today a stateful segmented slider tucked in the
   top-right corner of the menu bar.

Every screen is a 1920×1080 HTML/CSS mockup (`shots/` holds rendered PNGs).
Visual DNA (OLED black, monochrome, white-fill focus grammar, 12pt radii) is kept
from the current `SiloTheme`; each direction varies the chrome, not the brand.

## A — Skyline (`a1`–`a3`): content-type-first top bar

Apple TV-app-native. Libraries stop being a place you visit — each library type is
a top-level tab (Home · Movies · Series · Music · Audiobooks · Calendar). The mode
slider is replaced by sub-destination pills under the bar (Browse / Collections /
Genres / A–Z), and collections additionally surface as an inline row on each
library's landing. With multiple libraries of one type, the tab grows a lightweight
anchored dropdown (a3) — no full-screen modal.

- Closest to the current architecture (`TVMainTabView` already has a custom top menu).
- Most conventional; lowest learning curve.

**Focus-marquee variant (`a4`–`a5`, proposed):** removes the Featured
carousel/Spotlight hero entirely. The top section becomes a passive "marquee"
that previews whatever card is focused in the rows below — eyebrow names the
source row, backdrop crossfades with focus. Rows own all focus (entry focus
lands on the first card of row 1); the hero's buttons, auto-advance, and
position dots are gone. `a4` shows Home, `a5` the Movies landing.

**Cascading switcher (`a6`, proposed):** the scope dropdown opens the moment a
library tab takes focus (no hold), and focusing a library row spawns a flyout
to its right with that library's sections (Browse · Collections · Genres ·
A–Z · Recently Added). Press the library name for its landing, or d-pad right
into the flyout to jump straight to a section; up/down rolls through libraries
and the flyout follows focus.

## B — Rail (`b1`–`b3`): collapsible left glass rail

Plex/Netflix-style. A 104px icon rail on the left edge expands on focus into a glass
panel listing every destination *and every library flat with live counts* — switching
is left, pick, done. Inside a library, Recommended / Browse / Collections / Genres are
underlined content tabs beneath the title, with filter chips and an A–Z rail.

- Best for many libraries and power users; most information-dense.
- Costs horizontal focus travel (left edge owns the menu).

## C — Stage (`c1`–`c3`): chromeless cinema + summonable dock

Zero persistent chrome; content owns the frame, serif display type for titles.
Pressing down from the top (or holding Menu) summons a centered glass dock of large
tiles with a live contextual preview row of whatever tile is focused. Holding on a
library tile opens **Spaces** (c3) — a full-screen mosaic where each library is a
giant art card with counts, collection chips, and recent-poster strips. Switching
libraries becomes a destination, not a chore.

- Most distinctive and most "TV"; boldest departure.
- Navigation is hidden until summoned — needs good first-run hints.

## Re-rendering

Chrome headless subtracts ~90px of window chrome from `--window-size`, so render
taller and crop:

```sh
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$chrome" --headless=new --disable-gpu --hide-scrollbars \
  --window-size=1920,1400 --screenshot=/tmp/raw.png "file://$PWD/<file>.html"
ffmpeg -y -i /tmp/raw.png -vf "crop=1920:1080:0:0" shots/<file>.png
```

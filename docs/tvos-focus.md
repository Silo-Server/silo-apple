# tvOS Focus Guidance

This note combines Apple's focus-system behavior with the conventions used by
the Silo Apple client. Statements labeled **Silo rule** are project policy, not
guarantees made by SwiftUI or UIKit.

The central Silo rule is that every interactive zone has one focus owner. Let
the system move through a stable graph of focusable controls, or implement one
custom focusable composite control. Do not make both models respond to the same
directional input.

## What Apple's APIs Guarantee

- tvOS focus movement is directional and layout-based. People expect focus to
  move in the same direction as their remote gesture.
- `focusSection()` makes the modified view's frame and focusable descendants
  participate in movement guidance. The section itself does not become a
  focusable control; it directs focus to the nearest eligible descendant. A
  section intended to bridge a gap needs a frame large enough to intersect the
  relevant movement path.
- `focusScope(_:)` does not create a directional-navigation group. It limits
  the default-focus preferences used by `prefersDefaultFocus` and
  `resetFocus(in:)` to a namespace.
- `@FocusState` observes focus and can request a programmatic change.
  `defaultFocus` defines a value to use when SwiftUI evaluates default focus;
  `resetFocus(in:)` asks the named scope to reevaluate its default. These APIs
  do not remap a particular D-pad direction.
- `onMoveCommand` installs a command handler in the focused view hierarchy. It
  is useful for a custom control or an otherwise unhandled edge, but it is not
  a declarative focus-guide API. Do not rely on an ancestor handler to replace
  a valid geometric move between native controls.
- UIKit's `UIFocusGuide` is the supported escape hatch for a nonstandard
  geometric connection. Its active layout frame becomes an invisible focus
  region and `preferredFocusEnvironments` supplies its redirect destinations.
  Apple recommends using a guide only when ordinary layout cannot produce the
  desired navigation.
- Prefer system focus behavior and focus effects. Custom effects and
  programmatic focus changes should be deliberate, predictable, and tied to a
  person's action or to removal of the previously focused item.

## Focus Models

Use one of these patterns for a given control.

### Native Focus Graph

Use this for ordinary rows, grids, button groups, sheets, and menus where each
actionable item can be a real focus target.

- Render stable `Button`, `NavigationLink`, or `.focusable(...)` items.
- Use `focusSection()` to bridge a directional gap or enlarge a row's movement
  catchment. Use `focusScope(_:)` only when the region needs scoped
  default-focus evaluation.
- Use `@FocusState`, `prefersDefaultFocus`, `defaultFocus`, or `resetFocus` to
  seed, observe, or restore focus, not to fight the engine on every move.
- Keep the focused subtree mounted and structurally stable while moving focus.
- Keep native focus effects structurally stable too. If temporary focus
  eligibility is required to make one cross-row destination exclusive, latch
  it through the focus engine's transient `source -> nil -> destination`
  handoff. Restoring a row of Liquid Glass controls during that `nil` frame can
  redraw every glass surface and produce a visible row-wide flash. Release the
  latch only after the destination has landed, with implicit animations
  disabled. Prefer a bounded `focusSection()` catchment when geometry alone
  can express the edge; use `UIFocusGuide` when it cannot.
- Attach `onMoveCommand` at an intentional edge only when native movement has
  no desired destination, such as Up from the first card returning to chrome.
  Do not attach broad handlers that compete with ordinary in-zone movement.
- **Silo rule:** Prefer real layout (`padding`, `frame`, alignment, or spacers)
  when shaping focus relationships. A visual transform such as `.offset` can
  make rendered position and layout relationships disagree; verify transformed
  controls on hardware if it is unavoidable.

Good local examples:

- `TVCatalogGrid`
- `TVLibraryCollectionsView`
- `TVForYouDropdown`
- `TVProfileDropdown`

### Composite Focus Control

Use this when the visual control is one logical selector even though it renders
multiple highlighted rows or columns. A cascading selector is the main example.

- Make one container the real focus target with `.focusable(...)` and a single
  `@FocusState`. Specify the supported focus interactions when that distinction
  matters.
- Render internal rows as passive labels; do not also make them native focus
  targets or attach per-row `.focused(...)` bindings.
- Store the highlighted row or column in ordinary `@State`.
- Handle the composite's D-pad movement in one place.
- Give Select one semantic activation path. Prefer a native `Button` when its
  interaction model fits; `TVCascadeSelector` uses the focused container's tap
  gesture because the whole multi-column selector is one control.
- Provide one useful accessibility label, value, hint, and traits for the
  composite. Do not assume that visually rendered child labels are separate
  accessibility elements.

Good local example:

- `TVCascadeSelector`

## Do Not Mix Models

The broken pattern is a hybrid control:

- row `Button`s participate in native focus,
- the same rows also use `@FocusState`,
- a parent or window-level handler manually changes that focus for the same
  directional press.

That gives one physical remote press multiple potential owners. The symptom is
multiple focus writes for one move, such as:

```text
cascade.move/right library(1)
cascade.focus -> section(1, recommended)
cascade.focus -> section(1, browse)
cascade.focus -> nil
bar.focusedItem -> Calendar
```

When this happens, stop adding press interceptors. Decide which focus model the
control uses, then remove the other one.

## Top Menu Ownership

The following is a **Silo state-machine contract**, not an Apple API model:

- `closed`: no panel is visible; focus belongs to content or the bar.
- `preview`: a dwell-open panel is visible, but the bar still owns focus and
  the panel is passive.
- `entered`: the user moved into the panel; the panel owns focus and the bar is
  inert until the panel closes.

In entered mode, the bar must not accept focus on another tab behind the panel.
Treat `panelHasFocus` as telemetry from the child, not as the ownership source
of truth. The durable signal is the host's entered-panel state.

When closing a panel, choose the next owner explicitly:

- Menu/Back closes and returns focus to the panel's bar anchor.
- Down past the last row closes and hands focus to page content.
- Selecting a panel row closes, updates route or scope state, and hands focus
  to the destination content.

## Cross-Zone Return Targets

Master/detail screens can need a semantic return target that differs from the
geometrically nearest control. Settings is the canonical case: Left from any
detail row returns to the rail category whose pane is visible.

- First express the rule in the focus graph. While detail owns Settings focus,
  only the visible category is eligible on the rail; native Left movement then
  has one valid destination.
- Use `focusSection()` only when the issue is a missing geometric path. It
  guides focus to a nearest descendant; it cannot name an exact descendant.
- Do not use an ancestor `onMoveCommand` as an override when the engine already
  has a valid candidate in that direction.
- If SwiftUI layout and focus eligibility cannot express the required mapping,
  bridge to a `UIFocusGuide` with `preferredFocusEnvironments` rather than
  allowing the wrong item to focus and correcting it afterward.
- For programmatic restoration after a modal or disappearing view, set the
  intended owner and target together. Do not let another item settle and then
  asynchronously correct it; that produces a visible flash and violates the
  user's directional expectation.
- Use `resetFocus(in:)` only when you actually want the scope to reevaluate its
  configured default focus. It is not a directional-navigation command.

## Why Settings Uses Focus Eligibility

Settings keeps a two-pane native focus graph. Its behavior is:

1. While the rail owns focus, Profile, every category, and Sign Out are all
   eligible. Vertical movement and category previews remain native.
2. Entering detail changes the preferred owner to detail. The rail stays
   visible, but `canRailItemReceiveFocus(_:)` leaves only
   `.category(selectedCategory)` eligible.
3. A Left gesture from any detail control can therefore resolve to only that
   category. The focus engine performs one native move and never displays an
   intermediate rail highlight.
4. When the category receives focus, the rail becomes the preferred owner and
   all rail items become eligible again.

The earlier implementation attached `onMoveCommand` to the detail pane and set
the rail's `@FocusState` from that callback. That was not deterministic: the
native graph already contained valid controls to the left, so geometric focus
resolution could select one before the ancestor command path could establish
the semantic target. A later programmatic assignment either did not win or
produced the distracting wrong-item flash. Restricting eligibility expresses
the destination before movement begins and avoids corrective focus mutation.

## Detail Hero and Episode-Browser Handoff

The Apple-TV-style detail page is one vertical canvas with two visual regions:
the hero controls and the episode browser. `TVDetailFocusScroll` is the only
`ScrollViewProxy` writer. Focus state chooses its scroll intent; individual
buttons and rows must not also issue vertical `scrollTo` calls.

The directional contract is:

1. The detail page owns one `TVDetailActionFocus` value for Play and its sibling
   actions, plus one `TVPlaybackSelectorFocus` value for Version, Audio, and
   Subtitles. Child rows receive those bindings; they must not attach a second
   local `FocusState` to the same native control. Two focus bindings can produce
   a split state where a button looks focused but its row still reports `nil`.
2. Play -> Down enters the playback selector. While an action owns focus, the
   episode browser is temporarily ineligible. Keep that latch through the
   transient `source -> nil -> destination` frame and release it immediately
   when the selector row reports focus. The fallback is two seconds because a
   scroll-backed search on tvOS 26.5 can exceed 500 ms; it exists only to unlock
   an aborted move and is cancelled on a successful landing.
3. Version <-> Audio <-> Subtitles is ordinary native horizontal movement.
   Never rewrite selector focus for those presses. Keeping their shared focus
   binding at page scope also makes a Season-row return land on a healthy native
   item instead of a child-scope item with no horizontal candidates.
4. Playback selector -> Down uses native geometry. Episode cards and later
   rails are temporarily ineligible, but the Season row remains eligible. The
   selected pill is the row's only eligible entry target until the row owns
   focus; all pills then become eligible for ordinary Left and Right movement.
   Latch that ownership across the focus engine's transient
   `pill -> nil -> pill` frame. Only restore selected-only eligibility when nil
   persists as a genuine row exit, and suppress implicit animation for that
   eligibility update. Likewise, do not report transient nil to parent
   prefetch state: rebuilding the parent and every glass pill mid-handoff
   produces a row-wide flash.
   Render each season pill as an independent native glass surface. Do not wrap
   this row in a shared `GlassEffectContainer`: its combined render group
   couples every pill when the focused pill changes tint and scale, producing
   the same inactive-control flash avoided by `TVDetailActionRow`.
   Each pill is one custom composite: the completed glass surface receives the
   `.focusable(eligible)` gate, the row's `.focused(...)` binding, the Select
   gesture, and the default accessibility action. Render its Liquid Glass with
   the shared detail-surface recipe instead of nesting a native `Button`.
   Applying `.focusable` around an already focusable `Button` creates two
   activation owners: Select can stop at the outer interaction, visually
   highlight the pill, and never run the Button action. Repeated presses then
   appear to select every season while the episode carousel never changes.
   Removing only the eligibility wrapper makes activation work but loses the
   selected-season entry guarantee because tvOS does not reevaluate scoped
   default focus for every directional move.
   Render the bright white glass, lift, and inverted label from the same
   `focusedSeasonId` telemetry. Selection is a separate, quieter clear-glass
   tint with a white label. Do not add a dynamic backing or overlay around the
   pill: it can leave stale highlights behind and obscure which state owns the
   visual. This rendering must never mutate focus.
   A scoped `defaultFocus` remains a fallback, not the guarantee: tvOS does not
   reevaluate it for every directional entry. The latch is released when a
   Season pill owns focus. Do not add a second Version -> Season request/cancel
   state machine.
5. Season -> Up is the one intentional dead-edge command. The Season row asks
   the page-owned selector focus binding for Version. Selector telemetry then
   drives the existing `TVDetailFocusScroll` hero intent; individual controls
   still do not issue their own `scrollTo` calls.
6. Season -> Down enters the episode carousel on the episode represented by
   the detail page (or the series/season's next-up episode). `TVEpisodeRail`
   gives that card a user-initiated `defaultFocus` preference inside a nested
   carousel `focusScope`. The nested scope is essential: it makes the current
   episode win when focus enters the rail without letting the rail's preference
   compete with Play during page entry. Left and Right within the carousel
   remain ordinary native movement. Up from an episode re-enters the Season
   scope on its selected pill.
7. Selector -> Up returns to Play. Because a wide Version pill is geometrically
   centred under the secondary actions, keep those sibling actions ineligible
   while *any* selector owns focus. Use one continuously mounted `.disabled`
   value rather than conditionally adding/removing focus modifiers. The Boolean
   stays true across Version -> Audio -> Subtitles, so horizontal movement does
   not reconstruct the Liquid Glass action row.

Keep visually fading focus owners mounted with a render-only opacity floor. A
literal `.opacity(0)` removes descendants from the focus graph; `0.001` is
visually transparent while preserving stable eligibility and avoids the
offscreen render pass of a full-subtree mask.

Scroll progress is high-frequency render state, not page-navigation state.
Keep it in `TVDetailScrollVisualState` and pass the reference without reading
`progress` in `TVMovieDetailView.body`. Only the backdrop, hero reveal wrappers,
and compact-header reveal observe it. Storing progress directly on the root
detail view invalidates the complete focus graph and every Liquid Glass control
on every animation frame, which can hitch on physical Apple TV even when the
simulator looks smooth. Likewise, do not animate the radius of a full-screen
backdrop blur. Crossfade a fixed pre-blurred layer so scrolling changes only
cheap compositing properties.

The simulator regression test for this contract is
`TVDetailFocusHandoffUITests.testSeasonUpReturnsToPlaybackSelector`. It follows
Play -> Version -> Audio -> Version -> selected Season -> adjacent Season ->
current episode -> selected Season -> Version -> Audio -> Subtitles -> Version
-> Play -> Start Over -> Play and verifies the actual focused accessibility
element after every move. Keep it attached to a multi-season series fixture so
it exercises both focus zones and the canvas transition. Do not add sleeps to
make this route pass.

## Debugging Checklist

When focus feels random, capture the active ownership boundary first:

- current focused top-bar item
- open panel and whether it is previewed or entered
- whether the panel reports focus
- the panel's internal highlighted item
- every `onMoveCommand` direction handled by the active owner
- which controls are eligible in the destination zone

Expected cascade movement after entering a Movies panel looks like this:

```text
host.enterOpenPanel openPanel=Movies
cascade.panelFocused -> true selection=library(1)
cascade.move direction=right focus=library(1)
cascade.focus -> section(1, recommended)
cascade.move direction=down focus=section(1, recommended)
cascade.focus -> section(1, collections)
```

Unexpected signs:

- the bar logs a different focused tab while a panel is entered,
- one D-pad press produces multiple panel focus writes,
- panel focus becomes `nil` without an explicit close or content handoff,
- a broad `onMoveCommand` and native movement both appear to own the same zone,
- a semantic cross-zone move briefly focuses the wrong item before correction.

## Apple References

- [Focus and selection — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection/)
- [Remotes — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/remotes)
- [SwiftUI Focus](https://developer.apple.com/documentation/swiftui/focus)
- [The SwiftUI cookbook for focus — WWDC23](https://developer.apple.com/videos/play/wwdc2023/10162/)
- [`focusSection()`](https://developer.apple.com/documentation/swiftui/view/focussection%28%29)
- [`focusScope(_:)`](https://developer.apple.com/documentation/swiftui/view/focusscope%28_%3A%29)
- [`onMoveCommand(perform:)`](https://developer.apple.com/documentation/swiftui/view/onmovecommand%28perform%3A%29)
- [Creating custom navigation interactions](https://developer.apple.com/documentation/uikit/focus-based_navigation/creating_custom_navigation_interactions)
- [`UIFocusGuide`](https://developer.apple.com/documentation/uikit/uifocusguide)
- [Archived tvOS focus-engine and remote guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/AppleTV_PG/WorkingwiththeAppleTVRemote.html)

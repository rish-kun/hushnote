# Unified Sidebar and Meeting Canvas Design

## Status

Approved 24 August 2026. This document translates the approved **Unified
Editorial Spread** direction into an implementation plan. It supplements
`2026-08-23-folders-responsive-redesign-design.md`; it does not change that
document's folder, search, persistence, or responsive-navigation decisions.

## Problem and design intent

The current Models, Storage, and Settings pages have begun to use the
container-aware page language: one quiet canvas, deliberate gutters, a
bounded content column, and simple ruled inventory rows. The meeting library
and workspace still read as separate panels placed inside that application:

- The sidebar appears to be a rounded, independently framed card instead of a
  persistent part of the split view.
- `AppShellView` paints a shell canvas and then wraps every detail route in a
  second scaffold and paper background. Utility pages also add their own
  scaffold/canvas. Those nested owners create visible seams and inconsistent
  page measures.
- Meeting headers and tab strips use a raised background independent of the
  transcript body, producing the dark/light moat visible in the supplied
  meeting screenshot.
- All Meetings and Recently Deleted have correct controls and data but do not
  yet share the same page rhythm or inventory-row treatment as Models and
  Storage.

The application should instead read as one quiet editorial spread: a related,
subtly contrasting navigation column beside one continuous detail canvas.
Surfaces clarify a control or an editor, not a page boundary.

## Visual system

### Split-view surfaces

- Keep the existing app-owned, appearance-aware palette. The navigation
  surface is deliberately related to, but distinct from, the detail paper:
  slightly darker than the detail in light appearance and slightly lighter in
  dark appearance. Do not use a system sidebar material, blue selection, or a
  glass effect.
- The sidebar reaches the split-view edges. Remove any rounded outer-card
  treatment, inset border, or visually separate canvas around it.
- Separate sidebar and detail with exactly one quiet vertical rule using
  `HushnoteTheme.rule` at low opacity. The rule is structural, not a shadow or
  a second panel border.
- The detail route paints one continuous `paperBackground` from beneath the
  header through the scrollable body. The application canvas may show only
  outside that owned detail surface, never as a band between its header, tabs,
  and body.
- Retain raised/control surfaces for fields, buttons, editor wells, recording
  controls, and explicitly interactive utilities. They are never used merely
  to place a generic rectangle behind an entire subpage.

### Typography, measure, and rhythm

- Preserve the theme's sans-serif interface hierarchy and serif sustained
  reading. Page headers use `pageTitle`; long notes, summaries, and transcript
  prose retain the reading styles.
- Use `AdaptiveLayoutPolicy` as the single source of truth: compact below 760
  points, regular from 760 to 1099, wide from 1100. Detail gutters remain
  24/32/56 and utility content remains bounded by its existing 1,240-point
  maximum where appropriate.
- Keep transcript, notes, and summary prose at the existing 704-point measure
  (within the approved 680–720-point range). Align its start with the meeting
  header/tab gutter; center the reading measure only within the continuous
  content canvas rather than a visually separate dark column.
- Reuse rows, hairlines, whitespace, labels, and contextual actions as the
  primary organization tools. Avoid card grids, pronounced shadows, and
  separate canvas colors for sibling screen regions.

### Appearance preference

- Settings gains an **Appearance** choice with exactly three product terms:
  System, Light, and Dark. System is the default and continues to follow the
  macOS appearance. Light and Dark explicitly override it for the whole app.
- Use a product-owned accessible segmented treatment that fits the established
  control surface, focus treatment, and semantic theme colors. It must still
  be a native SwiftUI semantic control (or expose equivalent selection,
  keyboard, focus, and VoiceOver behavior), not a decorative row of gestures.
- Store the choice in `AppPreferences`/`UserDefaults`. Missing or malformed
  stored values resolve to System, and existing installations receive System
  without a migration prompt or a restart.
- The root app scene observes the preference and maps it to SwiftUI's
  `preferredColorScheme` (or an equivalent app-wide override). A selection
  takes effect immediately across the shell, sidebar, meeting canvas, and all
  utility screens; changing back to System resumes automatic system tracking.

## Architecture and ownership

### One shell-owned detail surface

`AppShellView` becomes the sole owner of the split-view detail background,
including failed-recording state. It resolves the active route and supplies
one continuous page canvas. It must not nest an `AdaptivePageScaffold` around
all routes, because Models, Storage, Settings, library views, and the meeting
workspace require different layout structures and currently own or will own
their own content placement.

Each route owns only its content geometry:

| Area | Surface owner | Content/layout owner |
| --- | --- | --- |
| Split navigation | `AppShellView` / `SidebarNavigationView` | Sidebar sections, search, rows, and recording footer |
| Models, Storage, Settings | shell detail paper | Existing page-local `AdaptivePageScaffold` and vertical scroll content |
| All Meetings, Unfiled, folders, Recently Deleted | shell detail paper | A shared library page layout plus reusable inventory rows |
| Completed meeting | shell detail paper | Meeting header, status, tabs, and the selected workspace within one vertical flow |
| Active/finalizing meeting | shell detail paper | Recording header and live transcript/notes content |

The implementation may simplify or rename background helpers, but it must
leave a single unambiguous owner at each level. In particular, do not apply
both `utilityCanvas` and `paperBackground` to a route and its ancestor when
that produces a seam. The background modifier needs to cover the full route
frame, including scrollable empty states, not only the intrinsic content.

### Affected production components

- `Sources/Hushnote/App/HushnoteTheme.swift`: retain semantic palette roles and
  adaptive thresholds; consolidate the shared canvas/scaffold contract so it
  expresses one detail surface. Update comments/tokens only if ownership is
  unclear. Do not introduce raw appearance-specific colors in views.
- `Sources/Hushnote/App/AppPreferences.swift` and
  `Sources/Hushnote/App/AppViewState.swift`: define an appearance preference
  value that round-trips through preferences, defaults to System, and is
  observable by the app without making it a meeting/persistence concern.
- `Sources/Hushnote/App/HushnoteApp.swift` (or the root scene host): map the
  saved preference to the app-wide preferred color scheme and react to changes
  in the active state immediately.
- `Sources/Hushnote/UI/AppShellView.swift`: make the sidebar edge-to-edge with
  a quiet divider; remove duplicate detail-scaffold/background ownership;
  route library views through the shared page layout; keep toolbar, search
  debouncing, failures, and recording footer behavior intact.
- `SidebarNavigationView` and `SidebarNavigationRow` in `AppShellView.swift`:
  preserve information architecture and selected accessibility state while
  tuning section/row rhythm for the unified surface. Search and the footer use
  the same navigation surface; selection stays moss-based and does not become
  an OS-blue list style.
- `MeetingsHomeView` in `AppShellView.swift`: adopt the Models/Storage page
  header, policy-aware gutters, full-height continuous body, and reusable
  editorial inventory rows. All, Unfiled, folders, and Recently Deleted use
  this one layout rather than separate per-scope scaffolds.
- `Sources/Hushnote/UI/MeetingWorkspaceView.swift`: make completed-meeting
  header, export status, tabs, and selected tab body siblings on the same
  continuous canvas. Replace full-width raised header backgrounds with spacing
  and a quiet bottom rule where separation is needed. Align active/finalizing
  meeting chrome to the same ownership model without weakening recording-state
  prominence. Preserve each tab's existing behavior.
- `Sources/Hushnote/UI/SettingsAndModelsView.swift` and
  `Sources/Hushnote/UI/StorageDashboardView.swift`: remove page-local canvas
  painting only where it duplicates the shell's detail surface; preserve their
  existing content scaffold, row hierarchy, loading/error UI, and actions.
  Settings adds the Appearance control, bound to the persisted app preference.
- `Sources/Hushnote/UI/Components.swift`: extract only genuinely shared UI
  (for example, an inventory row or a page header) if it eliminates repeated
  library/deleted markup. Keep native `Button`, `Menu`, `TextField`, and
  SwiftUI accessibility semantics; do not replace them with custom gestures.

No model, persistence, migration, or coordinator API change is required for
this visual redesign. The appearance value is application preference state,
not meeting data; its missing-value default is sufficient for existing users.

## Page behavior

### Sidebar

- Wide layouts continue to show the persistent navigation column at the
  existing 220–300 point split-view range. The column uses the related
  navigation shade all the way to its edges, including the recording footer.
- Section order remains Library, Recent (when non-empty), and System. Existing
  counts, folder rows, global search, selection, and meeting navigation stay
  unchanged.
- Keep the 250ms cancellable search behavior and the existing selected-row
  VoiceOver trait. Ensure row titles truncate rather than expanding the
  column; subtitle/date and count retain their secondary hierarchy.
- Compact navigation continues to use `NavigationSplitView`'s accessible
  affordance. This project is intentionally not introducing a custom
  split-view controller or a bespoke navigation drawer.

### Meeting library and Recently Deleted

- All Meetings, Unfiled, folders, and Recently Deleted present one editorial
  page header: title and explanatory subtitle at the standard policy gutter,
  with a contextual action aligned to the right when relevant. The All Meetings
  create action remains disabled while recording is busy. Recently Deleted
  does not offer a misleading create action.
- Use a flat, ruled inventory list: a quiet date/metadata column, a primary
  meeting title, controlled two-line excerpt, supporting template/duration,
  and contextual actions at the trailing edge. Rows share the same vertical
  cadence, divider, alignment, hover/focus behavior, and compact adaptation as
  the Models/Storage inventory language.
- A normal meeting row opens the meeting; its contextual Rename and Move to
  Recently Deleted actions remain available both through the existing menu and
  context menu. The active meeting cannot be deleted.
- Recently Deleted uses the same row system but makes its lifecycle clear:
  title, retained-until information, Restore, and Delete Permanently remain
  available. Permanent deletion retains confirmation. In the All Meetings
  scope, the deleted group remains a disclosure group with its current
  behavior; it adopts the same headings/rhythm without masquerading as an
  independent card.
- Empty and search-empty states retain distinct title, explanation, and next
  action for global/all, Unfiled, folders, and Recently Deleted. On compact
  widths the illustration and copy stack or otherwise fit without clipping.

### Meeting information and workspace

- The header starts on the standard detail gutter and owns title editing,
  date/duration/template metadata, current folder control, start/recovery,
  and export actions. The header uses space and a hairline rather than a raised
  panel to establish hierarchy.
- The tab strip sits directly below the header and shares its horizontal
  alignment. It remains keyboard accessible and horizontally scrollable at
  compact width; selected tab appearance remains distinguishable without
  introducing platform-blue segmented styling.
- Notes, Summary, Transcript, and Ask flow directly below the tab strip on the
  same page paper. The transcript remains a single scroll region with a
  704-point reading measure, live-region semantics, focused-edit protection,
  follow/jump-to-latest behavior, and reduced-motion behavior unchanged.
- The wide Summary right rail remains available only at the existing wide tier.
  At regular/compact widths it stays in document flow. Long metadata and
  actions use the existing stack/wrap behavior instead of clipping.
- Active and finalizing views preserve their distinctive recording/finalizing
  states and controls. Their header must appear as part of the same detail
  canvas, not as a separate elevated bar.

### Appearance behavior

- Selecting System, Light, or Dark updates the full application immediately.
  The active route, sidebar selection, draft state, scroll position, and
  recording session are not reset while the palette changes.
- Semantic theme tokens resolve in the selected appearance, including the
  navigation/detail relationship, raised controls, moss selection, rules,
  recording vermilion, and readable primary/secondary text. No page should
  retain a stale system appearance after an explicit override.

## Accessibility and resilience requirements

- Preserve semantic controls, menu/context-menu alternatives, keyboard
  shortcuts, focus behavior, VoiceOver labels/values, dynamic type wrapping,
  and `accessibilityReduceMotion` branches.
- Verify foreground/background contrast for both theme appearances, including
  selected navigation rows, muted metadata, sidebar divider, destructive text,
  and disabled actions. The low-contrast rule is decorative only and cannot be
  the only signal of selection, focus, deletion, or recording state.
- There must be no horizontal overflow at compact widths: headers stack,
  actions remain reachable, tab labels scroll, row metadata wraps/truncates
  appropriately, and the reading column does not force a minimum window size.
- Preserve loading, recording failure, model/storage errors, exported-audio
  status, transcript auto-follow, and empty-state behavior. This work changes
  presentation ownership, not data or state transitions.

## Implementation sequence

1. Audit the worktree and existing staged changes before editing. Leave all
   unrelated folder/responsive work intact; make this redesign compatible with
   its destinations and adaptive policies.
2. Add the persisted appearance preference and root-scene mapping. Establish
   the default/malformed-value behavior first, then bind the Settings control
   so System/Light/Dark changes affect the app without relaunching or changing
   meeting state.
3. Establish the single surface contract in `HushnoteTheme` and `AppShellView`:
   shell owns detail paper; the sidebar owns only its related navigation shade;
   add the low-contrast split divider; remove duplicate shell/route canvas
   layers without changing route selection or toolbar behavior.
4. Refactor Models, Storage, and Settings only enough to follow that contract.
   Validate that the current improved utility-page layout remains visually and
   behaviorally identical apart from removal of duplicate canvas seams.
5. Build or extract the minimal reusable library page header/inventory row
   primitives. Migrate `MeetingsHomeView` scopes, including the in-All
   Recently Deleted disclosure and all empty/search states.
6. Recompose `CompletedMeetingView` (and active/finalizing meeting chrome as
   needed) into a continuous header/tab/body flow. Maintain tab state and
   existing measure/right-rail logic; remove only background layers that make
   page regions appear disconnected.
7. Exercise compact, regular, and wide layouts in both light and dark
   appearance; iterate on gutters, row action placement, metadata wrapping,
   and sidebar/route boundary until the visual acceptance criteria pass.
8. Add targeted pure/UI tests, run the relevant suite, then perform a manual
   visual pass using representative library, deleted, completed, recording,
   long-title, and empty states. Do not alter persistence behavior merely to
   accommodate layout testing.

## Test plan

### Automated

- Keep `AdaptiveLayoutPolicyTests` as the source of truth for 759/760 and
  1099/1100 boundaries; add pure layout tests only for new policy-derived
  placement decisions.
- Extend existing `AppViewStateTests`/`AppPreferencesTests` only if route or
  selection behavior is accidentally touched; destination serialization,
  stale folder fallback, and selected tab persistence must continue to pass.
- Add `AppPreferencesTests` for the default System selection, all three values'
  round trip, and an invalid/missing stored value falling back to System. Add
  an `AppViewState` or small pure mapping test for System → `nil`, Light →
  `.light`, and Dark → `.dark` preferred-scheme behavior, including immediate
  observable change when the preference updates.
- Preserve `MeetingManagementPersistenceTests` coverage for search, folder
  membership, soft deletion, restore, permanent deletion, and active-meeting
  restrictions. No migration test should require an update for this change.
- Add focused view-model or helper tests for any extracted row/header layout
  decision that is not straightforward SwiftUI composition. Do not write tests
  that assert incidental colors or pixel offsets when a semantic assertion can
  cover the contract.

### Manual visual and accessibility matrix

| Scenario | Expected result |
| --- | --- |
| Light and dark, wide | Sidebar has a related contrasting shade and one quiet divider; all detail routes read as one continuous paper canvas. |
| Appearance: System, Light, Dark | System follows the host; explicit choices update every app-owned surface immediately and remain selected after relaunch. |
| 759/760 and 1099/1100 detail widths | No clipped controls or horizontal overflow; compact stacks controls, wide alone shows the summary rail. |
| All Meetings with long names/excerpts | Header and inventory align to utility-page gutters; long content truncates/wraps deliberately; contextual actions still work. |
| Recently Deleted with 0, 1, and many meetings | Correct empty copy; restore/permanent-delete actions and confirmation work; All Meetings disclosure remains functional. |
| Completed meeting, each tab | Header, export status, tabs, and body have no contrasting seam; tabs remain operable; 704-point reading measure remains intact. |
| Recording/finalizing meeting | Recording controls, error/finalization states, live transcript following, and reduced-motion behavior remain clear and functional. |
| VoiceOver, keyboard, increased text size | Selected navigation semantics, labels, keyboard actions, focus, menus, scrollable tabs, and content order remain usable. |

## Acceptance criteria

1. The sidebar is edge-to-edge, uses a subtle related navigation shade, and is
   separated from detail by one quiet rule—not a rounded, floating container.
2. There is exactly one visible continuous background from the meeting header
   through the active workspace content; no canvas band or raised page panel
   makes header, tabs, and transcript appear separate.
3. Models, Storage, Settings, All Meetings, Recently Deleted, and the meeting
   workspace use the same page language: theme tokens, adaptive gutters,
   hierarchy, hairlines, and restrained inventory treatment.
4. All existing navigation, global search, meeting/folder scopes, meeting
   actions, restore/permanent-delete confirmation, recording state, export,
   tab, transcript, summary, and note behavior is preserved.
5. Transcript/notes/summary prose remains within 680–720 points (704 today),
   and the wide summary rail appears only at the established wide threshold.
6. Compact, regular, and wide layouts pass the manual matrix in light and dark
   appearance with no inaccessible or clipped controls.
7. Targeted automated tests and the relevant application test suite pass
   without adding a data migration or changing persistent user state.
8. Appearance defaults to System, persists through `AppPreferences`, maps to
   the intended app-wide scheme without restart, and preserves accessible,
   contrast-checked navigation and detail surfaces in both forced schemes.

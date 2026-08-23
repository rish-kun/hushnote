# Hushnote brand assets

## Direction

Preserve the attached listening-tree silhouette while bringing it into Hushnote's established quiet editorial palette. The mark uses the app's vermilion; app-icon and About surfaces use warm ink and paper. The menu-bar variant is monochrome so macOS can render it correctly in every system appearance.

## Source of truth

One normalized Core Graphics path defines the silhouette and its two listening apertures. The SwiftUI brand mark and the AppKit menu-bar template consume that geometry.

The app icon no longer does. Supplied artwork at `Resources/Hushnote-icon-source.png` is the icon's production master, and `scripts/generate-app-icon.swift` downsamples it into every iconset size. That artwork carries no alpha channel — its rounded tile sits on opaque black corners, and the corner curve is continuous rather than a circular radius — so the generator recovers transparency by flood-filling inward from the four corners and fading each visited pixel toward the tile colour in proportion to its own brightness. Clipping to a guessed `roundedRect` instead would leave slivers at every corner.

## Surfaces

- A reusable SwiftUI brand mark for About and future in-app placements.
- A monochrome template image in the menu bar, with a compact recording badge while capture is active.
- A complete macOS iconset and `.icns`, rendered deterministically from the supplied artwork.
- A compact custom About window showing the mark, semantic product version/build, bundle identifier, and privacy-first product description.

## Validation

Unit tests verify normalized geometry, template-image behavior, and build-label formatting. A shell validator checks icon dimensions, Info.plist declaration, and bundle-build integration.

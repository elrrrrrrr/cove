# EasyReader Design Guide

> Purpose: make EasyReader feel like a polished iOS 26 native reading and media browser, not a generated demo UI.

This document is the design memory for Codex, Claude, and humans working on EasyReader. Read it before creating mockups or changing SwiftUI UI.

## Product Feel

EasyReader is a private content browser and reader. It should feel:

- Native: closer to Apple Photos, App Store, TV, Podcasts, Files, and Safari than to a web dashboard.
- Quiet: dense enough for repeated use, without marketing-page hero sections or decorative filler.
- Media-first: thumbnails, covers, pages, and video frames are the main visual material.
- Trustworthy: controls should feel stable, predictable, and hard to mis-tap.
- Flexible: site-specific behavior can vary, but the shell should remain coherent.

Avoid:

- "AI portfolio" aesthetics: oversized gradient cards, generic glass bubbles, random neon palettes, fake inspirational copy.
- Web admin aesthetics: boxed sections, card inside card, heavy shadows everywhere, dashboard widgets.
- Theme overuse: one-color palettes, purple-blue gradient dominance, beige/brown editorial styling.
- Decorative UI that does not represent real content, state, or controls.

## Core References

Use references as structure, not as skin.

- iOS 26 / Liquid Glass: navigation, toolbar, tab, and sheet controls float above content; content stays primary.
- App Store: Today card and horizontal shelves are good for curated entry points and site discovery.
- Photos: dense media grids are good for recent updates, image/video browsing, and mixed media.
- Apple TV / Infuse / YouTube: video detail should prioritize a large media surface, playback controls, and simple actions.
- Safari: web fallback/detail views should feel browser-native, with minimal custom chrome.
- Files: NAS and local/offline content should feel utilitarian, sortable, and information-dense.

Do not copy screenshots literally. Extract layout relationships:

- foreground controls over content
- large title where exploration starts
- inset grouped list for settings/library lists
- media grid for browsing
- bottom sheet for secondary detail
- full-screen player for playback

## iOS 26 Direction

Prefer system components that will inherit iOS 26 behavior:

- `NavigationStack`, `NavigationSplitView`
- `TabView`
- `.toolbar`
- `.sheet`, `.presentationDetents`
- `List` with `.insetGrouped`
- `ContentUnavailableView`
- standard buttons, menus, search, segmented controls

Use custom Liquid Glass-like UI sparingly. In SwiftUI implementation, prefer real system materials and components over hand-drawn HTML-style glass.

Good places for glass/material:

- floating navigation actions
- sheet header/footer
- player controls
- transient filters/search bars

Bad places for glass/material:

- every content card
- page background
- nested panels
- static repeated list rows

## Layout Principles

### 1. Content Owns The Screen

For media pages, the image/video grid should occupy most of the screen. Navigation and filters should be compact.

Good:

- floating or inline toolbar
- compact filter chips
- thumbnails with small overlays
- text below thumbnails

Bad:

- large empty headers
- thick card backgrounds around every item
- excessive top padding
- explanatory UI text

### 2. One Primary Structure Per Screen

Each screen should have one dominant structure:

- Site home: curated entry card + shelves + list
- Recent updates: media grid/list
- Favorites: saved media/library grid
- Detail: player or WebView sheet
- NAS: file list/grid
- Settings: inset grouped list

Do not mix many section styles on one screen.

### 3. Dense But Calm

EasyReader is used repeatedly. It should not feel like a landing page.

- Titles: 1-2 lines max in grids.
- Metadata: small, secondary, stable.
- Actions: visible only when expected; use long press/swipe/menu for secondary actions.
- Empty states: short and useful.

### 4. Stable Touch Targets

Common touch targets should be at least 44 pt high/wide. Cards should not resize on hover/press/state changes.

Long-press behavior:

- Pure video card: long press toggles favorite.
- Mixed media card, such as mixed media: long press opens secondary detail WebView sheet.
- Comic/image content: keep navigation/detail behavior aligned with reader needs.

## Visual Tokens

These are design targets, not mandatory hard-coded values.

### Radius

- Full sheet / large container: 28-38 pt
- Media thumbnail: 14-20 pt
- Small icon image / app icon: 10-14 pt
- Chips / controls: capsule when system-like, otherwise 8-12 pt
- Repeated content cards: avoid outer card where possible; if needed, max 8-12 pt

### Spacing

- Screen horizontal padding: 14-18 pt on iPhone
- Grid gap: 10-14 pt
- Card title top gap: 6-8 pt
- List row horizontal gap: 10-14 pt
- Sheet footer padding: 12-18 pt

### Typography

Use SF/PingFang system typography through SwiftUI defaults where possible.

- Large title only on root/exploration screens.
- Inline title on deep browsing screens.
- Grid card title: 13-15 pt, medium/semibold, 2 lines.
- Metadata: 11-12 pt, secondary.
- Buttons: system button styles unless there is a clear media/player need.

Avoid:

- viewport-scaled font sizes
- negative letter spacing
- hero-scale text inside compact cards
- explanatory feature text inside the app UI

### Color

Use system semantic colors first:

- primary / secondary / tertiary text
- system background / secondary system background
- separator
- accent color

Use site/content color only as accent, not full theme. Thumbnails and real media should provide color.

Avoid dominant:

- purple-blue gradients across the whole app
- beige/brown editorial pages
- dark blue/slate dashboards
- excessive pink/purple neon

## Screen Patterns

### Site Library

Goal: browsing configured sites should feel like choosing a content source, not editing settings.

Recommended structure:

1. Large title: "网站" or "站点"
2. Search
3. Optional curated/site status entry
4. Horizontal shelves for quick entry points
5. Inset grouped list for all sites

Rows:

- favicon/category icon
- site name
- subtitle: host + parser behavior or latest category
- category chip
- context menu/swipe actions for edit/rules/delete

Do not make every site a large promotional card.

### Recent Updates / Video Gallery

Goal: fast scanning, quick play, easy favorite.

Recommended structure:

1. Inline/floating navigation title with site/category context
2. Compact filters: latest, subtitles, hot, favorites, categories
3. Optional feature card only if it represents real "top/new/continue" content
4. Two-column media grid by default
5. Footer state: loading more / retry / page indicator

Card content:

- thumbnail, 16:9 or 16:10
- duration badge bottom trailing
- favorite state top trailing
- type badge only when mixed content needs distinction
- title below, 2 lines max
- metadata row: one or two chips max, such as actor and tag

Avoid:

- too many chips
- titles overlaid on thumbnails by default
- thick outer card backgrounds
- random masonry if content titles are important

Possible modes:

- Default: two-column information grid.
- Immersive: Photos-like dense grid for pure browsing.
- Compact: list mode for low-thumbnail or text-heavy sites.

### Mixed Media Detail, mixed media

Current pragmatic direction:

- Open a secondary WebView sheet on long press.
- Keep bottom favorite button.
- Do not attempt brittle DOM extraction unless a dynamic rule system exists.

Sheet structure:

- grabber
- compact header: close, title/domain/loading, Safari/open action
- WebView fills content area
- bottom favorite action

If later adding dynamic rules, build it as a separate parser configuration system with debug tools, not ad hoc hardcoded JS in the view.

### Video Detail / Player

Pure video should not feel like a web page.

Recommended structure:

- Full-screen or large-sheet player
- Large media surface first
- title and metadata below player
- simple transport controls
- actions: favorite, share/open, download if supported
- related/next items below only if useful

Avoid putting video playback inside a decorative card.

### Favorites

Goal: a saved library, not a queue.

Recommended structure:

- segmented control: videos / comics / mixed
- sort/filter menu
- grid matching source media
- empty state with clear CTA

### NAS / Files

Goal: operational file browser.

Recommended structure:

- list or grid toggle
- path breadcrumb
- sorting
- file type icons/thumbnails
- compact rows

Avoid entertainment styling here.

## Prototype Workflow

When creating a design prototype:

1. Define the screen goal in one sentence.
2. Name the real reference pattern, such as "Photos media grid" or "App Store Today shelf".
3. Make 2-3 variants for uncertain screens.
4. Use realistic UI labels in Chinese.
5. Use realistic state and metadata, not lorem ipsum.
6. Render and visually inspect via browser/simulator screenshot.
7. Ask: "What still looks AI-generated?"
8. Remove decoration before adding more style.

Prototype artifacts live under:

- `design/`
- `design/references/` for screenshots/notes when available

Do not treat HTML mockups as production implementation. They are review artifacts only.

## Visual Review Checklist

Before proposing a UI change, check:

- Does this screen look like a native iOS app, not a web landing page?
- Is real content the visual focus?
- Are there too many gradients, glass layers, shadows, or chips?
- Are controls familiar and predictable?
- Is text clipped or overcrowded on iPhone width?
- Are touch targets stable and large enough?
- Does the design still work with missing thumbnails, long titles, or no metadata?
- Does the layout support both light and dark mode, even if mockup is light?
- Is there a clear empty/loading/error state?
- Could this be implemented with existing SwiftUI system components?

## Implementation Rules

When translating design into SwiftUI:

- Prefer existing app patterns and shared components.
- Prefer system components over custom replicas.
- Keep card components stable in size.
- Use semantic colors and materials.
- Use `.foregroundColor(.accentColor)` where project constraints require it.
- Do not introduce new Swift files without running `xcodegen generate`.
- Verify with simulator screenshots for any substantial UI change.

## Current Design Decisions

- Queue feature is removed.
- Pure video long press toggles favorite.
- mixed media/mixed-media long press opens secondary WebView sheet.
- DOM extraction for dynamic mixed media is deferred until there is a proper rule system.
- The design direction is closer to App Store + Photos + video player than to a custom dashboard.

## Open Questions

- Should the site library use an App Store-like curated top section, or stay closer to a settings list?
- Should recent updates keep a feature card, or maximize density with only a grid?
- Should recent updates offer a Photos-like dense mode in addition to the default two-column grid?
- Should pure video detail become a dedicated player-first view?
- Should mixed media detail add Safari/open/refresh controls in the sheet header?

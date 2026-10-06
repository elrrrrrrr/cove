# Cove — iOS App

## Build

```sh
cd EasyReader
xcodegen generate
open EasyReader.xcodeproj
```

Always run `xcodegen generate` after adding/removing/moving Swift files. `project.yml` is the single source of truth for targets, dependencies, resources, scripts and settings.

## Stack and conventions

- SwiftUI + SwiftData, iOS 26+, Swift 6 strict concurrency.
- SPM: AMSMB2 (SMB), ZIPFoundation (CBZ/EPUB), Yams (`.site` YAML).
- UI labels and descriptions are Chinese.
- Use `@Observable @MainActor` for view-model-like objects; use actors for SMB and cache internals.
- Use `.foregroundColor(.accentColor)`, not `.foregroundStyle(.accentColor)`.
- AMSMB2 downloads use `downloadItem(atPath:to:progress:)`; URLs are `smb://host`, with share passed to `connectShare(name:)`.
- NAS uses SMB only. Passwords stay in Keychain. Legacy remote-config fields exist solely for stored-data compatibility.
- Thumbnail cache has synchronous NSCache, actor LRU, and disk layers. Preserve eviction and range-reading behavior.

## Structure

`EasyReader/Sources/EasyReader/` contains `App/`, `Models/`, `Features/` and `Shared/`.

- `Features/WebReader/`: site schema, registry, persistence, selector/JS engine, setup wizard, gallery, video extraction, content blocker.
- `Features/Comic/`: configuration-driven metadata and chapter image readers.
- `Features/Readers/`: PDF, CBZ, EPUB, TXT and video readers.
- `Features/NAS/`: SMB browsing, streaming, images, audio and thumbnails.
- Other feature directories cover Home, Favorites, History and Settings.
- SwiftData models: ReadingHistory, BookmarkSite, FavoriteVideo, OfflineItem, NASConfig; register new models in EasyReaderApp.

## Site independence

Real site names, domains, selectors, endpoints and transformation parameters belong in complete `.site` YAML files, never in Swift branches. Add a site by importing a definition or placing it in ignored root `sites/`. Extend generic capabilities only as required. See `docs/site-format.md`.

A definition has stable `id`, entries and role-specific rules. Common extraction uses CSS; optional JavaScript produces the same result structure. Carry `definitionID` through sub-navigation, favorites, history and media/chapter loading.

Root `sites/`, `data/`, `config/` are private and ignored. Optional `data/favorites.json` and site files import only on a fresh installation, once; an empty collection must never trigger reseeding. App persistent data lives under Application Support/Cove/config and data. Preserve existing data and stable identities during migration and backup import.

Public export uses `scripts/export-public-repo.py` to create a separate new Git repository. Keep the original development repository/history intact.

## Validation

Tests use reserved example domains and offline HTML fixtures. Cover schema errors, domain boundaries, CSS and asynchronous JS output, pagination, chapters, once-only bootstrap, migration, data merging and backup identity. Build both with and without private folders after resource-script changes.

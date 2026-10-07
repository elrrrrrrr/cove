> 历史候选：本文记录被回退的 v2 重构分支，不是当前恢复版的界面或数据契约。当前版本见 [恢复记录](ui-recovery.md)。

# Cove resource architecture

This rebuild uses a new `.site` schema and a new library store. It does not read the previous schema or migrate the previous database. Private definitions remain outside Git; convert their editable files explicitly when developing locally.

## Boundaries

- `SourceDefinition`: one files, SMB or web source, named entries, optional modules, presentation defaults. `.site` is portable YAML; credentials and folder authorization are separate local bindings.
- `SourceProvider`: list, search, resolve. Lists return stable `ResourceItem` identities and explicit pagination cursors. Resolving returns typed content, independent of its source.
- `ResourceAccess`: file access, bounded downloads to disk, HTTP validation, cancellation and temporary-file ownership. Video and audio use file/HTTP URLs or SMB range streaming.
- `ArchiveService`: registered decoders, containment checks, extraction limits, owned working directories. ZIP comics and EPUB share this service; registering an actual RAR decoder is the extension point for CBR/RAR.
- `LibraryStore`: one SwiftData model for every resource kind, favorites, recent activity and progress. Identity includes source and locator; temporary stream URLs never become identities.
- `BrowserModel`: collection context, search, append pagination and stable selection. No reader or card manages network pagination itself.
- `ReaderRouter`: native readers consume resolved content. A video feed owns a playback sequence and at most one active player; next-list-item and next-episode are separate operations.

## Configuration and UI

Schema version 2 supports CSS shorthand (`.title`, `a@href`, `.tag[]`) and full field objects for nested extraction, fallbacks and regex captures. Async JS returns the same payload as CSS. Rules can select variants by URL path. Modules cover catalog, pagination, search, login, video, comic, chapter, portal and image transforms.

Adding a source starts with its adapter, then a small set of enabled modules. The wizard offers visual field picking, content cards, pagination/search tests, and YAML/JS editing. Presentation selects existing native layouts and interactions; it cannot inject native UI code.

Root navigation: Home, Sources, Favorites, Settings. Files and SMB appear alongside web sources. Each collection uses a consistent browser; controls only appear for available capabilities. Card opening, tag search and favorite actions have separate hit targets.

## Completion checks

- No unconditional certificate acceptance; ATS stays enabled with explicit local-network intent.
- URL-derived cache names are hashes; extraction and publication exclusions have regression tests.
- Archives reject traversal, escaping symlinks and unsafe document references before writing or reading.
- SMB video opening from any entry point uses range streaming; large documents download to disk, never whole-file `Data`.
- Progress/favorites upsert by stable resource identity. Filtered reordering preserves other sources' positions.
- Sources import once, including an empty initial bundle; deleting a source never reseeds it.
- Offline schema/provider/library tests plus simulator wizard, source browsing and native reader checks.
- Builds succeed with and without private `sites/` and `data/`. GitHub remains private.

## Performance contracts

- A source provider owns one immutable definition snapshot. URL rule selection and extraction-script construction happen on navigation, never in SwiftUI `body`.
- Browser rows receive prepared metadata, tags and library state. Collection filtering/reordering happens on input changes.
- The image pipeline retains L0 cost-bounded decoded thumbnails, L1 byte-bounded encoded data and L2 indexed disk entries. Decode at requested pixel dimensions; keys include source, definition revision, request context, target size and file revision.
- SMB folder pages have a bounded 60-second cache. Catalog disk entries have a 24-hour TTL and storage limits. Disk accounting updates incrementally rather than enumerating on every write.
- File decoding/reading and TXT chapter recognition run off the main actor. Comic pages share the image pipeline and prefetch immediate neighbors.
- Shared image work has cancellable subscribers and bounded concurrency. SMB range-reader requests cancel their work. Playback teardown cancels stale resolutions and pauses the previous player.
- Loading UI uses one progress presentation. Diagnostics are bounded. Async refresh waits on a task, not a polling loop.

## Review amendments

The earlier external v1.0 proposal is background material, not this rebuild's contract. Schema 2 and a new store replace its compatibility and old-navigation requirements.

- Each web source has a persistent WebKit profile. The visual picker, login browser and renderer share that source's profile. A session epoch changes on explicit login completion/credential changes; cookie context is also included in image keys. Cache data cannot cross sources/accounts.
- Remote decoded/encoded image hits obey TTL. No ETag-based behavior is claimed without conditional revalidation. Full URL, cookie/header context, file size/mtime, pixels and transformation revision form cache identity.
- Disk index initialization performs bounded reconciliation. Crash-lost index writes can discard cache files safely; app data is never a cache recovery target.
- LibraryStore is a public application service on MainActor with a single UI context. Background code receives DTOs and immutable snapshots, never SwiftData model objects. Mutations commit before UI indexes are rebuilt; failed transactions roll back.
- Normal web pages and DOM/AJAX extraction permit the configured web session's scripts. EPUB uses a separate nonpersistent session, disables content JavaScript, confines document references, and rejects external navigation.
- NSCache cost limits are soft budgets, not a promise about process RSS. Encoded buffers, in-flight decodes, visible images and decoder overhead must be measured separately. Network and decode concurrency have distinct caps.
- No background/resumable-download guarantee is made for the current foreground resource loader. Its contract is cancellation, validated response, size limit, unique temporary destination, atomic publication and failure cleanup.
- File length is a responsibility-splitting signal, not a mechanical acceptance rule. Necessary list descriptions and small state transitions are allowed in body; repeated full-table derivation, IO and decoding are not.
- Performance verification records simulator/device, workload, target pixels, cold/warm cache and network conditions. Report measurements and limitations; do not infer a frame-rate improvement from annotations alone.

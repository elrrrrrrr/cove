# Cove — resource browser

## Build
SwiftUI + SwiftData, iOS 26+, Swift 6 strict concurrency. XcodeGen project.yml is the source of truth. Always run xcodegen generate after adding/removing/moving Swift files. Dependencies: AMSMB2, ZIPFoundation, Yams.

## Structure
- Core/: source schema, stable resource DTOs, access, archives, content policy, indexed caches, image/SMB streaming.
- Sources/: files/SMB/web adapters, source persistence, source-scoped WebKit sessions.
- Library/: public MainActor application services and SwiftData LibraryEntry; favorites, history, offline storage.
- Browser/: collection state and browsing UI; derive indexes/filtering on changes, not repeatedly in body.
- Readers/: typed native reading/playback and a single active feed session.
- Setup/: source wizard, field picker, YAML/JS editor.
- App/ and Settings/: root shell and preferences.

## Contracts
New .site schemaVersion 2 and Cove2 store; no old schema/database compatibility. CSS shorthand and JS produce the same payload. A source has adapter, entries, optional modules and presentation. Resource identity is source + stable identity/locator; content version is separate. Never use temporary media URLs or unpacked UUIDs as content identity.

SwiftData models stay on MainActor. Background work receives Sendable DTOs, never a UI ModelContext/@Model instance. LibraryStore owns its context/container, commits transactions, rolls back failures, and maintains UI indexes. Provider registry is weak; browsers/readers/playback own their provider leases.

UI language Chinese. Use @Observable @MainActor and foregroundColor(.accentColor). Feature views consume services and prepared state; no disk IO, parsing, full-table derivation or decoding in body. Small layout/list descriptions are allowed.

WebKit runs on MainActor with per-source persistent profiles. Preserve DOM/Cookie/AJAX context. EPUB uses no page JS, no external network, contained document references and owned extraction cleanup. Always use default TLS validation; no broad trust challenge handling.

Images: ImageIO thumbnails with orientation and explicit pixels, cost-budgeted decoded cache, byte-budgeted encoded actor cache, indexed disk limits/TTL. Keys include source/session/config/request context, pixel target, asset size/mtime and transforms. Shared cancellation removes only one subscriber; cancel the work after the last subscriber leaves. NSCache limits are soft, not an RSS guarantee.

SMB: smb://host, share passed to connectShare; credentials in Keychain. Stream video/audio with bounded range reads. Download documents to disk using downloadItem(atPath:to:progress:), never whole-file Data. Foreground downloads validate HTTP, enforce size limits while arriving, cancel old work before retry, publish atomically, and persist relative paths. Do not claim background resume support.

Archives reject traversal, absolute paths, symlinks, unsafe EPUB container/manifest references and expansion limits before writing. A decoder registration is a native capability; config alone cannot add RAR support.

Root sites/, data/, config/ and non-example .site files are ignored. Real domains/selectors/transformation keys belong only in private definitions. Only examples/sites and Tests/Fixtures/Sites contain reserved fictional definitions. Bundled content imports once, even if initially empty; never reseed after deletion.

## Validation
Tests use offline fixtures and localhost. Cover keys/session isolation/TTL, shared cancellation, archive and document boundaries, stable identities and rollback, directories, bounded media reads and wizard/card/feed interactions. Run builds with and without private seed folders. Visually inspect meaningful UI changes. Separate own-source warnings from dependency/SDK messages. Keep GitHub Private until explicitly authorized otherwise.

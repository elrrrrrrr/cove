# Cove — iOS resource browser

## Build
SwiftUI + SwiftData, iOS 26+, Swift 6 strict concurrency. Dependencies: AMSMB2, ZIPFoundation, Yams. project.yml is the source of truth. Run xcodegen generate after adding, removing or moving Swift files.

## Structure
- App/: application and root navigation.
- Models/: bookmarks, favorites, history, offline files and SMB configuration.
- Features/: Home, Favorites, History, Settings, NAS, WebReader, Comic and native Readers.
- Shared/: reusable components, caches, file access and downloads.

## Contracts
Only one current configuration format: schemaVersion 1 for .site, favorites JSON and configuration backups. Do not introduce parallel schemas, stores, version switches or unused compatibility wrappers. Site definitions have stable id, matching, entries and parsing rules; CSS and JavaScript use the same output contract.

Application data uses Application Support/Cove/config and data. Preserve existing user records and identifiers. Keep SwiftData on MainActor; background tasks receive immutable values. SMB passwords stay in Keychain; backups preserve NAS UUIDs and never include passwords.

Keep the current home, thumbnails, Bento/portrait/list layouts, category/search/pagination tools, favorites, readers and SMB capabilities when changing architecture or performance. Establish feature parity with the same configuration and data. UI labels are Chinese. Use @Observable @MainActor and foregroundColor(.accentColor).

Private domains, selectors and transformation parameters belong in private .site files. Root sites/, data/, config/ and non-example .site files are ignored. Bundled definitions and optional favorites import once; deletion never triggers reseeding. Examples use reserved fictional domains, except the user-approved public Hacker News teaching definition and loopback-only local demos. Offline fixtures and screenshots use synthetic content; account credentials never enter examples.

Use default TLS verification. Cache writes use URL hashes; contained legacy cache reads must reject traversal and symlinks. Archives and EPUB references remain within owned directories and enforce expansion limits. Disable EPUB content JavaScript. ReaderFileSafety contains shared path checks.

SMB uses smb://host and connectShare(name:). Stream media with bounded range requests. Download files to disk with downloadItem(atPath:to:progress:) rather than loading whole videos into Data. Credentials and local authorization never appear in portable configuration.

## Validation
Use offline fixtures and localhost. Cover schema round trips and rejection, entry identity, once-only initialization, backup consistency, CSS/JS extraction and resource boundaries. Validate changes with and without private seed folders. Check meaningful UI changes against existing layouts and data; passed parser tests do not establish UI parity. Separate own-source warnings from dependency/SDK warnings. GitHub stays Private until the user explicitly asks otherwise.

# Cove interface

Cove is a native iOS resource browser. Use system navigation, menus, lists and media surfaces; Chinese labels and semantic colors. Each screen has one primary structure.

- Home: compact continue-reading and recent activity with source/offline shortcuts.
- Sources: one list for folders, SMB and web; adapter filter and explicit add/import.
- Collection: one grid/portrait/list layout, capability-based search/login/pagination/original-page actions.
- Resource cards: separate open, tag and favorite buttons. No parent tap competing with child actions.
- Reader: content first, compact native controls. Video feed is vertical paging, one active player.
- Music: persistent shared audio session with mini-player after leaving its page.
- Setup: Source → Modules → Preview → Advanced. Visible field labels, CSS shorthand, point picking, card results, pagination/search tests. Full YAML and JS are optional advanced paths.
- Settings: grouped form.

Use native SwiftUI components. Avoid decorative gradients, nested cards and repeated per-cell shimmer. Use one loading presentation per collection. Prefer data/model boundaries over mechanical file-length limits. Screenshots on iPhone and iPad are required for substantial UI changes.

HTML prototypes under design/ are historical references and do not define the current implementation.

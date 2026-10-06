import Foundation

// ═══════════════════════════════════════════════════════════════════
// Generic catch-all heuristic
// ═══════════════════════════════════════════════════════════════════

extension SiteParser {
    static let generic = SiteParser(
        hostPattern: "",    // matches everything not claimed above
        itemKind: .video,
        preNavigateJS: nil,
        waitSeconds: 2.0,
        extractItemsJS: SiteParser.genericExtractItemsJS,
        paginationMode: .webNavigation(nextPageJS: SiteParser.genericNextPageJS)
    )

    // ─────────────────────────────────────────────────────────────────
    // Shared generic "find next page link" JS
    // ─────────────────────────────────────────────────────────────────
    static let genericNextPageJS = """
    (function() {
        const rel = document.querySelector('link[rel="next"]');
        if (rel?.href) return rel.href;
        const kw = [/\\bnext\\b/i, /下一页/, /›|»/];
        const links = [...document.querySelectorAll('a[href]')];
        for (const k of kw) {
            const a = links.find(el => k.test(el.textContent.trim()) && !el.href.match(/#$/));
            if (a) return a.href;
        }
        const cur = parseInt(
            document.querySelector('.pagination .active a, .page-item.active a, .current-page')
                    ?.textContent?.trim(), 10);
        if (!isNaN(cur)) {
            const a = links.find(el => parseInt(el.textContent.trim(), 10) === cur + 1);
            if (a) return a.href;
        }
        return null;
    })()
    """

    // ─────────────────────────────────────────────────────────────────
    // Shared generic extraction JS
    // Tries a ranked list of container selectors; picks the one with the
    // most valid (link + image) children. Also handles CSS background-image
    // thumbnails as fallback.
    // ─────────────────────────────────────────────────────────────────
    static let genericExtractItemsJS = """
    (function() {
        const selectors = [
            '.post-card-container',
            '.video-list-item', '.video-item', '.video-card', '.thumb-item',
            '.col-6', '.col-4', '.col-3', '.col-sm-4', '.col-lg-3',
            'article', '.item', '.card', '.media-item', '.post-item'
        ];

        let best = [], bestScore = 0;
        for (const sel of selectors) {
            const els = [...document.querySelectorAll(sel)];
            const score = els.filter(el => el.querySelector('a') && el.querySelector('img')).length;
            if (score > bestScore) { bestScore = score; best = els; }
        }
        if (bestScore === 0) return JSON.stringify([]);

        const items = [];
        best.forEach(el => {
            const a     = el.querySelector('a[href]');
            const img   = el.querySelector('img');
            const title = el.querySelector('h1,h2,h3,h4,h5,h6,[class*="title"],[class*="name"]');
            const dur   = el.querySelector('[class*="duration"],[class*="time"],[class*="label"],.badge');

            const url  = a?.href || '';
            const text = (title?.textContent || img?.alt || a?.title || '').trim();

            // Thumbnail: <img> attrs → CSS background-image fallback
            let thumb = img?.dataset?.src || img?.dataset?.lazySrc
                      || img?.dataset?.original || img?.dataset?.echo || img?.src || '';
            if (!thumb) {
                const bgEl  = el.querySelector('[style*="background-image"]');
                const bgStr = bgEl?.style?.backgroundImage || '';
                if (bgStr.includes('url(')) {
                    thumb = bgStr.split('(')[1].split(')')[0].replace(/"/g, '');
                }
            }

            if (url && text && !url.match(/^(#|javascript)/)) {
                items.push({ title: text, url, thumbnail: thumb,
                             duration: (dur?.textContent || '').trim(), extra: '' });
            }
        });

        const seen = new Set();
        return JSON.stringify(
            items.filter(i => seen.has(i.url) ? false : (seen.add(i.url), true)).slice(0, 100)
        );
    })()
    """
}

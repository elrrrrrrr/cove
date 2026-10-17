import Foundation

struct ArticleDocument: Hashable, Sendable, Codable {
    let title: String
    let author: String
    let publishedAt: String
    let sourceURL: URL?
    let commentsURL: URL?
    let blocks: [ArticleBlock]

    init(title: String, author: String, publishedAt: String, sourceURL: URL?, commentsURL: URL?, blocks: [ArticleBlock]) {
        self.title = title; self.author = author; self.publishedAt = publishedAt
        self.sourceURL = sourceURL; self.commentsURL = commentsURL; self.blocks = blocks
    }

    static func decode(_ data: Data, base: URL, fallbackTitle: String) throws -> Self {
        guard data.count <= 2 * 1024 * 1024 else { throw SiteDefinitionError.invalid("图文内容超过大小限制") }
        let raw = try JSONDecoder().decode(RawArticle.self, from: data)
        return try build(raw, base: base, fallbackTitle: fallbackTitle)
    }

    static func build(_ raw: RawArticle, base: URL, fallbackTitle: String) throws -> Self {
        guard raw.blocks.count <= 2000 else { throw SiteDefinitionError.invalid("图文块数量超过限制") }
        var characters = 0
        let blocks = try raw.blocks.enumerated().compactMap { index, block -> ArticleBlock? in
            guard let kind = ArticleBlock.Kind(rawValue: block.type) else { throw SiteDefinitionError.invalid("未知图文块类型：\(block.type)") }
            var attributed = AttributedString()
            for run in block.runs ?? [.init(text: block.text ?? "", url: nil)] {
                characters += run.text.count
                var text = AttributedString(run.text)
                text.link = address(run.url, base: base)
                attributed.append(text)
            }
            guard characters <= 1_000_000 else { throw SiteDefinitionError.invalid("正文文字超过限制") }
            let blockURL = address(block.url, base: base)
            if kind == .image || kind == .link {
                guard blockURL != nil else { return nil }
            } else if String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            return ArticleBlock(id: "block-\(index)", kind: kind, text: attributed, url: blockURL,
                alt: String((block.alt ?? "").prefix(1024)), level: min(6, max(1, block.level ?? 2)),
                aspectRatio: (block.width ?? 0) > 0 && (block.height ?? 0) > 0 ? min(100, max(0.01, block.width! / block.height!)) : 16.0 / 9)
        }
        let source = address(raw.sourceURL, base: base)
        guard !blocks.isEmpty || (source != nil && source != base) else { throw SiteDefinitionError.invalid("此页未提取到正文，可查看原始网页") }
        return Self(title: String((raw.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? raw.title! : fallbackTitle).prefix(4096)),
            author: String((raw.author ?? "").prefix(1024)), publishedAt: String((raw.publishedAt ?? "").prefix(1024)),
            sourceURL: source, commentsURL: address(raw.commentsURL, base: base), blocks: blocks)
    }

    init(from decoder: Decoder) throws {
        let raw = try RawArticle(from: decoder)
        self = try Self.build(raw, base: URL(string: "https://example.invalid")!, fallbackTitle: "图文")
    }

    func encode(to encoder: Encoder) throws {
        try RawArticle(title: title, author: author, publishedAt: publishedAt,
            sourceURL: sourceURL?.absoluteString, commentsURL: commentsURL?.absoluteString,
            blocks: blocks.map { block in
                RawArticleBlock(type: block.kind.rawValue, text: nil,
                    runs: block.text.runs.map { ArticleRun(text: String(block.text[$0.range].characters), url: $0.link?.absoluteString) },
                    url: block.url?.absoluteString, alt: block.alt, level: block.level, width: block.aspectRatio, height: 1)
            }).encode(to: encoder)
    }

    func snapshotData() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 2 * 1024 * 1024 else { throw SiteDefinitionError.invalid("图文快照超过大小限制") }
        return data
    }

    static func address(_ value: String?, base: URL) -> URL? {
        guard let value, !value.isEmpty, value.utf8.count <= 32_768,
              let url = URL(string: value, relativeTo: base)?.absoluteURL,
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}

struct ArticleBlock: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case paragraph, heading, image, quote, code, link }
    let id: String
    let kind: Kind
    let text: AttributedString
    let url: URL?
    let alt: String
    let level: Int
    let aspectRatio: Double
}

struct RawArticle: Codable {
    let title: String?
    let author: String?
    let publishedAt: String?
    let sourceURL: String?
    let commentsURL: String?
    let blocks: [RawArticleBlock]
}
struct RawArticleBlock: Codable {
    let type: String
    let text: String?
    let runs: [ArticleRun]?
    let url: String?
    let alt: String?
    let level: Int?
    let width: Double?
    let height: Double?
}
struct ArticleRun: Codable { let text: String; let url: String? }

/// Generic DOM-to-block conversion. Site selectors remain in configuration.
enum ArticleDOM {
    static let script = #"""
    function readArticleContent(root) {
        if (!root) return [];
        const blocks = []; let runs = [], type = 'paragraph', level = 2, characters = 0;
        const preserveWhitespace = ['pre','pre-wrap','break-spaces'].includes(getComputedStyle(root).whiteSpace);
        const ignored = new Set(['SCRIPT','STYLE','IFRAME','FORM','INPUT','BUTTON','NAV','FOOTER','NOSCRIPT','TEMPLATE']);
        const containers = new Set(['P','DIV','SECTION','ARTICLE','MAIN','UL','OL','LI','TABLE','TR','TD']);
        function address(value) {
            if (!value || value.length > 32768) return null;
            try { const u = new URL(value, document.baseURI); return ['http:','https:'].includes(u.protocol) && !u.username && !u.password ? u.href : null; }
            catch (_) { return null; }
        }
        function flush() {
            if (runs.length && runs.map(r => r.text).join('').trim()) {
                runs[0].text = runs[0].text.replace(/^\s+/, '');
                runs[runs.length - 1].text = runs[runs.length - 1].text.replace(/\s+$/, '');
                blocks.push({type, runs, level});
                if (blocks.length > 2000) throw new Error('图文块数量超过限制');
            }
            runs = [];
        }
        function walk(node, link = null) {
            if (node.nodeType === 3) {
                const text = type === 'code' || preserveWhitespace ? node.textContent : node.textContent.replace(/\s+/g, ' ');
                characters += text.length;
                if (characters > 1000000) throw new Error('正文文字超过限制');
                if (text) runs.push({text, url: link});
                return;
            }
            if (node.nodeType !== 1 || ignored.has(node.tagName) || node.hidden || node.getAttribute('aria-hidden') === 'true') return;
            if (node.tagName === 'IMG') {
                flush(); const url = address(node.currentSrc || node.getAttribute('src') || node.getAttribute('data-src'));
                if (url) blocks.push({type:'image', url, alt:node.getAttribute('alt') || '', width:node.naturalWidth || Number(node.getAttribute('width')) || 0, height:node.naturalHeight || Number(node.getAttribute('height')) || 0});
                if (blocks.length > 2000) throw new Error('图文块数量超过限制');
                return;
            }
            if (node.tagName === 'BR') { runs.push({text:'\n', url:link}); return; }
            const heading = /^H[1-6]$/.test(node.tagName);
            const boundary = containers.has(node.tagName) || heading || ['PRE','BLOCKQUOTE'].includes(node.tagName);
            const oldType = type, oldLevel = level;
            if (boundary) flush();
            if (heading) { type = 'heading'; level = Number(node.tagName[1]); }
            else if (node.tagName === 'PRE') type = 'code';
            else if (node.tagName === 'BLOCKQUOTE') type = 'quote';
            const target = node.tagName === 'A' ? address(node.getAttribute('href')) : link;
            for (const child of node.childNodes) walk(child, target);
            if (boundary) flush();
            type = oldType; level = oldLevel;
        }
        walk(root); flush(); return blocks;
    }
    """#
}

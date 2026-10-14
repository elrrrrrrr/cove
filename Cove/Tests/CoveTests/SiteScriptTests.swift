import XCTest
import WebKit
@testable import Cove

@MainActor final class SiteScriptTests: XCTestCase {
    private func execute(_ extraction: SiteExtraction, html: String) async throws -> Any {
        let page = FixturePage()
        try await page.load(html)
        let output = try await WebScript.string(extraction.javascript, in: page.webView)
        withExtendedLifetime(page) {}
        let text = try XCTUnwrap(output)
        return try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    func testCSSReadsLazyImageAndResolvesRelativeSignedLinks() async throws {
        let extraction = SiteDefinition.starter(name: "示例", url: URL(string: "https://media.example/latest/")!).rules[0].extract!
        let html = #"<article class="card"><a class="title" href="/watch/1?token=a&amp;part=2">标题</a><img data-src="/covers/1.jpg"></article>"#
        let object = try await execute(extraction, html: html)
        let values = try XCTUnwrap(object as? [[String: Any]])
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values[0]["title"] as? String, "标题")
        XCTAssertEqual(values[0]["url"] as? String, "https://media.example/watch/1?token=a&part=2")
        XCTAssertEqual(values[0]["thumbnail"] as? String, "https://media.example/covers/1.jpg")
    }

    func testCustomAsyncJavaScriptUsesSameResultContract() async throws {
        let extraction = SiteExtraction(script: "await Promise.resolve(); return [{title:'脚本内容',url:new URL('/watch/2',document.baseURI).href}];")
        let object = try await execute(extraction, html: "<main></main>")
        let values = try XCTUnwrap(object as? [[String: Any]])
        XCTAssertEqual(values[0]["title"] as? String, "脚本内容")
        XCTAssertEqual(values[0]["url"] as? String, "https://media.example/watch/2")
    }

    func testComicChaptersAndImagesUseNestedCSSFields() async throws {
        let chapters = SiteExtraction(fields: ["chapters": SiteField(selector: "a.chapter", all: true, fields: [
            "title": SiteField(text: true), "url": SiteField(attribute: "href", resolveURL: true)
        ])])
        let object = try await execute(chapters, html: #"<a class="chapter" href="/chapter/1">第一章</a><a class="chapter" href="/chapter/2">第二章</a>"#)
        let result = try XCTUnwrap(object as? [String: Any])
        let values = try XCTUnwrap(result["chapters"] as? [[String: Any]])
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[1]["url"] as? String, "https://media.example/chapter/2")
        let images = SiteExtraction(fields: ["images": SiteField(selector: "main img", attribute: "src", all: true)])
        let imageObject = try await execute(images, html: #"<main><img src="//images.example/1.jpg"><img src="/2.jpg"></main>"#)
        let imageResult = try XCTUnwrap(imageObject as? [String: Any])
        XCTAssertEqual(imageResult["images"] as? [String], ["https://images.example/1.jpg", "https://media.example/2.jpg"])
    }

    func testNumericEpisodeFieldsAndInvalidCSS() async throws {
        let extraction = SiteExtraction(fields: ["episodeCount": SiteField(selector: ".count", text: true)])
        let object = try await execute(extraction, html: "<span class='count'>12</span>")
        let value = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(value["episodeCount"] as? Int, 12)
        do {
            _ = try await execute(.init(items: "[", fields: ["title": .init(text: true)]), html: "<main></main>")
            XCTFail("Invalid CSS must report an error")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }

    func testCSSNextLinkAndLegacyExpressions() async throws {
        var definition = SiteDefinition.starter(name: "示例", url: URL(string: "https://media.example/latest/")!)
        definition.rules[0].pagination = .init(mode: "nextLink", selector: "a[rel=next]")
        let parser = SiteParserRegistry.parser(definition: definition, rule: definition.rules[0])
        let page = FixturePage(); try await page.load(#"<a rel="next" href="/latest/2/">下一页</a>"#)
        if case .webNavigation(let script) = parser.paginationMode {
            let next = try await WebScript.string(script, in: page.webView)
            XCTAssertEqual(next, "https://media.example/latest/2/")
        } else { XCTFail("Expected next-link pagination") }
        let legacy = SiteExtraction(expression: "JSON.stringify([{title:'旧脚本',url:'https://media.example/watch/1'}])")
        let legacyResult = try await execute(legacy, html: "<main></main>")
        XCTAssertEqual((legacyResult as? [[String: Any]])?.count, 1)
    }

    func testBundledDefinitionsAndScriptsValidateWithoutNetwork() async throws {
        let bundle = Bundle(for: SiteDefinitionStore.self)
        let bundled = SiteDefinitionStore.bundledDefinitions(bundle: bundle)
        XCTAssertTrue(bundled.issues.isEmpty, bundled.issues.joined(separator: "\n"))
        let page = FixturePage(); try await page.load("<main></main>")
        for definition in bundled.definitions {
            for rule in definition.rules {
                var expressions = [rule.extract?.javascript, rule.pagination?.expression, rule.load?.preNavigateExpression].compactMap { $0 }
                for (body, parameters) in [(rule.pagination?.script, "page"), (rule.pagination?.thumbnailScript, "page"), (rule.load?.preNavigateScript, ""), (rule.load?.transformScript, "html")] {
                    if let body { expressions.append("(async function(\(parameters)){\n" + body + "\n})") }
                }
                for expression in expressions {
                    let result = try await page.webView.callAsyncJavaScript("new Function('return (' + source + ');'); return true;", arguments: ["source": expression], in: nil, contentWorld: .page)
                    XCTAssertEqual(result as? Bool, true, "\(definition.id)/\(rule.id)")
                }
            }
        }
    }

    func testPagePointSelectionProducesReusableRelativeSelectors() async throws {
        let picker = SiteElementPicker()
        let page = FixturePage(webView: picker.webView)
        try await page.load(#"<article class="card"><span class="title">第一项</span><a href="/watch/1">打开</a></article><article class="card"><span class="title">第二项</span></article>"#)
        _ = try await picker.webView.callAsyncJavaScript("window.__covePickField='items'; document.querySelector('.title').click();", arguments: [:], in: nil, contentWorld: .page)
        for _ in 0..<100 {
            if picker.selection != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let card = try XCTUnwrap(picker.selection)
        XCTAssertEqual(card.field, "items")
        let count = try await picker.webView.callAsyncJavaScript("return document.querySelectorAll(selector).length;", arguments: ["selector": card.selector], in: nil, contentWorld: .page)
        XCTAssertEqual(count as? Int, 2)
        picker.selection = nil
        _ = try await picker.webView.callAsyncJavaScript("window.__covePickField='title'; window.__covePickItems=items; document.querySelector('.title').click();", arguments: ["items": card.selector], in: nil, contentWorld: .page)
        for _ in 0..<100 {
            if picker.selection != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let title = try XCTUnwrap(picker.selection)
        XCTAssertEqual(title.field, "title")
        XCTAssertEqual(title.value, "第一项")
        let relative = try await picker.webView.callAsyncJavaScript("return document.querySelector(items).querySelector(selector).textContent;", arguments: ["items": card.selector, "selector": title.selector], in: nil, contentWorld: .page)
        XCTAssertEqual(relative as? String, "第一项")
    }
}

@MainActor private final class FixturePage: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    init(webView: WKWebView = WKWebView()) { self.webView = webView; super.init() }
    private var continuation: CheckedContinuation<Void, Error>?
    func load(_ html: String) async throws {
        webView.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'\">" + html, baseURL: URL(string: "https://media.example/latest/")!)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard let self, let pending = self.continuation else { return }
                self.continuation = nil; pending.resume(throwing: URLError(.timedOut))
            }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume(); continuation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
}

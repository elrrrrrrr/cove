import SwiftUI
import WebKit

struct SitePickedElement: Sendable, Equatable {
    var id = UUID()
    var field: String
    var selector: String
    var attribute: String?
    var value: String
}

@Observable @MainActor
final class SiteElementPicker: NSObject {
    let webView: WKWebView
    var currentURL: URL?
    var isLoading = false
    var selection: SitePickedElement?
    var error: String?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(SitePickerMessageProxy(owner: self), name: "covePick")
        webView.navigationDelegate = self
    }

    func load(_ url: URL) { currentURL = url; error = nil; isLoading = true; webView.load(URLRequest(url: url)) }
    func pick(field: String?, items: String?) {
        Task {
            do {
                _ = try await webView.callAsyncJavaScript("window.__covePickField = field; window.__covePickItems = items;", arguments: ["field": field ?? "", "items": items ?? ""], in: nil, contentWorld: .page)
            } catch { self.error = error.localizedDescription }
        }
    }
    func stop() { webView.stopLoading() }

    private static let script = #"""
    (() => {
        window.__covePickField = '';
        window.__covePickItems = '';
        function selector(el, root, repeated) {
            const parts = [];
            for (let node = el; node && node !== root && node.nodeType === 1; node = node.parentElement) {
                if (node.id && !repeated) { parts.unshift('#' + CSS.escape(node.id)); break; }
                const classes = [...node.classList].filter(c => !/^(active|selected|hover|focus)$/.test(c)).slice(0, 3);
                let part = node.tagName.toLowerCase() + classes.map(c => '.' + CSS.escape(c)).join('');
                if (!classes.length && !repeated && node.parentElement) {
                    const peers = [...node.parentElement.children].filter(n => n.tagName === node.tagName);
                    if (peers.length > 1) part += ':nth-of-type(' + (peers.indexOf(node) + 1) + ')';
                }
                parts.unshift(part);
                if (repeated && classes.length) break;
            }
            return parts.join(' > ');
        }
        document.addEventListener('click', event => {
            const field = window.__covePickField;
            if (!field) return;
            event.preventDefault(); event.stopImmediatePropagation();
            let el = event.target.closest('*');
            if (!el) return;
            if (field === 'items') el = el.closest('article,li,[class*="card"],[class*="item"]') || el;
            if (['url','nextPageURL','prevChapter','nextChapter','chapters','nextPage'].includes(field)) el = el.closest('a[href]') || el;
            if (['thumbnail','cover','images'].includes(field)) el = el.closest('img') || el.querySelector('img') || el;
            let root = document;
            if (window.__covePickItems && field !== 'items' && field !== 'nextPage') {
                try { root = [...document.querySelectorAll(window.__covePickItems)].find(n => n.contains(el)) || document; } catch (_) {}
            }
            let attribute = null;
            if (['url','nextPageURL','prevChapter','nextChapter','chapters','nextPage'].includes(field)) attribute = 'href';
            if (['thumbnail','cover','images'].includes(field)) attribute = ['data-original','data-src','src'].find(name => el.getAttribute(name)) || 'src';
            const value = attribute ? el.getAttribute(attribute) || '' : (el.textContent || '').trim();
            el.style.outline = '3px solid #0a84ff';
            setTimeout(() => { el.style.outline = ''; }, 1000);
            window.webkit.messageHandlers.covePick.postMessage({field, selector: selector(el, root, field === 'items' || ['images','chapters','tags'].includes(field)), attribute, value});
            window.__covePickField = '';
        }, true);
    })();
    """#
}

@MainActor private final class SitePickerMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: SiteElementPicker?
    init(owner: SiteElementPicker) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let field = body["field"] as? String,
              let selector = body["selector"] as? String else { return }
        let result = SitePickedElement(field: field, selector: selector, attribute: body["attribute"] as? String, value: body["value"] as? String ?? "")
        owner?.selection = result
    }
}

extension SiteElementPicker: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        currentURL = webView.url; isLoading = false
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error.localizedDescription; isLoading = false
    }
}

struct SitePickerWebView: UIViewRepresentable {
    let picker: SiteElementPicker
    func makeUIView(context: Context) -> WKWebView { picker.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

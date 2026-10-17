import SwiftUI
import SwiftData
import WebKit

struct SiteLoginManagementView: View {
    @Query(sort: \BookmarkSite.sortOrder) private var sites: [BookmarkSite]

    var body: some View {
        List {
            let targets = SiteLoginTarget.targets(for: sites)
            if targets.isEmpty {
                ContentUnavailableView("暂无网站", systemImage: "globe", description: Text("先在管理网站中添加站点，再登录网站账号。"))
            } else {
                Section {
                    ForEach(targets) { target in
                        NavigationLink {
                            SiteLoginDetailView(target: target)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(target.name)
                                Text(target.host).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("website-login-" + target.host)
                    }
                } footer: {
                    Text("同一域名的入口共用登录数据。登录数据默认保留在本机，不包含在配置备份中；站点仍可能要求重新登录。")
                }
            }
        }
        .appSurface()
        .navigationTitle("网站登录")
    }
}

private struct SiteLoginDetailView: View {
    let target: SiteLoginTarget
    @State private var showLogin = false
    @State private var confirmClear = false
    @State private var clearing = false
    @State private var hasData: Bool?

    var body: some View {
        Form {
            Section {
                LabeledContent("网站", value: target.name)
                LabeledContent("域名", value: target.host)
                LabeledContent("登录数据", value: "默认保留")
                LabeledContent("本地网站数据", value: dataStatus)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("本地网站数据")
                    .accessibilityValue(dataStatus)
                    .accessibilityIdentifier("website-login-data-status")
            } footer: {
                Text("本地数据不代表账号仍已登录，实际登录状态以网站显示为准。")
            }
            Section {
                Button("登录或切换账号") { showLogin = true }
                    .accessibilityIdentifier("website-login-open")
                    .disabled(clearing)
                Button("清除该站登录数据", role: .destructive) { confirmClear = true }
                    .disabled(clearing)
                    .accessibilityIdentifier("website-login-clear")
                if clearing { ProgressView("正在清除…") }
            } footer: {
                Text("登录完成后关闭网页，返回站点重试解析。切换账号请在网站内退出当前账号，或先清除登录数据。")
            }
        }
        .appSurface()
        .navigationTitle(target.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .sheet(isPresented: $showLogin, onDismiss: { Task { await refresh() } }) {
            SiteLoginPage(target: target)
        }
        .alert("清除该站登录数据？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}
            Button("确认清除", role: .destructive) {
                Task {
                    clearing = true
                    await SiteWebSession.clearLoginData(for: target.host)
                    await refresh()
                    clearing = false
                }
            }
        } message: {
            Text("将删除该站的 Cookie 和本地存储，共享同一网站数据域的其他入口也会受影响。已打开的网页需要重新加载；收藏和阅读记录会保留。")
        }
    }
    private var dataStatus: String { hasData.map { $0 ? "已保存" : "暂无记录" } ?? "检查中…" }
    private func refresh() async { hasData = await SiteWebSession.hasLoginData(for: target.host) }
}

private struct SiteLoginPage: View {
    let target: SiteLoginTarget
    @Environment(\.dismiss) private var dismiss
    @State private var browser: SiteLoginBrowser

    init(target: SiteLoginTarget) {
        self.target = target
        _browser = State(initialValue: SiteLoginBrowser(url: target.url))
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Text(browser.info.url?.host ?? target.host).font(.caption).textSelection(.enabled)
                    Spacer()
                    if browser.info.loading { ProgressView().controlSize(.small) }
                }.padding(.horizontal).padding(.vertical, 8)
                if let error = browser.error {
                    Text(error).font(.caption).foregroundStyle(.secondary).padding()
                }
                ParsingWebViewHost(webView: browser.webView)
                    .accessibilityIdentifier("website-login-webview")
            }
            .navigationTitle("网站登录")
            .navigationBarTitleDisplayMode(.inline)
            .task { browser.start() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("website-login-done")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("后退", systemImage: "chevron.left") { browser.webView.goBack() }
                        .disabled(!browser.info.canGoBack)
                    Button("刷新", systemImage: "arrow.clockwise") { browser.reload() }
                }
            }
        }
    }
}

@Observable @MainActor final class SiteLoginBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let info: ParsingWebPageInfo
    var error: String?
    private let entryURL: URL
    private var initialURL: URL?

    init(url: URL) {
        let view = WebCoordinator().webView
        webView = view
        info = ParsingWebPageInfo(webView: view)
        entryURL = url
        initialURL = url
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
    }
    func start() {
        guard let url = initialURL else { return }
        initialURL = nil
        webView.load(URLRequest(url: url))
    }
    func reload() {
        error = nil
        if webView.url == nil { webView.load(URLRequest(url: entryURL)) }
        else { webView.reload() }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { error = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { self.error = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

import AppKit
import WebKit

/// Displays the Spectrum Help Book HTML in-app.
/// Apple Help Viewer often reports “Help isn’t available” for ad-hoc signed builds.
@MainActor
enum HelpBook {
    static func open(anchor: String? = nil) {
        let destination = destination(for: anchor)
        HelpWindow.shared.show(page: destination.page, fragment: destination.fragment)
    }

    private static func destination(for anchor: String?) -> (page: String, fragment: String?) {
        switch anchor {
        case "permissions", "screen-recording", "microphone", "after-granting":
            return ("permissions.html", anchor)
        case "same-binary":
            return ("permissions.html", "after-granting")
        case "audio-sources":
            return ("audio.html", "audio-sources")
        case "analyzer":
            return ("analyzer.html", "analyzer")
        case "appearance":
            return ("appearance.html", "appearance")
        case "performance":
            return ("performance.html", "performance")
        case "main-window":
            return ("window.html", "main-window")
        case "troubleshooting":
            return ("troubleshooting.html", "troubleshooting")
        default:
            return ("index.html", nil)
        }
    }
}

@MainActor
private final class HelpWindow: NSObject, WKNavigationDelegate {
    static let shared = HelpWindow()

    private var window: NSWindow?
    private var webView: WKWebView?
    private var pendingFragment: String?
    private var helpRoot: URL?

    func show(page: String, fragment: String?) {
        if window == nil {
            makeWindow()
        }
        load(page: page, fragment: fragment)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 640))
        webView.navigationDelegate = self
        self.webView = webView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Spectrum Help"
        window.minSize = NSSize(width: 560, height: 400)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentView = webView
        window.center()
        self.window = window
    }

    private func load(page: String, fragment: String?) {
        guard let root = helpDirectory() else { return }
        helpRoot = root
        let file = root.appendingPathComponent(page)
        pendingFragment = fragment
        webView?.loadFileURL(file, allowingReadAccessTo: root)
    }

    private func helpDirectory() -> URL? {
        let subdirectory = "Spectrum.help/Contents/Resources"
        if let english = Bundle.main.url(forResource: "English.lproj", withExtension: nil, subdirectory: subdirectory) {
            return english
        }
        return Bundle.main.url(forResource: "en.lproj", withExtension: nil, subdirectory: subdirectory)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let fragment = pendingFragment, !fragment.isEmpty else { return }
        pendingFragment = nil
        let escaped = fragment.replacingOccurrences(of: "'", with: "\\'")
        webView.evaluateJavaScript("window.location.hash = '\(escaped)';", completionHandler: nil)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url.isFileURL {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
